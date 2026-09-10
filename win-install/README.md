# win-install

Everything needed to perform an unattended Windows 11 install from USB.

## autounattend.xml

A Schneegans Answer File Generator config (the exact generator URL and all
chosen options are embedded in the comment at the top of the file, so it can
be regenerated or tweaked there).

What it does, in order:

1. **Wipes DISK 0** via diskpart (`SELECT DISK=0` + `CLEAN`, GPT, EFI/MSR/
   Windows/Recovery partitions). **This destroys all data on the target
   disk - there is no confirmation.**
2. Finds `install.wim` / `install.esd` / `install.swm` on the install media
   and applies the **Windows 11 Pro** image with DISM (`/CheckIntegrity
   /Verify`).
3. Injects drivers from a `$WinPEDriver$` folder on the USB (`drvload` in
   WinPE, `DISM /Add-Driver` offline).
4. Disables WPBT (Windows Platform Binary Table) in the offline SYSTEM hive
   and strips 8.3 filenames before first boot.
5. Copies itself to `C:\Windows\Panther\unattend.xml` and continues setup
   unattended: locale, computer name, local accounts, OOBE skipped.
6. During specialize/oobe it expects an `$OEM$` folder on the USB providing
   `$$\Setup\Scripts\Specialize.ps1` and `DefaultUser.ps1` - **this folder
   does not exist in the repo yet** (see VISION.md Phase 3).

It also embeds a hosts-file block script and registry tweaks to neuter
Windows Update driver downloads (full notes in
`scripts/tools/answer-file-notes.txt`).

## Credentials

The XML contains **plaintext local account passwords** - the unattend format
requires them (even with `ObscurePasswords=true` they are reversible). This
repo is public, so treat those passwords as published: use throwaway
install-time credentials and change them after first logon. The
`WINDOWS_KEY` in `.env.example` is Microsoft's public generic Pro key, not
a real license.

## img/

Ghost Rider wallpapers, because a machine that isn't badass isn't worth
installing.

## Testing without real hardware

`scripts/qemu/start.ps1` boots a Windows 11 VM with this folder injected as
a virtual USB, so the answer file can be tested end-to-end in QEMU before
touching a physical machine.
