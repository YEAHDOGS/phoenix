# qemu

QEMU virtual machines: one for the portable Linux dev environment
("Castle"), one for testing Windows installs.

## Castle VM (`start.ps1` + `get-iso.ps1`)

- `get-iso.ps1` downloads the CachyOS ISO into `qemu/data/` (skips if
  already present). The ISO URL is pinned and overridable via `-IsoUrl`.
- `start.ps1` boots it with WHPX acceleration, auto-sized CPU/RAM (leaves
  2 cores for the host, caps at 8 GB), a 40 GB `castle_root.qcow2` disk
  (created on first run), and the ISO attached as a cdrom.
- `scripts/main-install.sh` is the (currently empty) placeholder for
  provisioning steps to run *inside* the VM.
- `data/` holds the ISO and disk image and is gitignored.

## Windows install test VM (`../scripts/qemu/start.ps1`)

A separate script for testing `win-install/autounattend.xml` without real
hardware:

- Boots a Windows 11 ISO in QEMU (WHPX, OVMF/UEFI).
- Injects `../../win-install` as a virtual USB (`fat:rw:` drive), so the
  answer file runs exactly as it would from a real USB stick.
- Template paths at the top (`$VM_DIR`, `$ISO_PATH`) must be edited for
  your machine before first use.

## Notes

- Both launchers assume QEMU is installed at `C:\Program Files\qemu`.
- `qemu-notes.md` collects research: Arch-based distro shortlist (CachyOS /
  EndeavourOS), filesystem tradeoffs (btrfs vs ext4 vs ZFS), and the
  packages the Castle VM still needs (WireGuard/Tailscale, DNS filtering,
  Samba). Open questions, not decisions.
