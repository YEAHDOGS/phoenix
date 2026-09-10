# Phoenix Emergency Runbook — Backup + Nuke + Reinstall

**Purpose:** the exact steps Brandon follows THIS WEEK to deal with a suspected-infected laptop.
**Flow:** boot the **ONE Phoenix USB** → Ventoy menu: **Analyze / Backup / Nuke / Reinstall.**

> Architecture: `docs/BOOT-ARCHITECTURE.md`. The separate-USB flow (one stick
> for the installer, another for Rescuezilla) is retired — Ventoy carries all
> five boot entries on a single stick, and the Ventoy menu *is* the
> Analyze/Backup/Nuke/Reinstall menu.

---

## Safety invariants (non-negotiable)

Read these before touching anything. Every phase below enforces them.

1. **Never wipe before a VERIFIED image exists.** A backup you haven't verified is
   not a backup — it's a hope. The nuke phase must refuse to run without proof of a
   verified image. This is enforced in code, not just documented: `Invoke-Nuke.sh
   --nuke` requires `--image-proof <file>` (Step 2.5) whose `source_serial` binds
   it to the target disk. `--skip-image-gate` exists for true emergencies only
   (typed `NUKE WITHOUT BACKUP` on a real console, logged).
2. **Keep the infected image quarantined for forensics.** Label it clearly
   (`QUARANTINE-INFECTED-<date>`), store it on Castle's 10TB drive, and never mount
   it on a production machine. It is evidence, not a restore source.
3. **Keep the infected machine off the network during imaging.** Unplug Ethernet,
   disable Wi-Fi, do not attach network shares in Rescuezilla. Malware can't phone
   home, and a network share can't be touched by the infection, if the machine is
   air-gapped. Image to a **direct-attached USB drive**.
4. **Assume every destructive step is irreversible.** The nuke entry, the answer
   file's diskpart section, and `Invoke-Nuke` have no undo. Type confirmations are
   there to save you from yourself.
5. **Method-per-media for the nuke.** nwipe alone cannot sanitize SSDs
   (wear-levelling, overprovisioning, remapped blocks). SSD/NVMe targets get
   firmware-level sanitize first (`nvme format --ses=1` / `nvme sanitize` /
   manufacturer Secure Erase), per NIST 800-88 Purge. See BOOT-ARCHITECTURE.md §8.

---

## Phase 0 — PREP (do all of this on a CLEAN machine)

Everything in this phase runs on a machine you trust — not the infected one. Prep
once, execute later.

**Step 0.1 — Inventory your media.**
- 1× USB **≥ 64 GB** → the **Phoenix USB** (Ventoy + all five ISOs + config +
  scripts + caches). 128 GB if you want real cache headroom.
- 1× large external USB drive, **at least as big as the infected laptop's disk**
  (the image will be compressed, but plan for full-size headroom) → the **image target**.
- Optional: a spare USB for Veeam recovery media and installers.

**Step 0.2 — Download the ISO set and verify hashes.**
From a clean machine, download:
- Windows 11 ISO (Microsoft) — verify SHA-256 against Microsoft's published hash.
- Rescuezilla 64-bit ISO (`github.com/rescuezilla/rescuezilla` → Releases, v2.6.x
  current as of this writing — carries an updated SBAT shim for Secure Boot).
- SystemRescue AMD64 ISO (analyze/rescue side).
- ShredOS x86_64 ISO (nuke side — boots straight into nwipe; documents Ventoy
  as a supported install target).

Verify every ISO with the repo's checker before it touches the stick:

```powershell
.\scripts\checksum\check.ps1 -Path .\Win11_24H2_English_x64.iso
```

On a Linux clean machine, the bash twin emits the same manifest contract:

```bash
./scripts/checksum/check.sh Win11_24H2_English_x64.iso --out iso-manifest.csv
```

(Both twins hash SHA-256 and share the `Path,Hash` CSV contract, so a manifest
written by either side verifies with the other side's comparer:
`compare.sh` ↔ `compare.ps1`'s `Confirm-Integrity`.)

> [VERIFY] `scripts/checksum/check.ps1` computes **SHA-256**, not SHA-512. Match
> the algorithm to whatever hash your ISO source publishes. Never skip this step:
> a tampered ISO defeats the entire runbook.

**Step 0.3 — Build the Phoenix USB (Ventoy).**
1. Install **Ventoy** onto the ≥ 64 GB USB from the clean machine
   (Ventoy2Disk — this repartitions the stick; back up anything on it first).
2. Run the stager (static review only so far — **Windows testing required**
   before it touches a real stick):

   ```powershell
   .\tools\Build-PhoenixUsb.ps1 -UsbDrive "E:" -IsoDir ".\iso-staging" `
     -ComputerName "BRANDON-PC" -Username "brandon"
   ```

   On a **Linux** clean machine, the bash twin does the same job (reads the
   same JSON hash sidecar):

   ```bash
   ./tools/Build-PhoenixUsb.sh --usb-mount /media/phoenix --iso-dir ./iso-staging \
     --iso-hashes ./iso-staging/phoenix-iso-hashes.json \
     --computer-name BRANDON-PC --username brandon
   ```

   It verifies Ventoy is present, copies the ISO set with hash checks, writes
   `ventoy/ventoy.json` (the Analyze/Backup/Nuke/Reinstall menu aliases +
   auto-install wiring), writes `phoenix-config.json` + `autounattend.xml`,
   stages the Phoenix scripts, and writes `manifest.json`. It fails the build
   if any required asset is missing — a USB that silently skips steps is worse
   than no USB.
   > [VERIFY] The **Phoenix WinPE ISO is not built yet** (needs the ADK build
   > in BOOT-ARCHITECTURE.md §4). Until it lands, the TOOLKIT menu entry is
   > absent — Reinstall/Analyze/Backup/Nuke all work without it. The `$OEM$`
   > folder (Specialize.ps1 / DefaultUser.ps1) **does not exist in this repo
   > yet** either (see `VISION.md` Phase 3); until it lands, place post-install
   > scripts manually or run them after first logon.
3. Add your drivers to `phoenix\$WinPEDriver$` on the USB if the laptop needs
   them (network/storage drivers especially — test on the QEMU path if unsure).

**Step 0.4 — Sanity-check the stick on the clean machine.**
Boot the Phoenix USB on the clean machine once: confirm the Ventoy menu shows
the five entries (Analyze / Backup / Nuke / Reinstall / Toolkit) and that one
entry (e.g. SystemRescue) reaches its desktop. Then shut down — do not image
anything. This is also where you meet the **Secure Boot MOK enrollment screen**
for the first time: Ventoy is signed with its own key, so the blue MOK screen
appears once per machine — **enroll the key**, and Ventoy boots cleanly
thereafter. (If Ventoy won't boot and there's no MOK screen, check the
firmware's "Allow Microsoft 3rd Party UEFI CA" toggle.)

**Step 0.5 — Stage the Veeam Agent installer.**
Download the **Standalone Veeam Agent for Microsoft Windows (FREE)** installer from
veeam.com/windows-endpoint-server-backup-free.html on the clean machine and copy
it to a USB, so it can be installed offline after the reinstall. (Alternative on
the fresh install: `winget install -e --id Veeam.VeeamAgent`.)

> **Why Veeam, not Macrium, not Time Freeze:** Macrium Reflect Free is
> **discontinued** — do not standardize on it. ToolWiz Time Freeze (the "Time
> Freeze" Brandon half-remembered) is a **reboot-to-restore sandbox**, not a backup
> tool — it cannot produce an image of the infected disk and is no substitute for a
> real backup. Standard: **Rescuezilla** for the emergency bootable image,
> **Veeam Agent Free** for ongoing scheduled full-disk backups to Castle.

**Step 0.6 — If the infected laptop uses BitLocker, export the recovery key NOW.**
A Rescuezilla image of an encrypted disk is encrypted — without the recovery key
the image is a brick. This requires booting the infected Windows **once, fully
offline** (Ethernet unplugged, Wi-Fi off):

```powershell
manage-bde -protectors -get C:
```

Copy the 48-digit recovery key to paper or a USB. Then shut the machine down.
> [VERIFY] This is the one deliberate infected-OS boot in the runbook. If BitLocker
> is not in use, skip it entirely and never boot the infected OS again.

**Step 0.7 — Collect account credentials.**
Local/Microsoft account passwords, Wi-Fi password, license keys — everything the
fresh install will need. Write them down offline. The answer file /
`phoenix-config.json` carry install-time passwords in reversible form and this
repo is public (see BOOT-ARCHITECTURE.md §5 — **the USB is a key, keep it on
your person**); you will change them at Step 4.2.

---

## Phase 1 — ANALYZE (decide: clean or nuke?)

**Step 1.1 — Document symptoms.**
Write down what made you suspect infection (popups, new devices on your accounts,
unknown processes, performance, network activity). Dates and specifics. This is
your forensics baseline — and if you nuke, it's the only record of why.

**Step 1.2 — Boot `[1] ANALYZE — SystemRescue` from the Phoenix USB.**
Power on, open the one-time boot menu (F12/Del/Esc — varies by vendor), select
the Phoenix USB, then pick `[1] ANALYZE — SystemRescue` from the Ventoy menu.
**Do not boot Windows.** You get a full Linux rescue environment: file manager,
terminal, disk tools (testdisk, ddrescue) — inspect the suspect disk without
executing anything on it.

**Step 1.3 — Optional: bootable AV scan.**
Bootable rescue scanners inspect the disk **without booting the infected OS** —
same virus-safe principle as Rescuezilla imaging (Windows Defender Offline,
Kaspersky Rescue Disk, or ESET SysRescue Live). A rescue ISO can be dropped into
`ISOs/` on the stick later; Ventoy picks it up with no rebuild.
> The forensics toolkit (bootable AV rescue, Sysinternals, FTK Imager/Autopsy) is
> being standardized by a separate worker — consult its docs when they land.
> [VERIFY] Exact rescue-disk versions and boot steps for this week's specific
> build; treat anything from that toolkit as the source of truth once published.

**Step 1.4 — Make the call.**
Default assumption: **if you cannot identify the infection and remove it with
confidence, nuke.** Targeted malware doesn't advertise. The backup in Phase 2
preserves everything, so nuking costs you nothing but time.

**Step 1.5 — Note anything that must survive the wipe** (license keys, SSH keys,
authenticator exports, Ableton project folders) and confirm where each will be
captured in Phase 2's data-only backup.

---

## Phase 2 — BACKUP (image BEFORE wipe, always)

**Step 2.0 — Pre-flight safety checklist.** Run through this out loud before
imaging OR nuking. The scripts below enforce every line mechanically, but your
brain is the first interlock.

- [ ] **Enumerate, don't assume.** Run the disk inventory and read the table
  with your own eyes — model, serial, size, bus. Match the serial to the
  physical drive label (or the laptop's BIOS/UEFI storage page).
- [ ] **The boot USB is never the target.** It is listed so you can see it,
  and refused structurally. If your "target" row looks like a USB stick,
  stop — you picked the wrong disk.
- [ ] **Typed confirmation is exact.** Serial + model, exactly as printed,
  case-sensitive, on a real terminal. Piped input is refused. `echo` can
  never arm an image or a wipe.
- [ ] **Image before wipe, always.** The nuke gate checks for
  `image-proof.txt` from Step 2.6 and refuses without it.

**Step 2.1 — Air-gap the machine.** Ethernet unplugged. Wi-Fi disabled (or the
radio switched off in BIOS if available). The machine talks to nothing during
this phase — not even Castle. **Use only the direct-attached USB target.**

**Step 2.2 — Boot `[2] BACKUP — Rescuezilla` from the Phoenix USB.** Same stick,
same Ventoy menu, second entry. **Do not boot Windows.** Confirm you are in
Rescuezilla's environment before proceeding.

**Step 2.3 — Create the full-disk image.**
In Rescuezilla: Backup → select the **entire source disk** (not individual
partitions — you want the bootloader, recovery, and hidden partitions too) →
destination = the external USB drive → enable compression and the post-backup
integrity check. Name it clearly, e.g. `laptop-fulldisk-2026-09-09`. Let it run
to completion; a failing disk can take hours.

> **Scripted alternative:** `tools/Invoke-Backup.sh` (Linux rescue side) performs
> the same full-disk image headlessly — air-gap gate, serial-resolved source
> and USB target, verification ladder, and automatic image-proof emission —
> see `docs/BACKUP-MODULE.md`. The manual Rescuezilla path remains fully
> supported; the proof manifest is the contract either way.

**Scripted alternative (same safety contract, no GUI):** from a Linux shell on
the Rescuezilla desktop (target mounted at e.g. `/mnt/usb`):

```bash
./scripts/emergency/image_disk.sh \
    --src /dev/sda \
    --dest-dir /mnt/usb \
    --label laptop-fulldisk-2026-09-10 \
    --verify
```

This enforces the Step 2.0 checklist mechanically: explicit `lsblk`
enumeration, structural refusal of the boot/root disk and any mounted source,
refusal to overwrite an existing image, and a typed `SERIAL MODEL`
confirmation on a real TTY (piped input refused). It images with `dcfldd`
(hash-on-the-fly + progress) when available, else `dd` (`conv=noerror,sync`
so bad sectors become zero-filled gaps instead of aborting), then writes
`<label>.img` + `<label>.manifest.csv` (SHA-256, the same `Path,Hash`
contract as `scripts/checksum/check.sh`) and — with `--verify` — re-reads
the image and re-hashes before reporting success. **It will never image the
USB stick you booted from** (boot/root disk is refused, hard).

Windows twin for the WinPE side (same contract, .NET streamed copy with
progress + on-the-fly SHA-256):

```powershell
.\scripts\emergency\Invoke-Image.ps1 -Source 1 -DestDir E:\ -Label laptop-fulldisk-2026-09-10 -Verify
```

**Step 2.4 — VERIFY the image.**
Let Rescuezilla's post-backup check complete. Then independently confirm: the
image files exist on the target, sizes are plausible (compressed but non-trivial),
and — if the build supports it — open the image in Image Explorer / run the
"check image" step. Additionally, write a SHA-256 manifest of the image **now**,
while the target is still attached to the air-gapped machine, so the later
Castle copy (Step 2.6) can be proven bit-identical. (If you used
`image_disk.sh` in Step 2.3, the manifest is already written — skip straight
to verifying it.)
From a Linux shell on the
Rescuezilla desktop (target mounted at e.g. `/mnt/usb`):

```bash
./scripts/checksum/check.sh /mnt/usb/laptop-fulldisk-2026-09-09 \
    --out /mnt/usb/laptop-fulldisk-2026-09-09.manifest.csv
./scripts/checksum/compare.sh /mnt/usb/laptop-fulldisk-2026-09-09.manifest.csv
# expected tail:  -- N/N verified --
```

Keep the manifest file next to the image. It is the fingerprint the nuke gate
compares against after the copy.
> [VERIFY] Exact menu labels for the image-check step vary by Rescuezilla version.
> Minimum bar: files present, sizes sane, post-backup check green. **If the check
> fails, re-run the backup. Do not proceed to Phase 3 on a failed image.**
> The gate is: **verified image or no wipe.**

**Step 2.5 — Write the image-proof manifest.**
The nuke phase will not arm without machine-readable proof of the verified
image (runbook invariant 1, enforced in code). From the Backup environment
(or any Linux shell with the USB mounted), record it:

```bash
./tools/New-ImageProof.sh \
  --image-name laptop-fulldisk-2026-09-09 \
  --image-path /media/usb-target/laptop-fulldisk-2026-09-09 \
  --source-serial <serial-of-the-imaged-disk> \
  --source-dev /dev/nvme0n1 \
  --sha256 <64-hex-checksum-of-the-image> \
  --verified --verified-by brandon \
  --out /media/phoenix-usb/phoenix-logs/
```

`--verified` asserts YOU watched the backup tool's integrity check pass in
Step 2.4 — without it the manifest records `verified=NO` and the nuke gate
rejects it. The `source_serial` binds the proof to the disk it images: a
proof for disk A cannot arm a wipe of disk B. Keep the `.proof` file on the
Phoenix USB; you'll pass it to `Invoke-Nuke.sh --image-proof` in Phase 3.

**Step 2.6 — Take a separate data-only backup.**
Copy your user data (Documents, Desktop, Downloads triage, Ableton projects,
`~/.ssh`, configs, photos) to a **second, separate location** from the full
image. Belt and suspenders: this is what you actually restore from in Phase 4.
> Treat this folder as **dirty**. The full-disk image is the quarantine archive;
> the data backup is for selective restore only, after scanning.

**Step 2.7 — Quarantine and copy.**
Rename the full image `QUARANTINE-INFECTED-<date>`. Move the external drive to a
**clean machine** and copy the image onto Castle's 10TB drive for long-term
storage — the copy must be initiated from the clean side, never over the network
from the infected laptop. Use the repo's copy-verify script, which fingerprints
the image, copies it, re-fingerprints the copy, and **fails closed** on any
mismatch (a bad copy reports failure; it never reports success):

```bash
# on the CLEAN machine -- set once, e.g. in ~/.profile
export PHOENIX_CASTLE_TARGET=/mnt/castle/quarantine   # <-- real share path goes here
./scripts/emergency/Send-ImageToCastle.sh \
    -i /mnt/usb/laptop-fulldisk-2026-09-09
```

Windows twin (same contract, robocopy instead of rsync):

```powershell
$env:PHOENIX_CASTLE_TARGET = "\\CASTLE\quarantine"   # <-- real share path goes here
.\scripts\emergency\Send-ImageToCastle.ps1 -ImageDir E:\laptop-fulldisk-2026-09-09
```

The script requires you to type `CLEAN` on a real terminal (piped input is
refused), writes the copy to `QUARANTINE-INFECTED-<date>/` under the target, and
leaves `image-proof.txt` beside it — the fingerprint record Phase 3's nuke gate
checks. Also re-run the manifest from Step 2.4 against the copy; both must agree.

**Phase 2 exit gate:** verified full-disk image exists in two places (external
drive + Castle copy in progress or done) AND an **image-proof manifest** exists
on the Phoenix USB (Step 2.5) AND a separate data-only backup exists.
Only then may Phase 3 begin.

---

## Phase 3 — NUKE (only after verified backups)

**Step 3.1 — Confirm the exit gate.** Before anything destructive:
- [ ] Verified full-disk image exists (Step 2.4 green)
- [ ] Image copied/quarantined (Step 2.7)
- [ ] BitLocker recovery key in hand (Step 0.6, if applicable)
- [ ] Account credentials in hand (Step 0.7)
- [ ] **Media type identified** (HDD vs SSD/NVMe — determines the sanitize
      method; when in doubt, treat as SSD)

**Step 3.2 — Boot `[3] NUKE — ShredOS` and sanitize method-per-media.**
ShredOS boots straight into nwipe. **Do not nwipe-only an SSD** — nwipe cannot
reach wear-levelled, overprovisioned, or remapped blocks. The rule:
- **Spinning HDD:** nwipe with an appropriate pass.
- **SATA/NVMe SSD:** firmware-level sanitize **first** (`nvme format --ses=1` /
  `nvme sanitize`, manufacturer Secure Erase, or `hdparm` ATA Secure Erase —
  all available from a Linux shell), then nwipe as a supplement if desired.
- **Unknown media:** treat as SSD.

> The interlocked nuke UX has landed as `tools/Invoke-Nuke.sh` (bash, runs in
> the Linux boot env — typed confirmation, disk enumeration by model/serial/
> size, never auto-selects a target, method-per-media per BOOT-ARCHITECTURE.md
> §8). Arming **requires** `--image-proof <file>` — the manifest written in
> Step 2.5 — and the proof's `source_serial` must match the nuke target
> (invariant 1, enforced in code; see `docs/NUKE-SAFETY.md` interlock 11).
> The only bypass is `--skip-image-gate`, which demands typing
> `NUKE WITHOUT BACKUP` on a real console and is logged — true emergencies
> only. Until it is exercised in the QEMU test plan (docs/NUKE-TEST-PLAN.md),
> the ShredOS
> manual flow is the only wipe path — match the target disk's serial to the
> physical drive with your own eyes, twice.
>
> `tools/Invoke-Nuke.sh` is **dry-run by default**: no flags (or `--whatif`)
> only enumerates disks and exits. Always run this first and match the target
> serial to the physical drive with your own eyes (see Appendix D for what the
> enumeration output looks like and which columns you are reading).

**Step 3.3 — Sanity re-check post-wipe.** After the wipe completes, boot
`[2] BACKUP — Rescuezilla` again and confirm the disk reads as
unpartitioned/empty. A wipe you didn't verify is a wipe you didn't do.

---

## Phase 4 — REINSTALL (clean install + restore)

**Step 4.1 — Boot `[4] REINSTALL — Windows 11 (unattended)` from the Phoenix USB.**
Ventoy's `auto_install` feeds `autounattend.xml` to the Windows installer
automatically: diskpart wipe of DISK 0, DISM-apply of Windows 11 Pro
(`/CheckIntegrity /Verify`), `$WinPEDriver$` driver injection, WPBT disable,
unattended OOBE straight to desktop. **Disconnect all USB drives except the
Phoenix USB before this step** — the answer file wipes DISK 0 with no confirmation.
Sail to the desktop.

**Step 4.2 — Change the install-time passwords immediately.** The credentials in
`phoenix-config.json` / `autounattend.xml` are throwaway and effectively public
(see BOOT-ARCHITECTURE.md §5). Set real passwords / PIN on first logon, and
enable BitLocker — this time, store the recovery key somewhere safe **off** the
machine (you'll thank Phase-0 Brandon).

**Step 4.3 — Install apps via Chocolatey.**
Run the repo's Chocolatey flow (`scripts/chocolatey/install-chocolatey-online.ps1`,
then `scripts/chocolatey/apps.ps1` driven by `data/choco-install/apps.json` —
Chrome, Steam, Ableton, and the rest of your app picker list).
> [VERIFY] The unattended `$OEM$` hook (Specialize.ps1/DefaultUser.ps1) doesn't
> exist in the repo yet — until it does, this step runs manually at first logon.
> Network access is fine now: the machine is clean.

**Step 4.4 — Install Veeam Agent and set up scheduled backups.**
Install the staged Veeam Agent (Step 0.5), create the Veeam recovery media on a
USB, and configure a scheduled **entire-computer** backup job targeting Castle's
10TB drive. This is the ongoing-backup standard going forward — the thing that
makes the *next* emergency a restore instead of a crisis.

**Step 4.5 — Restore data selectively.**
From the **data-only** backup (Step 2.6), copy back what you need — and scan it
with Defender first. Restore files, not installers; reinstall applications fresh
from their sources. **Never boot or "restore" the quarantined full-disk image**
except on an isolated forensics setup.

**Step 4.6 — Verify clean.**
Full Defender scan. Windows Update to current. Eyeball Task Scheduler, Startup
apps, and installed programs for anything you don't recognize. Re-check your
Microsoft/Google "My Devices" pages for the unknown devices that started this.

---

## Appendix A — What "quarantined" means, concretely

- The infected image lives on Castle's 10TB drive under a clearly labeled
  `QUARANTINE-INFECTED-<date>/` folder.
- It is never mounted, booted, or opened on a daily-driver machine.
- Forensics access happens only from an isolated setup (separate worker's toolkit:
  FTK Imager / Autopsy on a machine that doesn't touch your accounts or network).
- Keep it until the incident is understood or you're certain you never need it —
  disk is cheap, regret is expensive.

## Appendix B — Don'ts (quick reference)

- Don't install ToolWiz Time Freeze as a "backup" — it's reboot-to-restore, not
  an imaging tool, and it gives zero protection against disk failure or theft.
- Don't standardize on Macrium Reflect Free — it's discontinued.
- Don't boot the infected OS "just to check something" after Phase 0, Step 0.6.
- Don't image over the network from the infected machine — direct-attached USB only.
- Don't restore executables/installers from the data backup — reinstall from sources.
- Don't nwipe-only an SSD — firmware-level sanitize first (Step 3.2).
- Don't leave the Phoenix USB in a machine or lying around — it carries
  install-time credentials in reversible form (BOOT-ARCHITECTURE.md §5).

## Appendix C — Founder questions (need Brandon's answers)

1. Which machine is the **clean machine** for Phase 0? (Prep must not touch the
   infected laptop; if there's no second machine, say so — that changes the plan.)
2. Where exactly is Castle's 10TB target — SMB share name/path, and which
credentials? Needed for the Veeam scheduled job in Step 4.4.
3. Is the ≥ 64 GB Phoenix USB on hand, or does it need to be bought?
4. Is the infected laptop's disk BitLocker-encrypted? (Determines whether
   Step 0.6 is required.) And is it HDD or SSD/NVMe? (Determines the nuke method.)
5. ~~Should the Analyze/Backup/Nuke/Reinstall **menu** be built into the Phoenix
   USB before this run?~~ **Answered:** Ventoy *is* the menu (BOOT-ARCHITECTURE.md §3).
## Appendix D — Disk enumeration examples (what you're reading)

All outputs below are **EXAMPLES** — fictional serials. Your screen will show
your real disks. The columns that matter for the interlock are **serial** and
**model**: the typed confirmation in Phase 3 must match them exactly as shown.

**Linux — the raw inventory source** (`lsblk -dno NAME,MODEL,SERIAL,SIZE,TRAN,RM -P`,
what `tools/Get-DiskInventory.sh` parses):

```
NAME="sda" MODEL="Samsung SSD 870 EVO 1TB" SERIAL="S5YBNJ0R123456A" SIZE="931.5G" TRAN="sata" RM="0"
NAME="sdb" MODEL="SanDisk Ultra USB 3.0"   SERIAL="4C530001234567890123"        SIZE="57.3G"  TRAN="usb"  RM="1"
NAME="nvme0n1" MODEL="WD Black SN850X 1TB" SERIAL="234567890123"                SIZE="931.5G" TRAN="nvme" RM="0"
```

**Linux — the structured contract** (`./tools/Get-DiskInventory.sh`, same shape
as the `.ps1` twin; this is what the confirmation gate reads — never your memory):

```json
[
  {
    "id": 1,
    "dev": "/dev/sda",
    "model": "Samsung SSD 870 EVO 1TB",
    "serial": "S5YBNJ0R123456A",
    "size_bytes": 1000204886016,
    "size_human": "931.5 GiB",
    "transport": "SATA",
    "removable": false,
    "mounted": false,
    "media": "ssd"
  },
  {
    "id": 2,
    "dev": "/dev/sdb",
    "model": "SanDisk Ultra USB 3.0",
    "serial": "4C530001234567890123",
    "size_bytes": 61505273856,
    "size_human": "57.3 GiB",
    "transport": "USB",
    "removable": true,
    "mounted": true,
    "media": "usb"
  }
]
```

Note disk 2 (`/dev/sdb`, the boot USB): `"mounted": true` — it is **listed but
structurally refused** as a nuke target. The menu shows it greyed out on purpose;
hiding it would invite "where did my disk go?" workarounds.

**NVMe detail** (`nvme list` — confirms the serial the interlock will re-read
immediately before execution):

```
Node             SN                   Model                Namespace Usage
/dev/nvme0n1     234567890123         WD Black SN850X 1TB  1         931.51 GB
```

**Windows — the same inventory from the WinPE side** (`Get-Disk | Format-Table`):

```
Number FriendlyName          SerialNumber       Size BusType
------ ------------          ------------       ---- -------
0      Samsung SSD 870 EVO   S5YBNJ0R123456A    931 GB SATA
1      SanDisk Ultra USB 3.0 4C530001234567890123 57 GB USB
```

**What the typed confirmation looks like** (Phase 3, Step 3.2 — real TTY only):

```
TARGET: [1] Samsung SSD 870 EVO 1TB  SN S5YBNJ0R123456A  931.5 GiB
Type the serial and model EXACTLY as shown to arm the wipe:
> S5YBNJ0R123456A Samsung SSD 870 EVO 1TB
```

Physical cross-check before typing: the serial on the drive's label (or in the
laptop's BIOS/UEFI storage page) must match the `SERIAL`/`SerialNumber` column
above. If the on-screen serial doesn't match the hardware you intend to wipe,
**stop** — the fingerprint gate (§4 of `docs/NUKE-SAFETY.md`) will also refuse a
disk that changed since the Analyze snapshot, but your eyes are the first gate.
