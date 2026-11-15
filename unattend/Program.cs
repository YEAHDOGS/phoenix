using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Schneegans.Unattend;

namespace Phoenix.Unattend;

/// <summary>
/// phoenix-unattend: CLI over the Schneegans unattend-generator.
///
///   phoenix-unattend schema
///   phoenix-unattend defaults
///   phoenix-unattend generate --in dto.json [--secrets secrets.json] --out autounattend.xml [--allow-empty-passwords]
///
/// stdout: one JSON document. Errors: JSON { "error", "path" } on stderr, exit 1.
/// See docs/ARCHITECTURE.md, "Answer file: Schneegans generator, wrapped".
/// </summary>
public static class Program
{
    private static readonly JsonSerializerOptions Pretty = new() { WriteIndented = true };

    public static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        try
        {
            if (args.Length == 0) throw new UsageException("Missing command: schema | defaults | generate");
            var model = new TypeModel(new UnattendGenerator());
            switch (args[0].ToLowerInvariant())
            {
                case "schema":
                    Emit(new SchemaBuilder(model).Build());
                    return 0;
                case "defaults":
                    Emit(Defaults(model));
                    return 0;
                case "generate":
                    Emit(Generate(model, ParseOptions(args.Skip(1).ToArray())));
                    return 0;
                case "version":
                    Emit(new JsonObject
                    {
                        ["wrapper"] = Assembly.GetExecutingAssembly().GetName().Version?.ToString(),
                        ["library"] = TypeModel.Library.GetName().Version?.ToString(),
                    });
                    return 0;
                default:
                    throw new UsageException($"Unknown command '{args[0]}'. Use: schema | defaults | generate");
            }
        }
        catch (DtoException e)
        {
            return Fail(e.Message, e.Path);
        }
        catch (ConfigurationException e)
        {
            return Fail(e.Message, null);
        }
        catch (UsageException e)
        {
            return Fail(e.Message, null);
        }
        catch (Exception e) when (e is TargetInvocationException { InnerException: not null })
        {
            return Fail(e.InnerException!.Message, null);
        }
        catch (Exception e)
        {
            return Fail($"{e.GetType().Name}: {e.Message}", null);
        }
    }

    private static int Fail(string message, string? path)
    {
        var err = new JsonObject { ["error"] = message, ["path"] = path };
        Console.Error.WriteLine(err.ToJsonString());
        return 1;
    }

    private static void Emit(JsonNode node) => Console.Out.WriteLine(node.ToJsonString(Pretty));

    private static Dictionary<string, string?> ParseOptions(string[] a)
    {
        var o = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < a.Length; i++)
        {
            if (!a[i].StartsWith("--")) throw new UsageException($"Unexpected argument '{a[i]}'.");
            string key = a[i][2..];
            if (key == "allow-empty-passwords") { o[key] = "true"; continue; }
            if (i + 1 >= a.Length) throw new UsageException($"--{key} needs a value.");
            o[key] = a[++i];
        }
        return o;
    }

    /// <summary>The full Configuration.Default as a DTO.</summary>
    public static JsonNode DefaultDto(TypeModel model) =>
        new DtoWriter(model).Write(Configuration.Default, typeof(Configuration))!;

    /// <summary>Phoenix defaults (embedded phoenix-defaults.json) merged over Configuration.Default.</summary>
    public static JsonNode Defaults(TypeModel model)
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("phoenix-defaults.json")
            ?? throw new InvalidOperationException("phoenix-defaults.json is not embedded.");
        var phoenix = JsonNode.Parse(s, documentOptions: new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
        var merged = DtoMerge.Merge(DefaultDto(model), phoenix)!.AsObject();
        merged.Remove("$comment");
        // Prove the defaults bind (accounts may lack passwords; that is checked at generate time).
        new DtoBinder(model).Bind(merged, typeof(Configuration), "$", false);
        return merged;
    }

    private static JsonObject Generate(TypeModel model, Dictionary<string, string?> opt)
    {
        string inPath = opt.GetValueOrDefault("in") ?? throw new UsageException("--in <dto.json> is required.");
        string outPath = opt.GetValueOrDefault("out") ?? throw new UsageException("--out <autounattend.xml> is required.");
        bool allowEmpty = opt.ContainsKey("allow-empty-passwords");

        var docOptions = new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };
        var dto = JsonNode.Parse(File.ReadAllText(inPath), documentOptions: docOptions)
            ?? throw new DtoException("$", "DTO file is empty.");
        var merged = DtoMerge.Merge(DefaultDto(model), dto)!.AsObject();
        merged.Remove("$comment");

        var warnings = new JsonArray();
        var accounts = new JsonArray();
        if (opt.GetValueOrDefault("secrets") is string secretsPath)
        {
            var secrets = JsonNode.Parse(File.ReadAllText(secretsPath))?.AsObject() ?? [];
            ApplySecrets(merged, secrets);
        }
        CheckPasswords(merged, allowEmpty, accounts, warnings);

        var config = (Configuration)new DtoBinder(model).Bind(merged, typeof(Configuration), "$", false)!;
        var xml = model.Generator.GenerateXml(config);
        var bytes = UnattendGenerator.Serialize(xml);
        var full = Path.GetFullPath(outPath);
        Directory.CreateDirectory(Path.GetDirectoryName(full)!);
        File.WriteAllBytes(full, bytes);

        return new JsonObject
        {
            ["ok"] = true,
            ["outPath"] = full,
            ["sha256"] = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
            ["bytes"] = bytes.Length,
            ["accounts"] = accounts,
            ["warnings"] = warnings,
        };
    }

    /// <summary>
    /// secrets: { "accounts": { "<name>": "<password>" }, "wifi": "<password>" }.
    /// Fills only passwords that are empty or missing in the DTO.
    /// </summary>
    private static void ApplySecrets(JsonObject merged, JsonObject secrets)
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (Prop(secrets, "accounts") is JsonObject acc)
        {
            foreach (var kv in acc) if (kv.Value?.GetValue<string>() is string pw) map[kv.Key] = pw;
        }
        string? wifi = Prop(secrets, "wifi")?.GetValue<string>();

        foreach (var obj in Walk(merged))
        {
            string? type = Prop(obj, "$type")?.GetValue<string>();
            if (type == nameof(UnattendedAccountSettings) && Prop(obj, "Accounts") is JsonArray list)
            {
                foreach (var a in list.OfType<JsonObject>())
                {
                    string? name = Prop(a, "Name")?.GetValue<string>();
                    if (name != null && string.IsNullOrEmpty(Prop(a, "Password")?.GetValue<string>()) && map.TryGetValue(name, out var pw))
                        Set(a, "Password", pw);
                }
            }
            if (type == nameof(BuiltinAutoLogonSettings) && string.IsNullOrEmpty(Prop(obj, "Password")?.GetValue<string>())
                && map.TryGetValue("Administrator", out var apw))
                Set(obj, "Password", apw);
            if (type == nameof(ParameterizedWifiSettings) && wifi != null && string.IsNullOrEmpty(Prop(obj, "Password")?.GetValue<string>()))
                Set(obj, "Password", wifi);
        }
    }

    private static void CheckPasswords(JsonObject merged, bool allowEmpty, JsonArray accounts, JsonArray warnings)
    {
        var missing = new List<string>();
        foreach (var obj in Walk(merged))
        {
            string? type = Prop(obj, "$type")?.GetValue<string>();
            if (type == nameof(UnattendedAccountSettings) && Prop(obj, "Accounts") is JsonArray list)
            {
                foreach (var a in list.OfType<JsonObject>())
                {
                    string name = Prop(a, "Name")?.GetValue<string>() ?? "?";
                    accounts.Add(new JsonObject { ["name"] = name, ["group"] = Prop(a, "Group")?.GetValue<string>() });
                    if (string.IsNullOrEmpty(Prop(a, "Password")?.GetValue<string>())) missing.Add(name);
                }
            }
            if (type == nameof(BuiltinAutoLogonSettings) && string.IsNullOrEmpty(Prop(obj, "Password")?.GetValue<string>()))
                missing.Add("Administrator (built-in auto-logon)");
        }
        if (missing.Count == 0) return;
        string msg = $"No password for: {string.Join(", ", missing)}.";
        if (!allowEmpty) throw new DtoException("$.AccountSettings", msg + " Supply them via --secrets (or pass --allow-empty-passwords).");
        warnings.Add(msg + " Accounts were created with empty passwords.");
    }

    private static IEnumerable<JsonObject> Walk(JsonNode? node)
    {
        if (node is JsonObject o)
        {
            yield return o;
            foreach (var kv in o) foreach (var c in Walk(kv.Value)) yield return c;
        }
        else if (node is JsonArray a)
        {
            foreach (var item in a) foreach (var c in Walk(item)) yield return c;
        }
    }

    private static JsonNode? Prop(JsonObject o, string name) =>
        o.FirstOrDefault(kv => string.Equals(kv.Key, name, StringComparison.OrdinalIgnoreCase)).Value;

    private static void Set(JsonObject o, string name, string value)
    {
        string key = o.Select(kv => kv.Key).FirstOrDefault(k => string.Equals(k, name, StringComparison.OrdinalIgnoreCase)) ?? name;
        o[key] = value;
    }
}

public sealed class UsageException(string message) : Exception(message);
