using System.Reflection;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Schneegans.Unattend;

namespace Phoenix.Unattend;

/// <summary>
/// Emits the schema described in docs/ARCHITECTURE.md ("Schema format") by
/// walking Configuration's constructor graph.
/// </summary>
public sealed class SchemaBuilder(TypeModel model)
{
    private readonly JsonObject types = [];
    private readonly HashSet<Type> seen = [];

    // Website-style sections. Any Configuration param not listed here lands in
    // "other", so new upstream options are never hidden.
    public static readonly (string Id, string Label, string[] Params)[] Groups =
    [
        ("region", "Region and language", ["LanguageSettings"]),
        ("architecture", "Processor architectures", ["ProcessorArchitectures"]),
        ("setup", "Setup settings", ["BypassNetworkCheck", "UseNarrator"]),
        ("computer-name", "Computer name", ["ComputerNameSettings"]),
        ("time-zone", "Time zone", ["TimeZoneSettings"]),
        ("pe", "Windows PE, partitioning, edition and source image", ["PESettings"]),
        ("activation", "Product key (activation)", ["ActivationKey"]),
        ("accounts", "User accounts", ["AccountSettings"]),
        ("password-expiration", "Password expiration", ["PasswordExpirationSettings"]),
        ("lockout", "Account lockout policy", ["LockoutSettings"]),
        ("file-explorer", "File Explorer", ["HideFiles", "ShowFileExtensions", "ClassicContextMenu", "LaunchToThisPC", "HideInfoTip"]),
        ("start-taskbar", "Start menu and taskbar", ["LeftTaskbar", "HideTaskViewButton", "ShowAllTrayIcons", "TaskbarSearch", "TaskbarIcons", "StartPinsSettings", "StartTilesSettings", "ShowEndTask", "DisableWidgets"]),
        ("system", "System tweaks", ["EnableLongPaths", "EnableRemoteDesktop", "HardenSystemDriveAcl", "DeleteJunctions", "AllowPowerShellScripts", "DisableLastAccess", "PreventAutomaticReboot", "DisableSac", "DisableUac", "DisableSmartScreen", "DisableSystemRestore", "DisableFastStartup", "TurnOffSystemSounds", "DisableAppSuggestions", "PreventDeviceEncryption", "DisableWindowsUpdate", "DisablePointerPrecision", "DeleteWindowsOld", "DisableBingResults", "DisableCoreIsolation", "DisableAutomaticRestartSignOn", "DisableWpbt", "PreventDeviceApps"]),
        ("edge", "Microsoft Edge", ["HideEdgeFre", "DisableEdgeStartupBoost", "MakeEdgeUninstallable", "DeleteEdgeDesktopIcon"]),
        ("visual-effects", "Visual effects", ["Effects"]),
        ("desktop-icons", "Desktop icons", ["DesktopIcons"]),
        ("start-folders", "Folders on Start", ["StartFolderSettings"]),
        ("vm", "Virtual machine support", ["VBoxGuestAdditions", "VMwareTools", "VirtIoGuestTools", "ParallelsTools"]),
        ("wifi", "Wi-Fi", ["WifiSettings"]),
        ("express", "Express settings (privacy)", ["ExpressSettings"]),
        ("lock-keys", "Lock keys", ["LockKeySettings"]),
        ("sticky-keys", "Sticky keys", ["StickyKeysSettings"]),
        ("personalization", "Personalization", ["ColorSettings", "WallpaperSettings", "LockScreenSettings"]),
        ("bloatware", "Remove bloatware", ["Bloatwares"]),
        ("scripts", "Run custom scripts", ["ScriptSettings"]),
        ("components", "XML markup for more components", ["Components"]),
        ("applocker", "AppLocker", ["AppLockerSettings"]),
        ("advanced", "Advanced", ["KeepSensitiveFiles", "HidePowerShellWindows", "ProcessAuditSettings"]),
    ];

    private static readonly Dictionary<string, string> LabelOverrides = new(StringComparer.Ordinal)
    {
        ["DisableWpbt"] = "Disable Windows Platform Binary Table (WPBT)",
        ["DisableSac"] = "Disable Smart App Control",
        ["DisableUac"] = "Disable UAC",
        ["HardenSystemDriveAcl"] = "Harden system drive ACL",
        ["HideEdgeFre"] = "Hide Edge first-run experience",
        ["LaunchToThisPC"] = "Open File Explorer to This PC",
        ["UseNarrator"] = "Use Narrator during Setup",
        ["KeepSensitiveFiles"] = "Keep sensitive files (do not delete unattend.xml after setup)",
        ["VBoxGuestAdditions"] = "Install VirtualBox Guest Additions",
        ["VMwareTools"] = "Install VMware Tools",
        ["VirtIoGuestTools"] = "Install VirtIO guest tools",
        ["ParallelsTools"] = "Install Parallels Tools",
        ["PESettings"] = "Windows PE operation",
        ["ActivationKey"] = "Activation product key",
        ["Bloatwares"] = "Bloatware to remove",
        ["DisableCoreIsolation"] = "Disable Core Isolation (memory integrity)",
        ["DisableAutomaticRestartSignOn"] = "Disable automatic restart sign-on (ARSO)",
        ["CompactOs"] = "Use Compact OS",
        ["Disable8Dot3Names"] = "Disable 8.3 file names",
        ["ObscurePasswords"] = "Obscure passwords (base64)",
    };

    public static string Label(string pascal)
    {
        if (LabelOverrides.TryGetValue(pascal, out var l)) return l;
        string spaced = Regex.Replace(pascal, "(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", " ");
        spaced = Regex.Replace(spaced, @"\bSettings\b$", "").Trim();
        if (spaced.Length == 0) spaced = pascal;
        return char.ToUpperInvariant(spaced[0]) + spaced[1..].ToLowerInvariant()
            .Replace(" pc", " PC").Replace(" ui", " UI").Replace(" xml", " XML").Replace(" json", " JSON")
            .Replace("gi b", "GiB").Replace("mi b", "MiB").Replace(" pe", " PE").Replace("wi fi", "Wi-Fi");
    }

    public JsonObject Build()
    {
        Visit(typeof(Configuration));
        var root = new JsonObject
        {
            ["root"] = "Configuration",
            ["generator"] = new JsonObject
            {
                ["library"] = "cschneegans/unattend-generator",
                ["assemblyVersion"] = TypeModel.Library.GetName().Version?.ToString(),
            },
            ["types"] = types,
            ["groups"] = BuildGroups(),
            ["defaults"] = new DtoWriter(model).Write(Configuration.Default, typeof(Configuration)),
        };
        return root;
    }

    public static JsonArray BuildGroups()
    {
        var all = TypeModel.PrimaryConstructor(typeof(Configuration))!.GetParameters().Select(TypeModel.DtoName).ToList();
        var listed = new HashSet<string>(Groups.SelectMany(g => g.Params));
        var arr = new JsonArray();
        foreach (var (id, label, ps) in Groups)
        {
            var present = ps.Where(all.Contains).ToList();
            if (present.Count == 0) continue;
            arr.Add(new JsonObject { ["id"] = id, ["label"] = label, ["params"] = new JsonArray([.. present.Select(p => (JsonNode)p)]) });
        }
        var other = all.Where(p => !listed.Contains(p)).ToList();
        if (other.Count > 0)
        {
            arr.Add(new JsonObject { ["id"] = "other", ["label"] = "Other (new upstream options)", ["params"] = new JsonArray([.. other.Select(p => (JsonNode)p)]) });
        }
        return arr;
    }

    private void Visit(Type t)
    {
        t = Nullable.GetUnderlyingType(t) ?? t;
        var (ck, key, elem) = TypeModel.Collection(t);
        if (ck != CollectionKind.None)
        {
            if (key != null) Visit(key);
            Visit(elem);
            return;
        }
        if (!seen.Add(t)) return;

        switch (model.KindOf(t))
        {
            case TypeKind.Primitive:
                return;
            case TypeKind.Enum:
                types[t.Name] = new JsonObject
                {
                    ["kind"] = "enum",
                    ["values"] = new JsonArray([.. Enum.GetNames(t).Select(n => (JsonNode)n)]),
                    ["flags"] = t.GetCustomAttribute<FlagsAttribute>() != null,
                };
                return;
            case TypeKind.Keyed:
                types[t.Name] = new JsonObject
                {
                    ["kind"] = "keyed",
                    ["options"] = new JsonArray([.. model.KeyedOptions(t)
                        .OrderBy(o => o.Label, StringComparer.OrdinalIgnoreCase)
                        .Select(o => (JsonNode)new JsonObject { ["id"] = o.Id, ["label"] = o.Label })]),
                };
                return;
            case TypeKind.ComponentAndPass:
                Visit(typeof(Pass));
                types[t.Name] = new JsonObject
                {
                    ["kind"] = "record",
                    ["params"] = new JsonArray(
                        new JsonObject { ["name"] = "Component", ["type"] = "string", ["nullable"] = false, ["collection"] = null, ["label"] = "Component" },
                        new JsonObject { ["name"] = "Pass", ["type"] = "Pass", ["nullable"] = false, ["collection"] = null, ["label"] = "Pass" }),
                    ["componentIds"] = new JsonArray([.. model.Generator.Components.Keys.Order().Select(k => (JsonNode)k)]),
                };
                return;
            case TypeKind.Interface:
                var impls = TypeModel.Implementations(t);
                types[t.Name] = new JsonObject
                {
                    ["kind"] = "interface",
                    ["implementations"] = new JsonArray([.. impls.Select(i => (JsonNode)i.Name)]),
                };
                foreach (var i in impls) Visit(i);
                return;
            case TypeKind.Record:
                var ctor = TypeModel.PrimaryConstructor(t)
                    ?? throw new InvalidOperationException($"{t.Name} has no public constructor.");
                var ps = new JsonArray();
                foreach (var p in ctor.GetParameters())
                {
                    ps.Add(Param(p));
                    Visit(p.ParameterType);
                }
                types[t.Name] = new JsonObject { ["kind"] = "record", ["label"] = Label(t.Name), ["params"] = ps };
                return;
        }
    }

    private JsonObject Param(ParameterInfo p)
    {
        var pt = Nullable.GetUnderlyingType(p.ParameterType) ?? p.ParameterType;
        var (ck, key, elem) = TypeModel.Collection(pt);
        string name = TypeModel.DtoName(p);
        var o = new JsonObject
        {
            ["name"] = name,
            ["type"] = model.TypeName(ck == CollectionKind.None ? pt : elem),
            ["nullable"] = model.IsNullable(p),
            ["collection"] = ck switch { CollectionKind.List => "list", CollectionKind.Set => "set", CollectionKind.Dict => "dict", _ => null },
            ["label"] = Label(name),
        };
        if (ck == CollectionKind.Dict && key != null) o["keyType"] = model.TypeName(key);
        if (p.HasDefaultValue)
        {
            o["default"] = p.DefaultValue switch
            {
                null => null,
                bool b => b,
                int i => i,
                string s => s,
                var v when v.GetType().IsEnum => v.ToString(),
                var v => v.ToString(),
            };
        }
        return o;
    }
}
