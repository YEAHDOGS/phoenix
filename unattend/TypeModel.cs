using System.Collections;
using System.Collections.Immutable;
using System.Drawing;
using System.Reflection;
using Schneegans.Unattend;

namespace Phoenix.Unattend;

/// <summary>How a CLR type is represented in the schema and the DTO.</summary>
public enum TypeKind { Primitive, Enum, Keyed, Interface, Record, ComponentAndPass }

public enum CollectionKind { None, List, Set, Dict }

/// <summary>
/// Classifies the library's types by reflection. Nothing here is hand-mapped
/// per setting, so options added upstream show up without code changes.
/// </summary>
public sealed class TypeModel
{
    public static readonly Assembly Library = typeof(Configuration).Assembly;

    private readonly UnattendGenerator generator;
    private readonly Dictionary<Type, IDictionary> keyedDictionaries = [];
    private readonly NullabilityInfoContext nullability = new();

    public TypeModel(UnattendGenerator generator)
    {
        this.generator = generator;
        // Every IImmutableDictionary<string, T> property on the generator is a lookup table for keyed type T.
        foreach (var prop in typeof(UnattendGenerator).GetProperties(BindingFlags.Public | BindingFlags.Instance))
        {
            var t = prop.PropertyType;
            if (t.IsGenericType && t.GetGenericTypeDefinition() == typeof(IImmutableDictionary<,>) && t.GetGenericArguments()[0] == typeof(string))
            {
                keyedDictionaries[t.GetGenericArguments()[1]] = (IDictionary)prop.GetValue(generator)!;
            }
        }
    }

    public UnattendGenerator Generator => generator;

    public IEnumerable<Type> KeyedTypes => keyedDictionaries.Keys;

    public bool IsKeyed(Type t) => keyedDictionaries.ContainsKey(t);

    public object LookupKeyed(Type t, string id, string path)
    {
        var dict = keyedDictionaries[t];
        if (dict.Contains(id)) return dict[id]!;
        // Case-insensitive fallback; ids like 'en-US' are often typed in another case.
        foreach (DictionaryEntry e in dict)
        {
            if (string.Equals((string)e.Key, id, StringComparison.OrdinalIgnoreCase)) return e.Value!;
        }
        throw new DtoException(path, $"Unknown {t.Name} '{id}'.");
    }

    public IEnumerable<(string Id, string Label)> KeyedOptions(Type t)
    {
        foreach (DictionaryEntry e in keyedDictionaries[t])
        {
            var item = e.Value!;
            string label = item.GetType().GetProperty("DisplayName")?.GetValue(item) as string ?? (string)e.Key;
            yield return ((string)e.Key, label);
        }
    }

    public static string KeyedId(object value) => ((IKeyed)value).Id;

    public static bool IsPrimitive(Type t)
    {
        t = Nullable.GetUnderlyingType(t) ?? t;
        return t == typeof(string) || t == typeof(bool) || t == typeof(int) || t == typeof(long)
            || t == typeof(double) || t == typeof(Color) || t == typeof(byte[]);
    }

    public static string PrimitiveName(Type t)
    {
        t = Nullable.GetUnderlyingType(t) ?? t;
        if (t == typeof(string)) return "string";
        if (t == typeof(bool)) return "bool";
        if (t == typeof(int) || t == typeof(long)) return "int";
        if (t == typeof(double)) return "number";
        if (t == typeof(Color)) return "color";
        if (t == typeof(byte[])) return "bytes";
        throw new NotSupportedException(t.FullName);
    }

    public TypeKind KindOf(Type t)
    {
        t = Nullable.GetUnderlyingType(t) ?? t;
        if (IsPrimitive(t)) return TypeKind.Primitive;
        if (t == typeof(ComponentAndPass)) return TypeKind.ComponentAndPass;
        if (t.IsEnum) return TypeKind.Enum;
        if (IsKeyed(t)) return TypeKind.Keyed;
        if (t.IsInterface || t.IsAbstract) return TypeKind.Interface;
        return TypeKind.Record;
    }

    /// <summary>Concrete public types in the library assignable to an interface/abstract type.</summary>
    public static IReadOnlyList<Type> Implementations(Type iface) =>
        Library.GetTypes()
            .Where(t => t.IsPublic && !t.IsAbstract && !t.IsInterface && iface.IsAssignableFrom(t))
            .Where(t => PrimaryConstructor(t) != null)
            .OrderBy(t => t.Name, StringComparer.Ordinal)
            .ToList();

    /// <summary>The public constructor with the most parameters (records: the primary ctor; the copy ctor is protected).</summary>
    public static ConstructorInfo? PrimaryConstructor(Type t)
    {
        if (t.IsValueType && t.GetConstructors().Length == 0) return null;
        return t.GetConstructors(BindingFlags.Public | BindingFlags.Instance)
            .Where(c => !(c.GetParameters().Length == 1 && c.GetParameters()[0].ParameterType == t))
            .OrderByDescending(c => c.GetParameters().Length)
            .FirstOrDefault();
    }

    /// <summary>DTO name of a ctor parameter: PascalCase (records already are; classes use camelCase params).</summary>
    public static string DtoName(ParameterInfo p) => char.ToUpperInvariant(p.Name![0]) + p.Name[1..];

    public static (CollectionKind Kind, Type? Key, Type Element) Collection(Type t)
    {
        if (t == typeof(string) || t == typeof(byte[])) return (CollectionKind.None, null, t);
        if (t.IsArray) return (CollectionKind.List, null, t.GetElementType()!);
        if (!t.IsGenericType) return (CollectionKind.None, null, t);

        var def = t.GetGenericTypeDefinition();
        var args = t.GetGenericArguments();
        Type[] dictDefs = [typeof(IDictionary<,>), typeof(ImmutableDictionary<,>), typeof(IImmutableDictionary<,>),
            typeof(ImmutableSortedDictionary<,>), typeof(Dictionary<,>), typeof(IReadOnlyDictionary<,>)];
        if (dictDefs.Contains(def)) return (CollectionKind.Dict, args[0], args[1]);
        Type[] setDefs = [typeof(ISet<>), typeof(ImmutableHashSet<>), typeof(IImmutableSet<>), typeof(ImmutableSortedSet<>),
            typeof(HashSet<>), typeof(IReadOnlySet<>)];
        if (setDefs.Contains(def)) return (CollectionKind.Set, null, args[0]);
        Type[] listDefs = [typeof(IEnumerable<>), typeof(IList<>), typeof(ImmutableList<>), typeof(IImmutableList<>),
            typeof(List<>), typeof(IReadOnlyList<>), typeof(IReadOnlyCollection<>), typeof(ICollection<>), typeof(ImmutableArray<>)];
        if (listDefs.Contains(def)) return (CollectionKind.List, null, args[0]);
        return (CollectionKind.None, null, t);
    }

    public bool IsNullable(ParameterInfo p)
    {
        if (Nullable.GetUnderlyingType(p.ParameterType) != null) return true;
        if (p.ParameterType.IsValueType) return false;
        return nullability.Create(p).WriteState == NullabilityState.Nullable;
    }

    /// <summary>Schema type name for an element type.</summary>
    public string TypeName(Type t)
    {
        t = Nullable.GetUnderlyingType(t) ?? t;
        return KindOf(t) switch
        {
            TypeKind.Primitive => PrimitiveName(t),
            _ => t.Name,
        };
    }

    /// <summary>
    /// Finds the readable member holding a ctor parameter's value: a property or
    /// field of the same name, else the single unmatched public property
    /// (CustomComputerNameSettings(name) exposes ComputerName).
    /// </summary>
    public static MemberInfo? MemberFor(Type t, ParameterInfo p, ParameterInfo[] all)
    {
        const BindingFlags flags = BindingFlags.Public | BindingFlags.Instance | BindingFlags.IgnoreCase;
        MemberInfo? m = (MemberInfo?)t.GetProperty(p.Name!, flags) ?? t.GetField(p.Name!, flags);
        if (m != null) return m;

        var names = new HashSet<string>(all.Select(a => a.Name!), StringComparer.OrdinalIgnoreCase);
        var unmatchedProps = t.GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Where(x => !names.Contains(x.Name) && x.GetIndexParameters().Length == 0 && x.Name != "EqualityContract")
            .Where(x => x.PropertyType == p.ParameterType || Nullable.GetUnderlyingType(p.ParameterType) == x.PropertyType
                || x.PropertyType.IsAssignableFrom(p.ParameterType) || p.ParameterType.IsAssignableFrom(x.PropertyType))
            .ToList();
        var unmatchedParams = all.Where(a =>
            t.GetProperty(a.Name!, flags) == null && t.GetField(a.Name!, flags) == null).ToList();
        if (unmatchedProps.Count == 1 && unmatchedParams.Count == 1) return unmatchedProps[0];
        return null;
    }

    public static object? ReadMember(MemberInfo m, object target) => m switch
    {
        PropertyInfo pi => pi.GetValue(target),
        FieldInfo fi => fi.GetValue(target),
        _ => null,
    };
}

public sealed class DtoException(string path, string message) : Exception(message)
{
    public string Path { get; } = path;
}
