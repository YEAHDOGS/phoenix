# Answer-file generator

Phase 2 of the Phoenix roadmap: `tools/New-UnattendXml.ps1` emits a clean
`autounattend.xml` from the tokenized template
`win-install/autounattend.template.xml` (a token-for-token copy of the
proven Schneegans-generated file, scrubbed of every credential and
machine-specific value).

## The one rule

**The generator is the only source of credentials. Never a committed file.**

- The template (`win-install/autounattend.template.xml`) contains zero
  credentials and is safe to commit. It carries `{{TOKEN}}` placeholders
  instead of names, passwords, keys, and hostnames.
- The filled file goes to `win-install/staging/autounattend.xml`, which is
  gitignored. The unattend format *requires* real local-account passwords
  (even `ObscurePasswords=true` is reversible), so a filled file must never
  be committed, pasted, or screenshotted.
- Note: the old `win-install/autounattend.xml` still has its dummy
  Schneegans passwords in plaintext in this public repo. Treat those as
  published - they were always throwaways, and the generator path replaces
  that file's job going forward.

## Quick start

```powershell
# Prompts for the password (SecureString - never touches shell history)
.\tools\New-UnattendXml.ps1 -ComputerName NIGHTMARE -Username brando

# Two accounts, explicit output, overwrite allowed
$pw = Read-Host -AsSecureString -Prompt 'Admin password'
.\tools\New-UnattendXml.ps1 -ComputerName NIGHTMARE -Username brando `
    -Password $pw -StandardUsername guest -Force
```

Copy the result to the USB root as `autounattend.xml` next to
`install.wim` / `install.esd`. What the file then does on boot is
documented in `win-install/README.md` (wipes DISK 0 via diskpart, applies
the image with DISM, injects `$WinPEDriver$` drivers, disables WPBT,
continues setup unattended).

## Parameters

| Param | Default | Notes |
|---|---|---|
| `-ComputerName` | *(required)* | NetBIOS name, 1-15 chars `[A-Za-z0-9-]` |
| `-Username` | *(required)* | Primary local account: Administrators + AutoLogon (1x) |
| `-Password` | *(prompted)* | SecureString. Omit it and you get a masked prompt - no plaintext args, no history |
| `-StandardUsername` | *(none)* | Optional second account (Users group). Omit for single-account |
| `-StandardPassword` | *(prompted if above)* | SecureString |
| `-TimeZone` | `Central Standard Time` | Windows timezone ID |
| `-Edition` | `Windows 11 Pro` | Must match `/Name:"..."` of an image in install.wim/esd |
| `-ProductKey` | `VK7JG-NPHTM-C97JM-9MPGT-3V66T` | MS public generic Pro key (not a license). Swap in a real key if you have one |
| `-OutputPath` | `win-install/staging/autounattend.xml` | Override only if you know why |
| `-Force` | | Overwrite an existing output file |

Fails cleanly (no partial write) on: missing template, existing output
without `-Force`, empty passwords, identical admin/standard usernames,
leftover unfilled tokens, or malformed XML.

## Linux twin: `tools/New-UnattendXml.sh`

The same generator as a bash script for the Linux side (every PowerShell
tool gets a bash twin). Same contract, same fail-closed validation, same
byte-level output (verified byte-identical to the `.ps1`'s proven output
modulo the origin stamp):

```bash
# Prompts for the password securely (read -s -- never touches shell history)
tools/New-UnattendXml.sh --computer-name NIGHTMARE --username brando

# Two accounts, overwrite allowed
tools/New-UnattendXml.sh --computer-name NIGHTMARE --username brando \
    --password 's3cr3t!' --standard-username guest --force
```

Flag mapping: `-ComputerName` -> `--computer-name`, `-Username` ->
`--username`, `-Password` -> `--password`, `-StandardUsername` ->
`--standard-username`, `-StandardPassword` -> `--standard-password`,
`-TimeZone` -> `--timezone`, `-Edition` -> `--edition`, `-ProductKey` ->
`--product-key`, `-OutputPath` -> `--output`, `-Force` -> `--force`.
Regression suite: `bash tests/tools/test-unattend-twin.sh` (21 checks).

## Schneegans round-trip

The template header keeps the original Schneegans generator URL. The
generator rewrites its query params to match your choices
(`ComputerName=`, `TimeZone=`, `InstallFromName=`, `AccountName0/1=`,
`AccountPassword0/1=`, ...), so a filled file can still be opened in
https://schneegans.de/windows/unattend-generator/ and hand-tweaked. The
password "obscuring" is Schneegans' own scheme, reproduced exactly:
`base64( UTF-16LE( password + "Password" ) )` - verified against the
proven file's hashes in the test suite.

## Testing

```powershell
.\tools\Test-UnattendXml.ps1
```

Pester-free, exits 1 on failure. Asserts: template well-formed with all 7
passes (`offlineServicing`, `windowsPE`, `generalize`, `specialize`,
`auditSystem`, `auditUser`, `oobeSystem`), `Microsoft-Windows-Setup` in
windowsPE, `UserAccounts` in oobeSystem, all 10 tokens present, zero dummy
credential strings, the obfuscation reproduces the proven hashes, and an
end-to-end generator run into a temp dir produces well-formed, token-free
output with both accounts, AutoLogon, rewritten comment, and clean
failure modes. (Also validated on Linux via python/xml.etree - 36/36 -
since the build VM has no PowerShell.)

End-to-end install testing stays where it was: `scripts/qemu/start.ps1`
boots the ISO + generated file + staged USB in QEMU (Phase 4 wires in
assertions).

## Not yet (future work)

- GUI form for this (Phase 5: Tauri app drives the same generator).
- Disk layout / locale / remove-list parameters - still Schneegans'
  territory; the comment URL is the escape hatch until then.
- The `$OEM$` `Specialize.ps1` / `DefaultUser.ps1` / `FirstLogon.ps1`
  scripts the answer file invokes (Phase 3) - referenced, not shipped.
