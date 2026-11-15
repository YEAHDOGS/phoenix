# phoenix-unattend

A CLI over the [Schneegans unattend-generator](https://github.com/cschneegans/unattend-generator)
(MIT), vendored unmodified at [`app/third_party/unattend-generator`](../third_party/unattend-generator/UPSTREAM.md).
It gives Phoenix every option of schneegans.de, offline.

```
phoenix-unattend schema       # JSON schema of the whole Configuration (types, groups, defaults)
phoenix-unattend defaults     # Phoenix's default DTO (phoenix-defaults.json over the library defaults)
phoenix-unattend generate --in dto.json [--secrets s.json] --out autounattend.xml [--allow-empty-passwords]
phoenix-unattend version
```

Errors: `{ "error", "path" }` on stderr, exit code 1. `path` points into the
DTO (for example `$.ComputerNameSettings.$type`).

The engine wraps this as `unattend-schema`, `unattend-defaults` and `unattend`
(`scripts/engine/lib/Unattend.ps1`). Formats: docs/ARCHITECTURE.md, "Answer file".

## Build

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File app\unattend\build.ps1
```

This installs the .NET 10 SDK to `%LOCALAPPDATA%\Microsoft\dotnet` if needed
(no admin; Microsoft's signed `dotnet-install.ps1`). It publishes a
self-contained single file to `app\unattend\bin\phoenix-unattend.exe` (about 36 MB).
Only the build PC needs it; the target machine never runs it.

Tests (read-only, temp files only):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File app\unattend\tests\Test-Unattend.ps1
```

## How it works

Nothing is mapped per setting. `TypeModel` walks `Configuration`'s constructor
graph by reflection:

- **record**: a class or record, built from its public constructor with the most parameters
- **interface**: an interface or abstract type; the DTO picks a concrete implementation with `"$type"`
- **keyed**: any type the generator has a lookup table for (languages, locales, keyboards, geo IDs, time zones, editions, bloatware, desktop icons, Start folders); the DTO holds its `id`
- **enum**, **primitive** (`string`, `bool`, `int`, `color` as `#RRGGBB`, `bytes` as base64), and collections (list, set, dict)

So options added upstream show up in the schema, and in the app's form,
without code changes. One exception: a new top-level `Configuration` parameter
lands in an "Other" group until it is added to `SchemaBuilder.Groups`. The test
suite fails until that happens, so it can't be missed.

DTO parameter names are the C# constructor parameter names in PascalCase.
Records already use PascalCase; classes use camelCase, so `name` becomes
`Name`. Input is case-insensitive.

## Phoenix defaults vs the website URL

`phoenix-defaults.json` was mapped from the schneegans.de regen URL the old
hand-built template came from:

| URL parameter | DTO |
|---|---|
| `LanguageMode=Unattended`, `UILanguage`, `Locale`, `Keyboard`, `GeoLocation` | `LanguageSettings` (`UnattendedLanguageSettings`) |
| `ProcessorArchitecture=amd64` | `ProcessorArchitectures` |
| `BypassNetworkCheck` | `BypassNetworkCheck` |
| `ComputerNameMode=Custom` | `ComputerNameSettings` (`CustomComputerNameSettings`) |
| `TimeZoneMode=Explicit` | `TimeZoneSettings` (`ExplicitTimeZoneSettings`) |
| `PEMode=Generated`, `PartitionMode=Unattended`, `PartitionLayout=GPT`, `EspSize=100`, `RecoveryMode=Partition`, `RecoverySize=600`, `DiskAssertionMode=Skip`, `InstallFromMode=Name`, `CompactOsMode=Never`, `Disable8Dot3Names` | `PESettings` (`GeneratePESettings` > `UnattendedPartitionSettings` with `FixedTargetDiskSettings` index 0; `NameInstallFromSettings`) |
| `WindowsEditionMode=Custom` + `ProductKey` | `ActivationKey`, only when the profile has a real key |
| `UserAccountMode=Unattended`, `AccountName0/1`, `AccountGroup0/1`, `AutoLogonMode=Own`, `ObscurePasswords` | `AccountSettings` (replaced from the profile at generate time) |
| `PasswordExpirationMode=Unlimited`, `LockoutMode=Default` | `PasswordExpirationSettings`, `LockoutSettings` |
| `HideFiles`, `ShowFileExtensions`, `LaunchToThisPC`, `ShowEndTask`, `TaskbarSearch`, `TaskbarIconsMode=Empty`, `HideTaskViewButton`, `DisableBingResults`, `StartTilesMode`, `StartPinsMode=Custom` + `StartPinsJson` | same-named params / `*Settings` |
| `DisableWindowsUpdate` ... `DisableWpbt` (13 toggles) | same-named bools |
| `ProcessAudit`, `ProcessAuditCommandLine` | `ProcessAuditSettings` (`EnabledProcessAuditSettings`) |
| `EffectsMode`, `DesktopIconsMode`, `StartFoldersMode=Custom` + `StartFolderDownloads/Network/Settings` | `Effects`, `DesktopIcons`, `StartFolderSettings` |
| `WifiMode=Skip`, `ExpressSettings`, `LockKeysMode=Skip`, `StickyKeysMode=Disabled`, `ColorMode`, `WallpaperMode`, `LockScreenMode`, `AppLockerMode=Skip` | matching `*Settings` |
| `Remove*=true` (44) | `Bloatwares` (43) |

Not mapped:

- `RemoveFaxAndScan`: the current library has no such bloatware entry.
- `WdacMode=Skip`: the current library has no WDAC option.

Phoenix changes on top of the URL:

- `PagingFileSettings: NoPagingFileSettings`: RAM never reaches disk, from the first boot.
- Computer name, time zone, edition, disk, locales and accounts come from `phoenix.config.json`.
