# win-install

Unattended Windows 11 install from USB.

## The answer file

`autounattend.xml` is no longer a hand-edited template. Phoenix generates it
with the [Schneegans unattend-generator](https://github.com/cschneegans/unattend-generator),
the open-source library behind schneegans.de, wrapped by [`app/unattend/`](../../app/unattend/README.md).
Every option the website offers is available in the Phoenix app's Answer file
screen, offline, and no password ever leaves the machine.

The USB builder writes it to the **root of the Phoenix USB**. Windows Setup
scans the root of every removable drive for `autounattend.xml`, so the Win11
install USB stays stock.

Generate one by hand:

```powershell
powershell -File app\unattend\build.ps1        # once: builds phoenix-unattend.exe
# then, through the engine (reads phoenix.config.json + a one-shot secrets file):
powershell -File scripts\engine\phoenix.ps1 unattend -ArgsPath args.json
```

Phoenix's defaults (`app/unattend/phoenix-defaults.json`) reproduce the settings
the old hand-built template used: GPT with a 100 MB EFI and a 600 MB recovery
partition on disk 0, install by edition name, WPBT disabled, 8.3 names off,
Windows Update and fast startup off, Edge uninstallable, process auditing with
command lines, express settings all off, and the same bloatware list. On top of
that, the page file is disabled from the first boot so RAM never reaches disk.

> [!CAUTION]
> The generated file **wipes the target disk** (disk 0 by default, set in the
> profile) without asking.

### What Phoenix adds

- **Accounts** from the profile: the admin (Administrators) logs on
  automatically once; the lead user and any extra users are standard users.
- **FirstLogon handoff**: finds `\phoenix\phoenix.id` on any drive, copies the
  kit to `C:\ProgramData\Phoenix\kit`, and starts phase `admin`. It starts the
  phase detached and waits for Setup's own FirstLogon steps to finish first,
  because Setup deletes `unattend.xml` (which holds the passwords) only after
  custom scripts run.

## Credentials

The unattend format requires account passwords in the file. Phoenix obscures
them (base64), which is **not encryption**. Passwords are typed at build time,
never saved in the profile, and Setup deletes its copy of the answer file
after the first logon. The copy on the Phoenix USB remains, so treat those
passwords as install-time only and change them after first logon.

## img/

Ghost Rider wallpapers, because a machine that isn't badass isn't worth
installing.

## Testing without real hardware

`scripts/qemu/start.ps1` boots a Windows 11 VM for end-to-end tests.
