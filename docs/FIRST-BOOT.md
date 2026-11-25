# First boot: Chocolatey, your apps, optional hardening

One PowerShell script that installs Chocolatey, then every app you chose at its
latest version, then (only if asked) a pinned third-party hardening script.

```
phoenix.ps1 setup-script   -ArgsPath { apps: [ids], harden?, reportUrl?, waitMinutes?, outPath? }
phoenix.ps1 setup-script  [-ArgsPath { configPath }]        the same, from a config
phoenix.ps1 harden-options                                   the hardening choices
phoenix.ps1 choco-search   -ArgsPath { query }               find package ids
```

`setup-script` returns the script text (and writes `outPath` when given). The
script needs nothing else from Phoenix, so it can be:

- **run by hand** on any PC: right-click, Run with PowerShell. It asks for
  administrator rights itself;
- **put in the answer file**, so a fresh install does it at the first logon;
- **tested in a VM** before you trust it on a real machine.

It can be run again: apps already installed are left alone.

## In the answer file

```json
{
  "apps": ["powertoys", "powershell-core", "7zip"],
  "firstBoot": {
    "enabled": true,
    "choco": true,
    "apps": null,
    "waitMinutes": 10,
    "reportUrl": "",
    "harden": { "enabled": false, "options": { "sysmon": true } }
  }
}
```

With `firstBoot.enabled`, `unattend` adds the script to the answer file's
FirstLogon scripts. `apps: null` means "use the config's `apps`". It waits up
to `waitMinutes` for the internet; with none, it stops and says so, and can be
run again later from `C:\Windows\Setup\Scripts\`.

This is separate from the Phoenix USB flow (docs/ARCHITECTURE.md), which
installs apps in the `user-online` phase after the machine has been hardened
offline. Use `firstBoot` when you want a machine that sets itself up straight
from the answer file, such as a VM.

## What it leaves behind

```
C:\ProgramData\Phoenix\firstboot.json            what happened, per app
C:\ProgramData\Phoenix\logs\firstboot-setup.log  the log
C:\ProgramData\Phoenix\logs\firstboot-harden.log the hardening script's own output
```

`firstboot.json`: `{ started, finished, ok, network, chocolatey, apps: [{ id,
ok, exit, version, seconds, restart }], harden, error }`. With `reportUrl` the
same JSON is also POSTed there after every step, so another machine can watch.

## Hardening source

`config/sources/sos-harden.json` describes
[simeononsecurity/Windows-Optimize-Harden-Debloat](https://github.com/simeononsecurity/Windows-Optimize-Harden-Debloat)
(MIT): the repository, **one commit**, the SHA-256 of that commit's zip, and
its 32 on/off options with Phoenix's own defaults and risk levels.

- It is off unless `harden.enabled` is true.
- The script downloads that exact commit, refuses to run it if the hash is
  different, and passes every option explicitly, so the upstream "everything
  on" defaults never apply.
- Nothing marked `danger` is on by default.
- It changes a great deal at once. Phoenix does not snapshot or undo it; the
  upstream script takes a restore point. Try it in a VM first.

To move to a newer commit: change `commit`, download
`https://github.com/<repo>/archive/<commit>.zip`, and put its SHA-256 in
`zipSha256`.

The hardening step has not been run end to end yet; only the script that calls
it is tested.
