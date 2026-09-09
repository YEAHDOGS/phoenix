# Phoenix Emergency Runbook — Backup + Nuke + Reinstall

**Purpose:** the exact steps Brandon follows THIS WEEK to deal with a suspected-infected laptop.
**Flow:** boot Phoenix USB → menu: **Analyze / Backup / Nuke / Reinstall.**

> Status note: the one-step Phoenix USB menu (Analyze / Backup / Nuke / Reinstall)
> is the target flow (see `VISION.md`). Today these phases run as manual steps that
> the menu will eventually orchestrate. This runbook is written so it works now,
> without the menu, and maps 1:1 onto the future menu items.

---

## Safety invariants (non-negotiable)

Read these before touching anything. Every phase below enforces them.

1. **Never wipe before a VERIFIED image exists.** A backup you haven't verified is
   not a backup — it's a hope. The nuke phase must refuse to run without proof of a
   verified image.
2. **Keep the infected image quarantined for forensics.** Label it clearly
   (`QUARANTINE-INFECTED-<date>`), store it on Castle's 10TB drive, and never mount
   it on a production machine. It is evidence, not a restore source.
3. **Keep the infected machine off the network during imaging.** Unplug Ethernet,
   disable Wi-Fi, do not attach network shares in Rescuezilla. Malware can't phone
   home, and a network share can't be touched by the infection, if the machine is
   air-gapped. Image to a **direct-attached USB drive**.
4. **Assume every destructive step is irreversible.** `CLEAN` on a disk, the answer
   file's diskpart section, and `Invoke-Nuke` have no undo. Type confirmations are
   there to save you from yourself.

---

## Phase 0 — PREP (do all of this on a CLEAN machine)

Everything in this phase runs on a machine you trust — not the infected one. Prep
once, execute later.

**Step 0.1 — Inventory your media.**
- 1× USB ≥ 16 GB → the **Phoenix USB** (Windows installer + answer file + `$OEM$`).
- 1× USB ≥ 2 GB → the **Rescuezilla USB** (emergency imaging).
- 1× large external USB drive, **at least as big as the infected laptop's disk**
  (the image will be compressed, but plan for full-size headroom) → the **image target**.
- Optional: a spare USB for Veeam recovery media and installers.

**Step 0.2 — Download the Windows 11 ISO and verify its hash.**
Download the ISO from Microsoft, then verify it with the repo's checker:

```powershell
.\scripts\checksum\check.ps1 -Path .\Win11_24H2_English_x64.iso
```

> [VERIFY] `scripts/checksum/check.ps1` computes **SHA-256**, not SHA-512. Microsoft
> publishes SHA-256 hashes for Windows 11 ISOs, so check.ps1 works as-is against
> the official published hash — **match the algorithm to whatever hash your ISO
> source publishes**. Never skip this step: a tampered ISO defeats the entire runbook.

**Step 0.3 — Build the Phoenix USB.**
1. Copy the verified ISO's contents onto the Phoenix USB.
2. Drop `win-install/autounattend.xml` at the **root** of the USB. It wipes DISK 0,
   applies the Windows 11 Pro image with DISM, injects `$WinPEDriver$` drivers,
   skips OOBE, and creates the install-time local accounts (see
   `win-install/README.md` for the full sequence).
3. Add your drivers to a `$WinPEDriver$` folder on the USB if the laptop needs them
   (network/storage drivers especially — test on the QEMU path if unsure).
4. Stage the `$OEM$` scripts on the USB.
   > [VERIFY] The `$OEM$` folder (Specialize.ps1 / DefaultUser.ps1) **does not
   > exist in this repo yet** (see `VISION.md` Phase 3). Until it lands, place your
   > post-install scripts manually or run them after first logon.

**Step 0.4 — Make the Rescuezilla USB.**
1. On the clean machine, download the latest Rescuezilla ISO from the project's
   releases page (`github.com/rescuezilla/rescuezilla` → Releases, 64-bit ISO —
   v2.6.x current as of this writing).
2. Flash it to USB with Rufus or balenaEtcher.
3. Sanity-check: boot the Rescuezilla USB on the clean machine once to confirm it
   reaches the desktop (then shut it down — do not image anything).
   > Rescuezilla 2.6 carries an updated SBAT shim so it should boot under UEFI
   > Secure Boot. If you see an "SBAT self-check failed" error, re-download the
   > newest build; use "Graphical Fallback Mode" from its boot menu for display issues.

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
fresh install will need. Write them down offline. The answer file contains
throwaway install-time passwords (they are plaintext in this public repo — see
`win-install/README.md`); you will change them at Step 4.2.

---

## Phase 1 — ANALYZE (decide: clean or nuke?)

**Step 1.1 — Document symptoms.**
Write down what made you suspect infection (popups, new devices on your accounts,
unknown processes, performance, network activity). Dates and specifics. This is
your forensics baseline — and if you nuke, it's the only record of why.

**Step 1.2 — Run a bootable AV scan (optional but recommended).**
Bootable rescue scanners inspect the disk **without booting the infected OS** —
same virus-safe principle as Rescuezilla imaging (Windows Defender Offline,
Kaspersky Rescue Disk, or ESET SysRescue Live).
> The forensics toolkit (bootable AV rescue, Sysinternals, FTK Imager/Autopsy) is
> being standardized by a separate worker — consult its docs when they land.
> [VERIFY] Exact rescue-disk versions and boot steps for this week's specific
> build; treat anything from that toolkit as the source of truth once published.

**Step 1.3 — Make the call.**
Default assumption: **if you cannot identify the infection and remove it with
confidence, nuke.** Targeted malware doesn't advertise. The backup in Phase 2
preserves everything, so nuking costs you nothing but time.

**Step 1.4 — Note anything that must survive the wipe** (license keys, SSH keys,
authenticator exports, Ableton project folders) and confirm where each will be
captured in Phase 2's data-only backup.

---

## Phase 2 — BACKUP (image BEFORE wipe, always)

**Step 2.1 — Air-gap the machine.** Ethernet unplugged. Wi-Fi disabled (or the
radio switched off in BIOS if available). The machine talks to nothing during
this phase — not even Castle. **Use only the direct-attached USB target.**

**Step 2.2 — Boot the Rescuezilla USB.** Power on, open the one-time boot menu
(F12/Del/Esc — varies by vendor), select the Rescuezilla USB. **Do not boot
Windows.** Confirm you are in Rescuezilla's environment before proceeding.

**Step 2.3 — Create the full-disk image.**
In Rescuezilla: Backup → select the **entire source disk** (not individual
partitions — you want the bootloader, recovery, and hidden partitions too) →
destination = the external USB drive → enable compression and the post-backup
integrity check. Name it clearly, e.g. `laptop-fulldisk-2026-09-09`. Let it run
to completion; a failing disk can take hours.

**Step 2.4 — VERIFY the image.**
Let Rescuezilla's post-backup check complete. Then independently confirm: the
image files exist on the target, sizes are plausible (compressed but non-trivial),
and — if the build supports it — open the image in Image Explorer / run the
"check image" step.
> [VERIFY] Exact menu labels for the image-check step vary by Rescuezilla version.
> Minimum bar: files present, sizes sane, post-backup check green. **If the check
> fails, re-run the backup. Do not proceed to Phase 3 on a failed image.**
> The gate is: **verified image or no wipe.**

**Step 2.5 — Take a separate data-only backup.**
Copy your user data (Documents, Desktop, Downloads triage, Ableton projects,
`~/.ssh`, configs, photos) to a **second, separate location** from the full
image. Belt and suspenders: this is what you actually restore from in Phase 4.
> Treat this folder as **dirty**. The full-disk image is the quarantine archive;
> the data backup is for selective restore only, after scanning.

**Step 2.6 — Quarantine and copy.**
Rename the full image `QUARANTINE-INFECTED-<date>`. Move the external drive to a
**clean machine** and copy the image onto Castle's 10TB drive for long-term
storage — the copy must be initiated from the clean side, never over the network
from the infected laptop. The infected machine stays air-gapped until it is wiped.

**Phase 2 exit gate:** verified full-disk image exists in two places (external
drive + Castle copy in progress or done) AND a separate data-only backup exists.
Only then may Phase 3 begin.

---

## Phase 3 — NUKE (only after verified backups)

**Step 3.1 — Confirm the exit gate.** Before anything destructive:
- [ ] Verified full-disk image exists (Step 2.4 green)
- [ ] Image copied/quarantined (Step 2.6)
- [ ] BitLocker recovery key in hand (Step 0.6, if applicable)
- [ ] Account credentials in hand (Step 0.7)

**Step 3.2 — Follow the nuke module's interlocked flow.**
`tools/Invoke-Nuke.sh` (bash — the wipe runs in the Linux boot environment,
so there is deliberately no `.ps1`) implements the safety flow:

- **Dry-run default:** no flags (or `--whatif`) only enumerates disks and exits.
- **Explicit enumeration:** numbered table of model / serial / size / bus / media class.
- **Structural refusals:** the boot USB and any disk with mounted partitions are refused, hard.
- **Two-factor typed confirmation, real TTY only:** type the target's exact **serial AND the exact size as displayed** (e.g. `SATATEST001 931.5 GB`, or `NUKE <serial> <size>`). Piped or scripted input is refused — `echo $serial | ...` can never arm a wipe.
- **Abort window:** 5-second countdown after arming (Ctrl-C aborts).
- **Identity re-check:** the serial is re-read immediately before execution; if it changed, the run aborts.
- **Method per media (NIST 800-88):** HDD → nwipe DoD 5220.22-M; SATA SSD → ATA Secure Erase; NVMe → `nvme format --ses=1`.
- **Full log** written to the USB.

Do a dry run first (`Invoke-Nuke.sh` with no flags). Match the serial number to the physical drive with your own eyes before typing anything.
> **Branch note:** the nuke module is being built on the nuke workstream branch
> and is not in every worktree yet. Before executing Phase 3, confirm
> `tools/Invoke-Nuke.sh` is present on your USB and read its `--help`. If it
> isn't there yet, the answer file's own diskpart wipe (Phase 4, Step 4.1) is
> the only wipe path — it targets DISK 0 with no confirmation, so triple-check
> boot order and disconnect all USB target disks first.

**Step 3.3 — Sanity re-check post-wipe.** After the wipe completes, boot
Rescuezilla again and confirm the disk reads as unpartitioned/empty. A wipe you
didn't verify is a wipe you didn't do.

---

## Phase 4 — REINSTALL (clean install + restore)

**Step 4.1 — Boot the Phoenix USB and install unattended.**
Insert the Phoenix USB, boot from it. `win-install/autounattend.xml` runs the
full sequence: diskpart wipe of DISK 0, DISM-apply of Windows 11 Pro
(`/CheckIntegrity /Verify`), `$WinPEDriver$` driver injection, WPBT disable,
unattended OOBE straight to desktop. **Disconnect all USB drives except the
Phoenix USB before this step** — the answer file wipes DISK 0 with no confirmation.
Sail to the desktop.

**Step 4.2 — Change the install-time passwords immediately.** The credentials in
`autounattend.xml` are throwaway and effectively public (this repo is public).
Set real passwords / PIN on first logon, and enable BitLocker — this time, store
the recovery key somewhere safe **off** the machine (you'll thank Phase-0 Brandon).

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
From the **data-only** backup (Step 2.5), copy back what you need — and scan it
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

## Appendix C — Founder questions (need Brandon's answers)

1. Which machine is the **clean machine** for Phase 0? (Prep must not touch the
   infected laptop; if there's no second machine, say so — that changes the plan.)
2. Where exactly is Castle's 10TB target — SMB share name/path, and which
   credentials? Needed for the Veeam scheduled job in Step 4.4.
3. Are the Phoenix USB and Rescuezilla USB already on hand, or do they need to be
   bought? (Sizes: ≥16 GB and ≥2 GB.)
4. Is the infected laptop's disk BitLocker-encrypted? (Determines whether
   Step 0.6 is required.)
5. Should the Analyze/Backup/Nuke/Reinstall **menu** be built into the Phoenix USB
   before this run, or are the manual phases in this runbook sufficient for
   this week's emergency?
