# usb-backup.ps1

Back up any plugged-in USB drive or SD card in every useful form at once, from one checklist.

```powershell
pwsh -File scripts\usb\usb-backup.ps1                       # GUI: tick the drives and the outputs you want
pwsh -File scripts\usb\usb-backup.ps1 -Disks 1 -Do Image,Folder,Iso,Zip
pwsh -File scripts\usb\usb-backup.ps1 -Disks 1,2 -Do Image -Destination D:\Backups\usb -NoGui
```

Only **Image** needs admin (Windows blocks raw sector reads otherwise); the script asks for elevation just for that. Folder, Iso, Zip and Burn run as a normal user. Output goes to `<Destination>\<label>_<serial>_<timestamp>\` (default `%USERPROFILE%\Backups\usb`) with a `manifest.json` (disk, partitions, volumes, hashes) and `backup.log`.

| Output | What you get | Notes |
|---|---|---|
| **Image** | `name.img` + `name.img.sha256` | Sector-for-sector clone of the whole disk, partition table included. Restore with the clone script, Rufus (DD mode), or `dd`. 7-Zip opens `.img` files directly, so you can extract single files from it. Unreadable sectors are retried per sector and zero-filled, and listed in the manifest. |
| **Folder** | `files\<volume label>\...` | Plain robocopy of every mounted volume, timestamps preserved. |
| **Iso** | `name.iso` | ISO9660 + Joliet + UDF image of the files (UDF-only when a file is 4 GB or bigger). Burnable with Windows "Burn disc image" or any burner; mountable in Windows; 7-Zip opens it. |
| **Zip** | `name.zip` | 7-Zip zip64, store-level compression for speed. Falls back to `Compress-Archive` if 7-Zip is missing. |
| **Burn** | | Opens the Windows burn dialog with the `.iso` (needs an optical drive). Implies Iso. |

Tick Folder together with Iso/Zip and the drive is read only once: the ISO and ZIP are built from the local copy.

Space: a raw image needs the drive's full capacity; Folder, Iso and Zip each need the used size.

Uses only what Windows ships plus 7-Zip: IMAPI2 for the ISO, robocopy, `isoburn.exe`. No third-party imaging tools.

Run it from another repo without copying it: see `scripts/tools/phoenix-import.ps1`.
