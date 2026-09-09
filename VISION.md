# Phoenix - Vision & Roadmap

> Plug a Phoenix-generated USB drive into any computer on Earth and get
> back to a personalized, debloated Windows setup. Air-gapped mode is a
> must: full install with zero network. Fifteen minutes, wipe to desktop.

## Where the repo actually is (2026-09-09)

- ~60 PowerShell scripts organized by concern: `asr/` (Defender Attack
  Surface Reduction), `sys-info/` (auditing/listing), `firewall/`,
  `kill-updates/`, `chocolatey/`, `get-windows-updates/`, `registry/`,
  `settings/`, `tools/`, `git/`, `checksum/`, plus a WinForms GUI launcher
  that runs scripts on a *live* machine.
- One working Schneegans-generated `win-install/autounattend.xml`: wipes
  DISK 0, applies install.wim via DISM, injects `$WinPEDriver$` drivers,
  disables WPBT, skips OOBE. Tested manually, not yet in an automated loop.
- A QEMU test VM (`scripts/qemu/start.ps1`) that injects `win-install/` as
  a virtual USB - the seed of a real test harness.
- `data/` lists: `remove/services.json` is populated (with vulnerability
  notes), `remove/devices.json` is partial, `remove/optionalfeatures.json`
  and `choco-install/apps.json` are **empty skeletons**.
- Docs with real intent: `readme.md` (philosophy + manual runbooks),
  `scripts/tools/answer-file-notes.txt` (the Windows Update war diary -
  mine this before writing any installer logic).

In short: a strong daily-driver script toolbox and one hand-built answer
file. The journey from here to "USB into any PC" is: USB creation flow,
answer-file generation, offline staging, air-gap execution, a test loop,
and finally the GUI app.

## Gap analysis: scripts -> "USB into any PC"

1. **No USB creation flow.** No stager, no disk writer, no `$OEM$` folder
   in the repo (the answer file expects `$$\Setup\Scripts\Specialize.ps1`
   and `DefaultUser.ps1` - they don't exist yet).
2. **No answer-file generator.** `autounattend.xml` is hand-edited; every
   tweak means re-running Schneegans by hand.
3. **Air-gap is aspirational.** Most post-install paths assume network:
   Chocolatey installs, ASR rule fetch, Winget. The stage-while-online /
   run-offline pattern isn't implemented here yet.
4. **Driver story is half-built.** The answer file references
   `$WinPEDriver$`, but there is no flow to collect/stage driver packs.
5. **No verification loop.** `checksum/check.ps1` exists but isn't wired
   into any install flow; ISO integrity is unchecked.
6. **Plaintext credentials in a public repo.** The XML carries real local
   account passwords (unattend format requires them - see
   `win-install/README.md`).

## Phased roadmap

### Phase 0 - Script hardening (in progress)
Confirmations on destructive tools, machine-portable paths (no more
hardcoded usernames), the ASR batch-call fix. The toolbox must be safe to
run before it becomes safe to ship.

### Phase 1 - USB stager (online prep)
A `stage-usb.ps1` that runs on a connected machine and produces a
`usb-staging/` tree + `manifest.json`:
- Windows ISO download with **SHA-512 verification** (extend
  `checksum/check.ps1`; Brandon already verifies ISOs this way)
- Driver packs per machine profile into `$WinPEDriver$/`
- App installers: Chocolatey `.nupkg` cache (`choco download`) and/or
  standalone `.exe`/`.msi` into `cache/apps/`
- Update catalog via `get-windows-updates/fetch-updates.ps1` into
  `cache/updates/`
- The phoenix `scripts/` tree itself, so the target machine runs the
  exact audited versions
- The stager **fails the build if any required asset is missing** - a USB
  that silently skips steps is worse than no USB

### Phase 2 - Answer-file generator
A config-driven generator (PowerShell module first, GUI later) that emits
`autounattend.xml` from a simple config: computer name, accounts, locale,
edition, disk layout, remove-lists. The current Schneegans URL is embedded
in the XML header - keep supporting hand-tweaked files while the
generator catches up.

### Phase 3 - Air-gap execution
Every script that runs on the target gets an offline contract: `-Offline`
switch or an offline variant, reading only from the USB's `cache/`
folders. `$OEM$` folder with `Specialize.ps1` / `DefaultUser.ps1` /
FirstLogon scripts that invoke phoenix scripts locally. Hosts-file
update-domain blocks applied from the staged copy (the pattern is already
documented in `answer-file-notes.txt`).

### Phase 4 - QEMU test loop
Scripted unattended-install test: boot the ISO + generated answer file +
staged USB in QEMU, assert it reaches the desktop with the expected
debloat applied, snapshot/rollback on failure. `scripts/qemu/start.ps1`
is the starting point; it needs parameterization and assertions.

### Phase 5 - The GUI app
**Recommendation: Tauri v2 + Svelte 5 + Tailwind.** It's Brandon's exact
web stack, ships as a single small binary (no Electron bloat - on-brand
for a debloat tool), and Tauri's shell/command APIs can drive the
PowerShell stager scripts as sidecars. The app owns three jobs:
1. Form-driven `unattend.xml` generation (Phase 2 as UI)
2. USB build: staging + writing + verification (Phase 1 as UI)
3. Profile management: machine profiles (HP Omnibook 7 today, "any PC on
   Earth" tomorrow) with per-machine driver packs and remove-lists

The existing WinForms `gui-launcher.ps1` stays useful as the *live-machine*
tweak tool; the installer app is a separate product.

## Adapting reviOS-offline (read-only analysis)

Brandon's `cptnbrando/reviOS-offline` fork is the reference implementation
of the air-gap pattern. Analyzed, not copied; nothing is pushed there.

**Borrow:**
- **The build pattern** (`build.ps1`): `getapps.ps1` stages binaries
  while online, then the packager swaps `-offline` variants in
  (`start-offline.yml` -> `start.yml`, `software-offline.yml` ->
  `software.yml`, `playbook-offline.conf` -> `playbook.conf`) and bundles
  everything. This maps 1:1 to a phoenix `stage-usb.ps1` + `build-usb.ps1`.
- **The `!download` -> `!run Offline/...` swap.** Every network fetch gets
  an offline twin that runs a pre-staged binary. Phoenix's equivalent:
  offline variants / `-Offline` switches on the choco, ASR, and update
  scripts.
- **The offline `playbook.conf` changes**: drop the `Internet`
  requirement, drop the ProductCode integrity check. Phoenix's stager
  should similarly verify the USB manifest *locally* (hashes in
  `manifest.json`) instead of phoning home.
- **The hosts-file copy during init** (`start-offline.yml`). Phoenix
  already documents this approach; formalize it as a staged file.
- **The YAML task model as an *idea***: small declarative task files
  grouped by concern. Phoenix's `data/remove/*.json` lists are the same
  instinct in JSON - they should grow into the single source of truth the
  future GUI renders as checkboxes (like ReviOS's FeaturePages).

**Skip:**
- The AME `.apbx` packaging (7z + password "malte" + AME signature
  checks). Phoenix's delivery vehicle is the USB + unattend.xml, not the
  AME Wizard - different runtime, different trust model.
- `playbook.conf` FeaturePages XML. The Tauri GUI supersedes it with real
  Svelte forms.
- ReviOS's **disable-Defender default**. Phoenix's philosophy is the
  opposite (ASR hardening, firewall rules). Port the *mechanism*, never
  the *defaults*.

**Watch out for:**
- ReviOS runs tasks as TrustedInstaller via the AME engine; phoenix
  scripts run as Administrator. Some removals (AppX, WinSxS) behave
  differently - test in the QEMU loop before assuming parity.
- The offline fork still trusts pre-staged binaries; the stager must
  hash-verify every downloaded asset at stage time (SHA-512, per
  Brandon's existing practice) and re-verify from `manifest.json` on the
  target.

## Air-gap staging spec (what must be on the USB)

```
PHOENIX-USB/
  autounattend.xml            # generated (Phase 2)
  $OEM$/$$/Setup/Scripts/    # Specialize.ps1, DefaultUser.ps1, FirstLogon
  $WinPEDriver$/<profile>/   # driver packs, per machine profile
  sources/install.wim        # or install.esd (from the ISO)
  phoenix/scripts/           # the audited toolbox, version-pinned
  phoenix/manifest.json      # file hashes + versions of everything below
  cache/apps/                # offline installers + choco .nupkg cache
  cache/updates/             # update catalog + MSU files
  cache/iso.sha512           # ISO integrity sidecar
  assets/hosts               # update-domain blocks
  assets/wallpaper/          # Ghost Rider, obviously
```

Rule: **nothing on the target may reach the network.** If a script can't
do its job offline, it gets an offline variant or it doesn't ship on the
USB.
