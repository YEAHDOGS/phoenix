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
   > post-install hooks (Specialize.ps1 / DefaultUser.ps1 / FirstLogon.ps1)
   > **now exist** in `oem/` and both stager twins copy them to the USB root
   > automatically (fail-closed if missing).
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

**Step 2.1 — Air-gap the machine.** Ethernet unplugged. Wi-Fi disabled (or the
radio switched off in BIOS if available). The machine talks to nothing during
this phase — not even Castle. **Use only the direct-attached USB target.**

**Step 2.2 — Boot `[2] BACKUP — Rescuezilla` from the Phoenix USB.** Same stick,
same Ventoy menu, second entry. **Do not boot Windows.** Confirm you are in
Rescuezilla's environment before proceeding.

**Step 2.3 — Create the full-disk image (scripted path, preferred).**
From the Backup environment (or any Linux shell with the Phoenix USB mounted),
run the native imager — chunked, resumable, SHA-512-verified, and it mints the
Step 2.5 proof itself:

```bash
./tools/phoenix-backup.sh \
  --source /dev/nvme0n1 \
  --source-serial <serial-of-the-infected-disk> \
  --out /media/usb-target/laptop-fulldisk-2026-09-09 \
  --proof-out /media/phoenix-usb/phoenix-logs/ \
  --operator brandon
```

- `--source` is the **entire source disk** (not a partition — you want the
  bootloader, recovery, and hidden partitions too). Get `--source-serial` from
  `lsblk -o NAME,SERIAL` (it binds the proof to this disk; a proof for disk A
  cannot arm a wipe of disk B).
- Interrupt-safe: chunks already imaged *and verified* are skipped on re-run;
  a corrupted chunk file is detected by hash and re-imaged. Verification
  decompresses every chunk and checks the whole-stream SHA-512 — the manifest
  (`backup.manifest`) and the nuke-gate `.proof` are written **only** on
  `verify=PASS`.
- If the target fills or the machine dies mid-run, just re-run the same
  command — it resumes where it stopped.
- **Compression + chunking decisions (the defaults, and why).** Chunks default
  to `--chunk-mib 512` (512 MiB): small enough that a lost chunk costs minutes,
  not hours, on resume; big enough that a 1 TB disk is only ~2,000 files. Each
  chunk is individually SHA-512 hashed, so the manifest can prove exactly
  which chunks survived an interruption.
- **zstd verdict:** `--compressor auto` (the default) picks **zstd** when the
  boot environment has it, else **gzip**, else uncompressed. gzip is present in
  every rescue environment we boot; zstd ships in some and not others — so
  `auto` degrades gracefully instead of failing. The compressor actually used
  is recorded in `backup.manifest` and the resume state file, and a re-run
  with a *different* compressor is refused as a hard failure (the chunks don't
  mix). If you want a deterministic run, pass one explicitly
  (e.g. `--compressor gzip`). The WinPE twin uses DISM's own WIM compression
  (`-Compress Max` default) and records `compressor=dism-wim` in its manifest.

**Step 2.3 (GUI alternative) — Rescuezilla.** If you prefer a GUI: in
Rescuezilla, Backup → select the **entire source disk** → destination = the
external USB drive → enable compression and the post-backup integrity check.
Name it clearly, e.g. `laptop-fulldisk-2026-09-09`. Let it run to completion;
a failing disk can take hours. Afterwards you still need Step 2.5 (manual
proof minting) — the scripted path above does it for you.

**Step 2.4 — VERIFY the image.**
Let Rescuezilla's post-backup check complete. Then independently confirm: the
image files exist on the target, sizes are plausible (compressed but non-trivial),
and — if the build supports it — open the image in Image Explorer / run the
"check image" step.
> [VERIFY] Exact menu labels for the image-check step vary by Rescuezilla version.
> Minimum bar: files present, sizes sane, post-backup check green. **If the check
> fails, re-run the backup. Do not proceed to Phase 3 on a failed image.**
> The gate is: **verified image or no wipe.**

**Step 2.5 — Write the image-proof manifest.**
The nuke phase will not arm without machine-readable proof of the verified
image (runbook invariant 1, enforced in code). **If you used the scripted
path in Step 2.3, this step is already done** — `phoenix-backup.sh` mints the
proof itself, only after its own verification passes. This manual form is for
the Rescuezilla GUI path. From the Backup environment (or any Linux shell with
the USB mounted), record it:

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
(On a Windows/WinPE machine the exact-parity twin `tools\New-ImageProof.ps1`
writes the same manifest with `-ImageName`, `-ImagePath`, `-SourceSerial`,
`-Sha256`, `-Verified`, etc. — the Linux nuke gate accepts either.)

`--verified` asserts YOU watched the backup tool's integrity check pass in
Step 2.4 — without it the manifest records `verified=NO` and the nuke gate
rejects it. The `source_serial` binds the proof to the disk it images: a
proof for disk A cannot arm a wipe of disk B. Keep the `.proof` file on the
Phoenix USB; you'll pass it to `Invoke-Nuke.sh --image-proof` in Phase 3.

**Step 2.6 — Take a separate data-only backup (scripted path, preferred).**
Copy your user data (Documents, Desktop, Downloads triage, Ableton projects,
`~/.ssh`, configs, photos) to a **second, separate location** from the full
image — this is what you actually restore from in Phase 4. The native tool
mounts the infected volume **read-only** (never read-write), skips executables
by default, and hashes every file:

```bash
./tools/phoenix-data-backup.sh \
  --source-dev /dev/nvme0n1p3 \
  --out /media/usb-target2/laptop-data-2026-09-09 \
  --extra "Users/brandon/Ableton Projects:license-keys.txt" \
  --operator brandon
```

- `--source-dev` is the **Windows partition** (e.g. the `p3` on the infected
  disk); the tool mounts it `ro,noexec,nodev,nosuid` itself and unmounts on
  exit. Pass `--source-dir /mnt/x` instead if you already mounted it read-only
  yourself.
- Without `--profiles`, every non-system profile under `Users/` is backed up
  (`Public`/`Default*` are excluded unless named explicitly). Per profile:
  Documents, Desktop, Downloads, Pictures, Videos, Music, `.ssh`.
- `--extra` takes `:`-separated paths **relative to the volume root** for
  anything outside the profile folders (Ableton project folders elsewhere,
  license exports). Paths escaping the volume root are refused.
- **Dirty-data contract:** `*.exe/*.msi/*.dll/*.ps1/...` are skipped (recorded
  in `skipped-executables.txt`, never restored — reinstall from sources);
  every copied file gets a SHA-256 in `files.sha256`; the output carries
  `DIRTY-NOT-FORENSIC-SAFE.txt` (scan-before-restore) and
  `data-backup.manifest` records `contamination=DIRTY`, `verify=PASS`.
  Pass `--include-exe` only if you truly know what you are doing.
- Fail-closed: the target must be a local direct-attached drive (network
  filesystems and UNC paths refused), and `--out` may never sit inside the
  source volume.
- WinPE twin: `.\tools\New-PhoenixDataBackup.ps1 -Source "C:" -Out
  "E:\laptop-data-2026-09-09" -Operator brandon` — robocopy-based copy of the
  same profile set, same manifest/schema/dirty contract (see the tool header).

> Manual alternative: copy the folders by hand from the rescue file manager.
> You lose the hash manifest and the exe-skip ledger — the scripted path is
> strongly preferred.
> Treat this folder as **dirty**. The full-disk image is the quarantine archive;
> the data backup is for selective restore only, after scanning.

**Step 2.7 — Quarantine and copy (scripted path, preferred).**
Move the external drive to a **clean machine** (never the infected laptop —
this tool runs from the clean side) and copy the verified image onto Castle's
10TB drive, straight into the quarantine layout:

```bash
./tools/phoenix-quarantine-copy.sh \
  --source /media/usb-target/laptop-fulldisk-2026-09-09 \
  --target /media/castle-10tb \
  --date 2026-09-09 \
  --operator brandon
```

- Fail-closed: it refuses to copy unless the image has machine-readable proof
  of verification — a `phoenix-backup/1` manifest with `verify=PASS` (the
  scripted Step 2.3 path mints this automatically), or `--image-proof <file>`
  pointing at a `phoenix-image-proof/1` manifest with `verified=YES` (the
  Rescuezilla GUI path — mint it in Step 2.5 first).
- It refuses network filesystems (nfs/cifs/smb/sshfs/UNC) — the quarantine
  copy goes to a **direct-attached** drive only, same air-gap principle as
  the imaging step.
- Every chunk is re-verified on the target after the copy (per-chunk SHA-512
  from the backup state file, then the whole-stream SHA-512 and chunk-set
  SHA-256 against the manifest — the same verification the imager itself
  runs). `quarantine-copy.manifest` records `verify=PASS` only when all checks
  pass. The copy is resumable: re-run skips already-verified chunks and
  re-copies mismatched ones.
- It writes the image to `<target>/QUARANTINE-INFECTED-<date>/<image-name>/`
  and copies the manifest/state/proof alongside it for the forensics paper
  trail.

> Manual alternative: rename the full image `QUARANTINE-INFECTED-<date>`,
> move the external drive to a clean machine, and copy it onto Castle's 10TB
> drive — the copy must be initiated from the clean side, never over the
> network from the infected laptop. You lose the post-copy re-verification
> and the copy manifest — the scripted path is strongly preferred.
> The infected machine stays air-gapped until it is wiped.

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
> The unattended `$OEM$` hook now exists in the repo (`oem/$OEM$/$$/Setup/Scripts/FirstLogon.ps1`,
> staged onto the USB by both `Build-PhoenixUsb` twins): on first logon it installs apps
> **offline-first** from the USB's `cache/apps/*.nupkg` with zero network, and only goes
> online with an explicit `-AllowOnline` opt-in. If the stager built your stick without an
> app cache, this step runs manually at first logon as before.
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
