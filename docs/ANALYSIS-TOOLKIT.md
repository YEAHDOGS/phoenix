# Phoenix Analysis Toolkit

Owner: Analyze worker · Branch: `jack/phoenix-analysis`

The "Analyze" entry in the Phoenix boot menu carries a heavyweight, all-free
forensics/malware-analysis kit. Its purpose: answer *"what is on this machine?"*
after the disk has been imaged, without ever needing to boot the infected OS.

**Golden rule: IMAGE FIRST, THEN ANALYZE THE IMAGE.**
Step 0 of every analysis is the Backup worker's Rescuezilla image, hash-verified
and stored on cold media. All inspection after that happens against the *image*
(mounted read-only) or a bootable scanner's own OS. The infected Windows
installation is booted **only** as a last resort, with the network cable
unplugged, because booting it executes whatever is resident.

## Workflow order

1. **Image** (Backup worker's domain) — Rescuezilla full-disk image of the
   infected drive, written to external/staging media, SHA-256 verified.
   Nothing below starts until the image exists.
2. **Bootable AV sweep (offline, no infected OS booted)** — Boot the Phoenix
   USB → Analyze → Kaspersky Rescue Disk. It runs its own Linux environment,
   updates definitions if a network is present, and scans the *offline* disk.
   Malware never executes, so it cannot hide or fight back.
3. **Mount the image, read-only** (staging machine) — FTK Imager mounts the
   Rescuezilla/DD image as a read-only drive letter. Browse the filesystem,
   recover deleted files, export suspicious binaries for hash lookup.
4. **Autostart/persistence inspection** — Sysinternals Autoruns against the
   mounted offline Windows (`File → Analyze Offline System`, pointed at the
   mounted `Windows` directory). This finds Run keys, services, drivers,
   scheduled tasks, and WMI persistence the scanner may have missed.
5. **Second-opinion scans of the mounted image** (staging machine) —
   Microsoft Defender via `MpCmdRun -Scan` pointed at the mount, plus the
   portable Emsisoft Emergency Kit. Two more engines, zero boot of the suspect.
6. **Deep forensics** (staging machine only) — Autopsy ingests the disk image:
   timeline reconstruction, registry hives, browser artifacts, deleted-file
   carving, keyword search. This is the "write the report" phase.
7. **Live triage — last resort only** — If the image can't answer the question
   (e.g. fileless/memory-only malware), boot the infected OS *air-gapped*
   with Process Explorer / Process Monitor / TCPView from the USB and capture
   behavior quickly. Assume the box is hostile while it runs.

## The toolkit

### Kaspersky Rescue Disk 18 — bootable offline AV scanner

A free, self-contained bootable environment (Gentoo Linux + Kaspersky engine,
~667 MB ISO) that scans and disinfects a PC whose OS you deliberately do not
boot. Because the suspect OS never loads, rootkits and bootkits can't cloak
themselves, which is exactly why it leads the workflow. It updates its
definitions over the network when one is available and ships a file manager,
registry editor, and browser for triage inside the rescue environment.
Verified still maintained and free in September 2026 (build 18.0.11.3d,
updated 2026-04-28, mirrored 2026-09-07). One caveat for a US-based builder:
Kaspersky's official US download page blocks US customers, so the ISO is
fetched from Kaspersky's non-US support page or a reputable mirror (TechSpot
carries the identical file) — the stager verifies the SHA-256 either way, and
a checksum mismatch is a hard stop. Ships on the Phoenix USB as a bootable
ISO entry, not as a Windows executable.

### Microsoft Defender Offline / MpCmdRun — built-in second engine, $0

Every Windows 10/11 machine already carries this. The classic `mssstool64.exe`
standalone builder is a Windows 7/8.1-era artifact; on modern Windows the
offline scan lives in Windows Security (`Start-MpWDOScan` in PowerShell).
It reboots the *target* OS to scan, so it does not fit the "never boot the
infected OS" rule as a first-line tool — its Phoenix role is on the **staging
machine**: `MpCmdRun -Scan -ScanType 3 -File <mounted-image-path>` sweeps the
read-only mounted image with Microsoft's engine without touching the suspect.
Caveat worth knowing: after the April/May 2025 Windows 10 cumulative updates,
some machines reboot-loop instead of completing an offline scan, so treat it
as a second opinion, never the only scanner.

### Sysinternals Suite (Autoruns, Process Explorer, Process Monitor, Sigcheck, TCPView) — live-system and offline-hive inspectors

Microsoft's own free, portable, digitally-signed toolbox (updated August 2026,
~192 MB ZIP, runs straight off the USB with no install). **Autoruns** is the
star for this kit: it enumerates every persistence point in Windows — Run
keys, services, drivers, Explorer add-ons, scheduled tasks, WMI — and its
"Analyze Offline System" mode points at a *mounted image's* Windows directory,
so persistence can be audited without booting anything hostile. **Sigcheck**
bulk-verifies digital signatures (unsigned binaries in System32 are a red
flag). **Process Explorer / Process Monitor / TCPView** are the live-triage
instruments for step 7 only: they need a running OS, so they run only in the
last-resort air-gapped boot, or on the staging machine for baseline
comparisons. Still free, still Microsoft-maintained — confirmed September 2026.

### Emsisoft Emergency Kit — portable dual-engine second opinion

A 100%-portable, no-install malware scanner (GUI + command-line) with two
detection engines, free and updated (2025.7.0.12683, June 2025). It runs from
the USB's data partition on the staging machine against the mounted image, or
— if the last-resort live boot is ever used — directly on the suspect box.
License note that matters to Brandon: it is free for **private use only**;
commercial/helpdesk use requires Emsisoft Emergency Kit Pro. Personal laptop
triage qualifies; any DOGS-company client work does not. The stager verifies
its Authenticode signature (`Emsisoft Ltd`) on download.

### FTK Imager (free edition) — disk-image mounting and file extraction

Exterro's free forensic imager is the bridge between "we have an image" and
"we can look inside it": it mounts E01/DD/RAW images as read-only drive
letters in Windows Explorer, browses allocated *and* deleted files, previews
hex/text, exports evidence files, and verifies acquisition hashes. It also
captures live memory (`File → Capture Memory`) for the step-7 scenario. Note
two things: it is Windows-only and free-but-proprietary — Exterro gates the
download behind a free registration form, so the stager treats it as a
manual-drop item (place the installer in `staging/inbox/`, the script verifies
its signature, `Exterro Inc.`) rather than an auto-download. A paid "FTK
Imager Pro" ($499) now exists; the free edition covers everything Phoenix
needs.

### Autopsy — deep forensics platform (staging machine only)

The free, open-source digital forensics platform built on The Sleuth Kit
(current 4.21.0, 2026): file carving, timeline analysis, registry and browser
artifact parsing, email, keyword search across the whole image, and report
generation. This is explicitly **not** a USB tool — it needs a real install
(Windows 64-bit or Linux), Java 11+, and a minimum of 8 GB RAM (16 GB
recommended) plus room for case files and its Solr index. It lives on the
staging machine (Brandon's clean box or Castle storage), where it ingests the
Rescuezilla image for the deep-dive phase. The stager downloads the installer
to staging media but never to the boot USB.

### Deliberately excluded

- **ESET SysRescue Live** — effectively discontinued (last release 1.0.14.0,
  circa 2017; ESET folded rescue into its paid products). Do not build on it.
- **`mssstool64` standalone** — superseded by built-in Defender Offline on
  Win10/11 (see above).
- Anything paid or license-encumbered (EnCase, X-Ways, FTK Pro). The whole
  kit must be $0.

## License / cost / placement summary

| Tool | License | Cost | Runs from |
|---|---|---|---|
| Kaspersky Rescue Disk 18 | Proprietary freeware | $0 | Bootable ISO entry on Phoenix USB |
| Microsoft Defender Offline / MpCmdRun | Built into Windows | $0 | Staging machine (scan mounted image); target OS (offline scan) |
| Sysinternals Suite | Microsoft freeware | $0 | USB data partition (portable); works in WinPE |
| Emsisoft Emergency Kit | Free for **private use only** | $0 personal | USB data partition → staging machine |
| FTK Imager (free) | Proprietary freeware (registration) | $0 | Staging machine (manual-drop install) |
| Autopsy | Open source (Apache-2.0) | $0 | Staging machine only (heavy) |

## "Analyze" boot-menu wiring

The Phoenix USB is multiboot. The **Analyze** top-level entry opens a submenu
whose items map to the toolkit split above — boot-environment tools run on the
machine under test, staging-machine tools are documented as a handoff
checklist so the operator knows what moves to the clean box:

```
Analyze
 ├─ 1. Offline AV sweep ──────────────► boots Kaspersky Rescue Disk ISO
 │      (own Linux env; scans disks without booting suspect OS)
 ├─ 2. WinPE analysis shell ──────────► WinPE with USB data partition:
 │      Sysinternals (Autoruns offline-system mode vs mounted image),
 │      FTK Imager CLI for image verification, triage notes
 └─ 3. Staging-machine handoff ───────► checklist (not booted here):
        mount image read-only (FTK Imager) → Defender MpCmdRun scan →
        Emsisoft Emergency Kit scan → Autoruns offline analysis →
        Autopsy deep forensics → report
```

Rules the wiring enforces: items 1–2 never mount the suspect disk writable;
item 3 never runs on the infected hardware. The actual bootloader entries are
built by the USB-assembly worker from this contract; the staging script
(`tools/Stage-AnalysisTools.ps1`) populates the USB data partition and the
staging media from the manifest (`tools/analysis-toolkit.manifest.json`).

## Staging pipeline

`tools/Stage-AnalysisTools.ps1` runs on a **clean** build machine (never the
infected laptop). For each manifest entry it downloads (or picks up a
manual drop from `staging/inbox/`), then verifies:

- SHA-256 against the manifest hash where the vendor publishes one
  (Kaspersky ISO) — **mismatch = delete the file and abort loudly**, or
- Authenticode signature (`Get-AuthenticodeSignature` must be `Valid` and the
  signer must match the manifest subject) where no hash is published
  (Sysinternals → `Microsoft Corporation`, Emsisoft → `Emsisoft Ltd`,
  FTK Imager → `Exterro Inc.`).

Manual-drop items missing from `staging/inbox/` produce a warning with the
official download URL, not a failure. Downloaded binaries are build-time
artifacts and are never committed to the repo.
