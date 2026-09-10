# Phoenix per-app backup profiles

Phoenix backup is **selective per application**. A naive backup restores the
malware too — AppData-style locations are prime malware/spyware persistence
spots. So every app gets a profile that says exactly what is **data** (safe),
what is **config** (validate before reapplying), and what must **never come back**.

## File-class taxonomy

| class        | meaning                                                            | backup policy          |
|--------------|--------------------------------------------------------------------|------------------------|
| `data`       | the user's real stuff: projects, saves, libraries, bookmarks       | back up as-is          |
| `config`     | settings files                                                     | back up **only if valid** (JSON must parse, etc.); never trusted blindly |
| `cache`      | caches, logs, crash dumps, credential blobs (cookies, tokens)      | **never** — rebuilt by the app, or exported separately |
| `executable` | app installs, extension binaries, game binaries, plugin DLLs       | **never** — apps reinstall clean (Chocolatey); binaries in user-writable dirs are treated as hostile |

Restore = clean OS + clean app installs + sanitized config + user data.
Anything secretly living in AppData dies in the flamethrower.

## Profile schema (`phoenix-profile/v1`)

```json
{
  "schema": "phoenix-profile/v1",
  "app": "chrome",
  "display_name": "Google Chrome",
  "locations": [
    {
      "class": "data | config | cache | executable",
      "notes": "why this classification (required — future-you needs the reasoning)",
      "windows": ["%LOCALAPPDATA%\\path\\to\\thing"],
      "linux": ["~/.config/path/to/thing"]
    }
  ]
}
```

Rules:
- `windows` paths use `%VAR%` env expansion. `linux` paths may start with `~`
  (expanded to `$PHOENIX_HOME`, default `$HOME`).
- Every location needs `notes` explaining the call. If you can't explain why
  it's data and not a persistence hole, it isn't data.
- `cache` and `executable` classes are the *kill list*: the engines must print
  them as explicitly SKIPPED in plan mode so it's visible they were considered.
- When in doubt, classify DOWN: data -> config -> cache. Missing something is
  fixable; restoring malware is not.

## Engines

- `scripts/backup/backup-selective.ps1` — Windows side (PowerShell).
- `scripts/backup/backup-selective.sh` — Linux rescue side (bash twin).
- `scripts/backup/test-profiles.sh` — regression check: validates every profile
  against the schema, then runs the bash engine against a fixture home to prove
  selection/exclusion logic and manifest output.

Both engines default to **plan mode** (read-only listing of what WOULD be
backed up, what would be validated, and what would be skipped). Nothing is
copied until you pass `-Execute` / `--execute`.

## Restore rules

The restore engines (`scripts/backup/restore-selective.ps1` /
`restore-selective.sh`, documented in `scripts/backup/RESTORE.md`) enforce
these profiles on the way back in — policy lives here, not in code:

- Every manifest entry is classified by matching its *target* path against
  this profile's `windows`/`linux` locations.
- `data` restores (hash-verified before and after the copy); `config` restores
  only after revalidation (`.json` must parse — anything else is quarantined
  and never written).
- `cache` / `executable` entries are **never restored**, even if someone
  hand-edits them into a manifest — the engine prints them as kill-list SKIPs.
- `--app <id>` restores only that profile's files. New app = new
  `profiles/<app>.json`, zero engine changes.
