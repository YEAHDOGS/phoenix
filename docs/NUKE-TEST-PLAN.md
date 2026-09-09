# NUKE Test Plan — VM-only verification for `tools/Invoke-Nuke.sh`

> **IRON RULE: destructive nuke paths are tested ONLY in QEMU, on throwaway
> images. NEVER run `--nuke` on bare metal, even "just to check enumeration"
> — a typo in a device id is exactly what the interlocks exist to survive,
> and testing should never depend on them.**

Static checks (this Linux VM, no hardware needed):

```bash
bash -n tools/Invoke-Nuke.sh          # syntax -- must pass
# shellcheck tools/Invoke-Nuke.sh     # if available in the boot-image build env
bash tests/tools/test-nuke-interlocks.sh   # interlock regression harness -- must be 58/58 green
```

The harness (`tests/tools/test-nuke-interlocks.sh`) runs the safety
interlocks with a mocked `lsblk` fixture (sda=HDD, sdb=boot USB, nvme0n1=NVMe,
sdd=mounted data disk) and a preflight that refuses to run if
nwipe/hdparm/nvme-cli are present, so no destructive path can execute.
It covers: dry-run default, `--whatif`, boot-USB structural refusal,
mounted-partition refusal (row + /dev path), unknown/out-of-range id,
bad `--method`, missing `--nuke` arg, gate ordering, plus unit tests of
`classify_media`, `method_for` (+overrides), `nist_level_for`,
`human_size`, `parent_disk`, `resolve_id`. It has caught two real bugs so
far (a `parent_disk` sed fallback mangling nvme names; an `lsblk -P`
`eval` clobbering PATH and silently killing the mount guard).

Everything below runs on Brandon's Windows 11 host with QEMU
(`C:\Program Files\qemu\`; see `scripts/qemu/start.ps1` for the WHPX pattern).
PowerShell snippets assume that install path.

## 0. Test fixtures

```powershell
$Q = "C:\Program Files\qemu"
$T = "$env:USERPROFILE\phoenix-nuke-test"; New-Item $T -ItemType Directory -Force | Out-Null

# Throwaway targets -- RAW format so we can hexdump-verify afterwards
& "$Q\qemu-img.exe" create -f raw $T\target_sata.raw 1G
& "$Q\qemu-img.exe" create -f raw $T\target_nvme.raw 1G
# Fake "Phoenix USB" (the boot medium the guard must protect)
& "$Q\qemu-img.exe" create -f raw $T\fake_usb.raw 512M

# Linux live ISO with nwipe + hdparm + nvme-cli + bash
# (Ubuntu live, SystemRescue, or ShredOS; ShredOS boots straight into nwipe
#  -- drop to a shell with Alt+F2 for these tests)
$ISO = "$T\test-live.iso"   # <-- place your live ISO here

# Get the script into the VM: FAT dir exposed as a USB stick
$SHARE = "$T\share"; New-Item $SHARE -ItemType Directory -Force | Out-Null
Copy-Item ..\tools\Invoke-Nuke.sh $SHARE\
```

Boot command (adjust `-m`/`-smp` to taste):

```powershell
& "$Q\qemu-system-x86_64.exe" -accel whpx -cpu Haswell-v4 -smp 4 -m 4G `
  -cdrom $ISO -boot order=d `
  -drive file=$T\fake_usb.raw,if=none,format=raw,id=usb0 `
  -device usb-storage,drive=usb0 `
  -drive file=$T\target_sata.raw,if=none,format=raw,id=sata0 `
  -device ide-hd,drive=sata0 `
  -drive file=$T\target_nvme.raw,if=none,format=raw,id=nvme0 `
  -device nvme,drive=nvme0,serial=TESTNVME001 `
  -drive file=fat:rw:$SHARE,format=raw,if=none,id=share0 `
  -device usb-storage,drive=share0 `
  -device usb-tablet -display gtk
```

> Note: the live ISO is the *booted* medium here, so the boot-USB guard test
> targets whichever device the live env mounts (the ISO or `fake_usb.raw`
> if you `toram`/`findiso` from it). T3 pins down the exact expectation.

## Test cases

### T1 — Dry-run enumeration (no flags)
Run: `sudo bash /path/to/Invoke-Nuke.sh`
Expect:
- Numbered table prints: device, model, serial, size, bus (TRAN), media class, flags.
- NVMe test disk appears as `NVMe SSD` / bus `nvme`.
- SATA test disk appears as HDD or SSD / bus `sata`.
- Exit code `0`. **No log file created, nothing written.**
Verify: `qemu-img compare` / checksums of `target_*.raw` unchanged after the run.

### T2 — `--whatif` behaves identically to no flags
Run: `sudo bash Invoke-Nuke.sh --whatif`
Expect: same as T1, exit 0.

### T3 — Boot-USB guard refuses the boot device
1. From T1 output, note the row flagged `BOOT-USB` (or any `MOUNTED` row).
2. Run: `sudo bash Invoke-Nuke.sh --nuke <that-row-number>`
Expect: `FATAL: REFUSED: ... is the boot USB` (or `has mounted partitions`),
exit code `1`, **no log file**, target image bit-identical afterwards.

### T4 — Unknown identifier is rejected
Run: `sudo bash Invoke-Nuke.sh --nuke /dev/doesnotexist`
Expect: `FATAL: No disk matches identifier`, exit 1, nothing touched.

### T5 — Wrong serial aborts (the Y/N-that-isn't)
1. Run: `sudo bash Invoke-Nuke.sh --nuke <target_sata row>`
2. At the prompt, type anything that is NOT the exact serial (e.g. `y`, `yes`, a truncated serial).
Expect: `Aborted. Confirmation did not match.`, exit code `2`, log file
exists on the USB recording the abort, target image unchanged.

### T6 — `NUKE <serial>` prefix is accepted
Same as T5 but type `NUKE <exact-serial>`. Then **Ctrl-C during the 5s
countdown**.
Expect: abort, exit code `130`/non-zero, log records the arming + the abort,
target image unchanged. (Proves the countdown is a real abort window.)

### T7 — Destructive run on a throwaway image (SATA, nwipe path)
1. Write a known pattern: `sudo dd if=/dev/urandom of=/dev/sdX bs=1M count=100`
   (use the *enumerated* row for `target_sata.raw` — triple-check via serial/size).
2. Run: `sudo bash Invoke-Nuke.sh --method zero --verify-off --no-countdown --nuke <row>`,
   type the exact serial.
Expect: nwipe completes, log on the USB contains the `CONFIRMED` timestamp
line and `NUKE COMPLETE`.
Verify (host side, VM powered off):
```powershell
# first 100MB must be all zeros now
& "$Q\qemu-img.exe" dd if=$T\target_sata.raw of=$T\head.bin bs=1M count=100 2>$null
# then: (Get-FileHash) or compare against a zeroed reference
fsutil file createnew $T\zeros.bin 104857600  # all-zero file, then zero it for real:
# simplest: hexdump the head in WSL/Linux and confirm no non-zero bytes
wsl hexdump -C $T\head.bin | grep -v " 00 00 00" | head   # expect empty
```
3. Re-run T1: the disk must still enumerate (proves we wiped data, not the device).

### T8 — NVMe path selects firmware purge
1. Fresh `target_nvme.raw` (recreate it).
2. Run: `sudo bash Invoke-Nuke.sh --no-countdown --nuke <nvme-row>`, type serial.
Expect: log shows `NVMe Format with Secure Erase Setting=1 (crypto erase)`.
   (QEMU's emulated NVMe may not advertise crypto erase — then the log must
   show the sanitize fallback or the nwipe fallback **with the logged
   WARNING**. Either is a pass as long as the log matches reality.)
3. If the nwipe fallback fired, verify zeros as in T7.

### T9 — Frozen ATA drive fails safe (optional, hardware-dependent)
If a test SATA drive reports `frozen` in `hdparm -I`: arming must die with the
suspend/resume instruction, exit 1, nothing written. (QEMU guests rarely hit
this; document the outcome if observed on real hardware during image build.)

## Regression checklist (every change to the script)

- [ ] `bash -n` passes.
- [ ] `bash tests/tools/test-nuke-interlocks.sh` is 58/58 green.
- [ ] T1/T2: enumeration only, exit 0, no writes.
- [ ] T3: boot device refused structurally.
- [ ] T5: wrong confirmation aborts, exit 2.
- [ ] T7 or T8: one destructive path completes in-VM with a correct log.

## Out of scope for VM testing

- Real ATA Secure Erase timing/behavior on physical SSDs (firmware-dependent;
  validated by reading the log + `hdparm -I` post-erase on sacrificial hardware
  only, never a machine you care about).
- NVMe crypto-erase on real controllers (QEMU's emulation is a stand-in).
- The full Phoenix USB menu integration (Analyze/Backup/Nuke/Reinstall) —
  covered when the boot image is assembled.
