using System.Collections;
using System.Collections.Immutable;
using System.Drawing;
using System.Globalization;
using System.Reflection;
using System.Text.Json.Nodes;
using Schneegans.Unattend;

namespace Phoenix.Unattend;

/// <summary>Library object -> DTO JSON. Used for defaults and round-trips.</summary>
public sealed class DtoWriter(TypeModel model)
{
    public List<string> Warnings { get; } = [];

    public JsonNode? Write(object? value, Type declared, string path = "$")
    {
        if (value == null) return null;
        var t = Nullable.GetUnderlyingType(declared) ?? declared;

        var (ck, keyType, elem) = TypeModel.Collection(t);
        if (ck == CollectionKind.Dict)
        {
            if (keyType == typeof(ComponentAndPass))
            {
                var arr = new JsonArray();
                foreach (DictionaryEntry e in (IDictionary)value)
                {
                    var cp = (ComponentAndPass)e.Key;
                    arr.Add(new JsonObject { ["component"] = cp.Component, ["pass"] = cp.Pass.ToString(), ["xml"] = (string?)e.Value });
                }
                return arr;
            }
            var obj = new JsonObject();
            foreach (DictionaryEntry e in (IDictionary)value)
            {
                obj[KeyString(e.Key)] = Write(e.Value, elem, $"{path}.{KeyString(e.Key)}");
            }
            return obj;
        }
        if (ck != CollectionKind.None)
        {
            var arr = new JsonArray();
            int i = 0;
            foreach (var item in (IEnumerable)value) arr.Add(Write(item, elem, $"{path}[{i++}]"));
            return arr;
        }

        switch (model.KindOf(t))
        {
            case TypeKind.Primitive:
                return value switch
                {
                    string s => s,
                    bool b => b,
                    int n => n,
                    long n => n,
                    double d => d,
                    Color c => $"#{c.R:X2}{c.G:X2}{c.B:X2}",
                    byte[] bytes => Convert.ToBase64String(bytes),
                    _ => JsonValue.Create(value.ToString()),
                };
            case TypeKind.Enum:
                return value.ToString();
            case TypeKind.Keyed:
                return TypeModel.KeyedId(value);
            case TypeKind.ComponentAndPass:
                var cap = (ComponentAndPass)value;
                return new JsonObject { ["component"] = cap.Component, ["pass"] = cap.Pass.ToString() };
            case TypeKind.Interface:
                var o = WriteRecord(value, value.GetType(), path);
                o.Insert(0, "$type", value.GetType().Name);
                return o;
            default:
                return WriteRecord(value, value.GetType(), path);
        }
    }

    private JsonObject WriteRecord(object value, Type runtime, string path)
    {
        var o = new JsonObject();
        var ctor = TypeModel.PrimaryConstructor(runtime);
        if (ctor == null) return o;
        var ps = ctor.GetParameters();
        foreach (var p in ps)
        {
            string name = TypeModel.DtoName(p);
            var member = TypeModel.MemberFor(runtime, p, ps);
            if (member == null)
            {
                Warnings.Add($"{path}.{name}: no readable member on {runtime.Name}; written as null.");
                o[name] = null;
                continue;
            }
            object? v = TypeModel.ReadMember(member, value);
            // ProductKey and similar wrap a string; members may be typed more loosely than the param.
            o[name] = Write(v, p.ParameterType, $"{path}.{name}");
        }
        return o;
    }

    private static string KeyString(object key) => key switch
    {
        IKeyed k => k.Id,
        Enum e => e.ToString(),
        _ => Convert.ToString(key, CultureInfo.InvariantCulture) ?? "",
    };
}

/// <summary>DTO JSON -> library objects, by reflection over constructor parameters.</summary>
public sealed class DtoBinder(TypeModel model)
{
    public object? Bind(JsonNode? node, Type declared, string path, bool nullable)
    {
        if (node == null)
        {
            if (nullable || Nullable.GetUnderlyingType(declared) != null) return null;
            throw new DtoException(path, "A value is required.");
        }
        var t = Nullable.GetUnderlyingType(declared) ?? declared;

        var (ck, keyType, elem) = TypeModel.Collection(t);
        if (ck == CollectionKind.Dict) return BindDict(node, t, keyType!, elem, path);
        if (ck != CollectionKind.None) return BindCollection(node, t, ck, elem, path);

        switch (model.KindOf(t))
        {
            case TypeKind.Primitive: return BindPrimitive(node, t, path);
            case TypeKind.Enum:
                {
                    string s = Str(node, path);
                    if (Enum.TryParse(t, s, ignoreCase: true, out var ev) && Enum.IsDefined(t, ev!)) return ev;
                    throw new DtoException(path, $"'{s}' is not a {t.Name}. Expected one of: {string.Join(", ", Enum.GetNames(t))}.");
                }
            case TypeKind.Keyed:
                return model.LookupKeyed(t, Str(node, path), path);
            case TypeKind.ComponentAndPass:
                {
                    var o = Obj(node, path);
                    string comp = Str(Get(o, "component") ?? throw new DtoException(path, "component is required."), path + ".component");
                    var pass = (Pass)Bind(Get(o, "pass"), typeof(Pass), path + ".pass", false)!;
                    return new ComponentAndPass(comp, pass);
                }
            case TypeKind.Interface:
                {
                    JsonObject o;
                    string typeName;
                    if (node is JsonValue v && v.TryGetValue<string>(out var bare))
                    {
                        typeName = bare; o = [];
                    }
                    else
                    {
                        o = Obj(node, path);
                        typeName = Get(o, "$type")?.GetValue<string>()
                            ?? throw new DtoException(path, $"'$type' is required for {t.Name}. Options: {string.Join(", ", TypeModel.Implementations(t).Select(i => i.Name))}.");
                    }
                    var impl = TypeModel.Implementations(t).FirstOrDefault(i => string.Equals(i.Name, typeName, StringComparison.OrdinalIgnoreCase))
                        ?? throw new DtoException(path + ".$type", $"'{typeName}' is not a {t.Name}. Options: {string.Join(", ", TypeModel.Implementations(t).Select(i => i.Name))}.");
                    return BindRecord(o, impl, path);
                }
            default:
                return BindRecord(Obj(node, path), t, path);
        }
    }

    private object BindRecord(JsonObject o, Type t, string path)
    {
        var ctor = TypeModel.PrimaryConstructor(t) ?? throw new DtoException(path, $"{t.Name} cannot be constructed.");
        var ps = ctor.GetParameters();
        var known = new HashSet<string>(ps.Select(TypeModel.DtoName), StringComparer.OrdinalIgnoreCase) { "$type" };
        foreach (var kv in o)
        {
            if (!known.Contains(kv.Key)) throw new DtoException($"{path}.{kv.Key}", $"{t.Name} has no parameter '{kv.Key}'. Known: {string.Join(", ", ps.Select(TypeModel.DtoName))}.");
        }
        var args = new object?[ps.Length];
        for (int i = 0; i < ps.Length; i++)
        {
            var p = ps[i];
            string name = TypeModel.DtoName(p);
            string ppath = $"{path}.{name}";
            var node = Get(o, name, out bool present);
            if (!present)
            {
                if (p.HasDefaultValue) { args[i] = p.DefaultValue; continue; }
                if (model.IsNullable(p)) { args[i] = null; continue; }
                throw new DtoException(ppath, $"{t.Name}.{name} is required.");
            }
            args[i] = Bind(node, p.ParameterType, ppath, model.IsNullable(p));
        }
        try
        {
            return ctor.Invoke(args);
        }
        catch (TargetInvocationException e) when (e.InnerException != null)
        {
            throw new DtoException(path, e.InnerException.Message);
        }
    }

    private object BindCollection(JsonNode node, Type t, CollectionKind ck, Type elem, string path)
    {
        if (node is not JsonArray arr) throw new DtoException(path, "Expected an array.");
        var listType = typeof(List<>).MakeGenericType(elem);
        var list = (IList)Activator.CreateInstance(listType)!;
        for (int i = 0; i < arr.Count; i++) list.Add(Bind(arr[i], elem, $"{path}[{i}]", false));

        if (t.IsArray)
        {
            var a = Array.CreateInstance(elem, list.Count);
            list.CopyTo(a, 0);
            return a;
        }
        var def = t.IsGenericType ? t.GetGenericTypeDefinition() : t;
        if (def == typeof(ImmutableList<>) || def == typeof(IImmutableList<>))
            return Call(typeof(ImmutableList), "CreateRange", elem, list);
        if (def == typeof(ImmutableArray<>))
            return Call(typeof(ImmutableArray), "CreateRange", elem, list);
        if (def == typeof(ImmutableHashSet<>) || def == typeof(IImmutableSet<>))
            return Call(typeof(ImmutableHashSet), "CreateRange", elem, list);
        if (def == typeof(ImmutableSortedSet<>))
            return Call(typeof(ImmutableSortedSet), "CreateRange", elem, list);
        if (ck == CollectionKind.Set)
            return Activator.CreateInstance(typeof(HashSet<>).MakeGenericType(elem), list)!;
        return list; // IEnumerable<T>, IList<T>, IReadOnlyList<T>, ...
    }

    private object BindDict(JsonNode node, Type t, Type keyType, Type valueType, string path)
    {
        var dictType = typeof(Dictionary<,>).MakeGenericType(keyType, valueType);
        var dict = (IDictionary)Activator.CreateInstance(dictType)!;
        if (keyType == typeof(ComponentAndPass))
        {
            if (node is not JsonArray arr) throw new DtoException(path, "Expected an array of { component, pass, xml }.");
            for (int i = 0; i < arr.Count; i++)
            {
                string ip = $"{path}[{i}]";
                var o = Obj(arr[i], ip);
                var key = Bind(o, typeof(ComponentAndPass), ip, false)!;
                var xml = Bind(Get(o, "xml"), valueType, ip + ".xml", false);
                dict[key] = xml;
            }
        }
        else
        {
            var o = Obj(node, path);
            foreach (var kv in o)
            {
                string kp = $"{path}.{kv.Key}";
                var key = Bind(JsonValue.Create(kv.Key), keyType, kp, false)!;
                dict[key] = Bind(kv.Value, valueType, kp, false);
            }
        }
        var def = t.IsGenericType ? t.GetGenericTypeDefinition() : t;
        if (def == typeof(ImmutableDictionary<,>) || def == typeof(IImmutableDictionary<,>))
            return Call2(typeof(ImmutableDictionary), "CreateRange", keyType, valueType, dict);
        if (def == typeof(ImmutableSortedDictionary<,>))
            return Call2(typeof(ImmutableSortedDictionary), "CreateRange", keyType, valueType, dict);
        return dict;
    }

    private static object Call(Type host, string method, Type elem, IList items)
    {
        var m = host.GetMethods().First(x => x.Name == method && x.IsGenericMethodDefinition && x.GetParameters().Length == 1)
            .MakeGenericMethod(elem);
        return m.Invoke(null, [items])!;
    }

    private static object Call2(Type host, string method, Type k, Type v, IDictionary items)
    {
        var m = host.GetMethods().First(x => x.Name == method && x.IsGenericMethodDefinition && x.GetParameters().Length == 1)
            .MakeGenericMethod(k, v);
        return m.Invoke(null, [items])!;
    }

    private static object BindPrimitive(JsonNode node, Type t, string path)
    {
        try
        {
            if (t == typeof(string)) return Str(node, path);
            if (t == typeof(bool))
            {
                if (node is JsonValue bv && bv.TryGetValue<bool>(out var b)) return b;
                if (node is JsonValue sv && sv.TryGetValue<string>(out var s) && bool.TryParse(s, out var b2)) return b2;
                throw new DtoException(path, "Expected true or false.");
            }
            if (t == typeof(int))
            {
                if (node is JsonValue iv && iv.TryGetValue<int>(out var n)) return n;
                if (node is JsonValue dv && dv.TryGetValue<double>(out var d) && d == Math.Floor(d)) return (int)d;
                if (node is JsonValue sv && sv.TryGetValue<string>(out var s) && int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n2)) return n2;
                throw new DtoException(path, "Expected an integer.");
            }
            if (t == typeof(long)) return node.GetValue<long>();
            if (t == typeof(double)) return node.GetValue<double>();
            if (t == typeof(byte[])) return Convert.FromBase64String(Str(node, path));
            if (t == typeof(Color))
            {
                string s = Str(node, path).Trim().TrimStart('#');
                if (s.Length != 6 || !int.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var rgb))
                    throw new DtoException(path, "Expected a color like #0078D4.");
                return Color.FromArgb(255, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
            }
        }
        catch (DtoException) { throw; }
        catch (Exception e) { throw new DtoException(path, e.Message); }
        throw new DtoException(path, $"Unsupported primitive {t.Name}.");
    }

    private static string Str(JsonNode node, string path)
    {
        if (node is JsonValue v)
        {
            if (v.TryGetValue<string>(out var s)) return s;
            return v.ToJsonString().Trim('"');
        }
        throw new DtoException(path, "Expected a string.");
    }

    private static JsonObject Obj(JsonNode? node, string path) =>
        node as JsonObject ?? throw new DtoException(path, "Expected an object.");

    private static JsonNode? Get(JsonObject o, string name) => Get(o, name, out _);

    private static JsonNode? Get(JsonObject o, string name, out bool present)
    {
        foreach (var kv in o)
        {
            if (string.Equals(kv.Key, name, StringComparison.OrdinalIgnoreCase)) { present = true; return kv.Value; }
        }
        present = false;
        return null;
    }
}

/// <summary>JSON-level deep merge: overlay wins; objects with a different $type replace wholesale; arrays replace.</summary>
public static class DtoMerge
{
    public static JsonNode? Merge(JsonNode? baseNode, JsonNode? overlay)
    {
        if (overlay is JsonObject oo && baseNode is JsonObject bo)
        {
            string? bt = TypeOf(bo), ot = TypeOf(oo);
            if (ot != null && !string.Equals(bt, ot, StringComparison.OrdinalIgnoreCase)) return oo.DeepClone();
            var result = (JsonObject)bo.DeepClone();
            foreach (var kv in oo)
            {
                string key = result.Select(r => r.Key).FirstOrDefault(k => string.Equals(k, kv.Key, StringComparison.OrdinalIgnoreCase)) ?? kv.Key;
                var existing = result[key];
                result.Remove(key);
                result[key] = Merge(existing, kv.Value);
            }
            return result;
        }
        return overlay?.DeepClone();
    }

    private static string? TypeOf(JsonObject o) =>
        o.FirstOrDefault(kv => string.Equals(kv.Key, "$type", StringComparison.Ordinal)).Value?.GetValue<string>();
}
