# R36S (Temu clone, R36S-V20 board) – EASYROMS card tooling

The handheld runs a vendor build of ArkOS on a custom kernel. Only the stock BOOT partition drives its ST7703 screen, so **never reflash BOOT**. Games live on partition 3 of the card, an exFAT volume labelled `EASYROMS`.

## Adding games (the everyday flow)

1. Plug the card in. It shows up as a drive labelled `EASYROMS` (the letter varies; the updater finds it by label).
2. Copy games into the folder for their system on that drive: `snes\`, `n64\`, `gba\`, `megadrive\`, `psp\`, `nds\` and so on.
   `systems-cheatsheet.txt` lists every folder the OS knows and which file extensions it accepts. A file with the wrong extension, or in a folder the OS doesn't know, never appears in the menu.
3. Run the updater:

   ```powershell
   pwsh -File "C:\Users\Brando\Projects\phoenix\scripts\emulationstation\update-card.ps1"
   ```

   It writes a `gamelist.xml` in every system folder (clean names without region tags, artwork links when a matching PNG exists next to the game or in an `images` folder), extracts any PortMaster zips dropped into `F:\ports\`, warns about files the OS will ignore, and deletes empty system folders. It never deletes a game. Run it as often as you like.
4. Eject the card ("Safely remove" in Windows), put it in the handheld, boot.

Options: `-Drive G` to force a drive letter; `-KeepEmptyFolders`; `-PsxPrep` to generate `.cue` sheets for bare PSX `.bin` files and `.m3u` playlists for multi-disc sets (off by default).

Notes:
- The OS itself also rewrites `gamelist.xml` when EmulationStation exits, keeping play counts and any metadata. The updater preserves what's already in a gamelist and only adds/removes entries for files that appeared/disappeared.
- PSX: EmulationStation lists `.cue`, `.chd`, `.pbp`, `.m3u`, `.iso` — not bare `.bin`. CHD is the simplest format (one file, no companion).
- PortMaster ports: drop the zip in `ports\`; the updater extracts it and moves the zip to `ports\_zips\`. Some ports still need their commercial game data placed in the port folder (they ship a `PLACE_..._HERE` marker).

## Card surgery scripts (rarely needed)

- `clone-to-card.ps1 -DiskNumber N` – writes the archived 16 GB image (`D:\backups\temu-gameboy\full-card-image\sdcard-full-image-v2.img`) to a blank card and verifies it. Run elevated.
- `expand-easyroms.ps1 -DiskNumber N` – capacity-tests the spare space, then recreates partition 3 to fill the card as exFAT `EASYROMS`. Run elevated, after cloning.
- `restore-trimmed.ps1 -Drive X` – copies the ArkOS support folders plus DS and GTA PSP from the archived backup onto a fresh EASYROMS.

The archive in `D:\backups\temu-gameboy\` is the untouched original card (files + raw image). Do not modify it.

## Launch flash (DOGS logo)

`launchimages\` next to the updater holds a 0.27 s DOGS-logo flash (`loading.mp4`, plus `loading.jpg` and `loading.gif` for the other launch-image modes). The updater copies these onto the card's `launchimages\` folder, replacing the BMO clip the handheld shipped with. Regenerate from `C:\Users\Brando\Projects\DOGS-CONTENT\dogs-logo-cropped.png` with ffmpeg if the logo changes.

## Using these scripts from other projects

`scripts/tools/phoenix-import.ps1` fetches phoenix from GitHub (sparse, pinned to a ref, optionally signature-checked) and runs a script from it:

```powershell
iex (irm https://raw.githubusercontent.com/YEAHDOGS/phoenix/master/scripts/tools/phoenix-import.ps1)
Invoke-PhoenixScript 'scripts/emulationstation/update-card.ps1'
```
