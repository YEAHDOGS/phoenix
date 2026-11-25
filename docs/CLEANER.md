# The cleaner

Frees disk space on a Windows PC or an Android phone. It always shows what it
found first, and deletes only the rules you pick.

```
phoenix.ps1 clean-rules   [-ArgsPath { platform }]                 the rules, no scanning
phoenix.ps1 clean-scan    [-ArgsPath { platform, ids?, top?, serial?, adbPath? }]   read-only
phoenix.ps1 clean-run      -ArgsPath { platform, ids, serial?, adbPath? }           deletes
phoenix.ps1 clean-devices [-ArgsPath { adbPath? }]                 Android devices on USB
```

`platform` is `windows` (default) or `android`. `clean-run` with no `ids`
fails: nothing is ever cleaned by default.

`clean-scan` returns, per rule: `bytes`, `files`, the `biggest` files (25, or
`top`), the `folders` it looked in, `running` (programs to close first),
`blocked: "needs-admin"` when the rule needs an elevated engine, and `notes`
when a folder was refused. `clean-run` returns what was freed per rule, how
many files were in use and left (`failed`), and free space before and after.

On the PC this was built on, a scan covers 25 rules and about 480,000 files in
8 to 20 seconds.

## Rules are data

Every `*.json` in `config/clean/` is a rule set. Add a file to add rules; share
it like a pack. `PHOENIX_CLEAN_RULES` points the engine at another folder.

```json
{
  "id": "my-rules", "name": "Mine", "platform": "windows", "version": 1,
  "rules": [
    {
      "id": "app.example",
      "group": "Apps",
      "name": "Example cache",
      "why": "One or two plain sentences: what this is, and what happens after it is gone.",
      "risk": "safe",
      "default": true,
      "admin": false,
      "closeFirst": ["example"],
      "targets": [
        { "path": "%LOCALAPPDATA%\\Example\\*\\Cache" },
        { "path": "%APPDATA%\\Example\\logs", "match": ["*.log", "*.old"], "olderThanHours": 24, "recurse": false }
      ],
      "files": ["%SystemRoot%\\MEMORY.DMP"]
    }
  ]
}
```

- `targets[].path` is a folder. Its **contents** go; the folder stays. `*` and
  `?` work in any part but the drive. Environment variables are expanded.
- `match` limits it to file names. `olderThanHours` keeps recent files.
  `recurse: false` stays out of subfolders.
- `files` names single files exactly, no wildcards, and only `.dmp .log .tmp
  .old .bak .etl .db .chk`.
- `risk` is `safe` or `caution`. `default` says whether an app should tick it
  to begin with. `admin: true` rules are skipped unless the engine is elevated.
- `special` is for the two things that are not plain folders: `recycle-bin`
  and (Android) `android-app-caches`.

## What a rule cannot do

A rule file may come from someone else, so these hold whatever it says:

- A folder is refused when it **is**, **contains** or **sits inside** a place
  that is yours or Windows' own: the profile, Documents, Desktop, Pictures,
  Music, Videos, Downloads, OneDrive, `.ssh`, AppData itself, Windows,
  System32, WinSxS, Program Files, ProgramData. The scan lists each refusal in
  `notes`.
- Junctions and symbolic links are never followed and never removed.
- Rules cannot run anything. They name files; that is all.

`scripts/engine/tests/Test-Engine.ps1` deletes for real inside a sandbox folder
and checks each of these.

## Android

Over USB with debugging on, no root. `adb` is found in the loadout
(`platform-tools`), in `PHOENIX_ADB`, on `PATH`, or passed as `adbPath`.

- **App caches** come from Android's own bookkeeping (`dumpsys diskstats`) and
  are cleared with `pm trim-caches`. Without root Android clears every app's
  cache at once; it cannot do one app. Android fills in the per-app sizes only
  now and then; without them the scan says `sizeUnknown` and the run reports
  what it freed from free space before and after.
- **File rules** may only name folders under `/sdcard`, using letters, digits,
  dots, dashes and `*`. A folder that holds your own files (DCIM, Pictures,
  Download, ...) needs a file-name pattern.

Tested against the Android 15 emulator: it removed the planted thumbnails, trashed
photo and .apk and left the photo and document beside them. Not tried on a physical
phone yet, and the emulator had no app caches to prove how much `pm trim-caches` frees.

## iOS

Not built. Apple gives no supported way to clear another app's cache from a
computer; the only real lever is offloading or deleting apps on the phone.
