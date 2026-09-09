# Uptime pinger

Zero-token website monitor for Phoenix. No AI, no agent — just web requests,
once a minute, appending to `~\uptime.log`.

Install on Windows via Task Scheduler (repeat every 1 minute):
```
powershell.exe -ExecutionPolicy Bypass -File "C:\path\to\uptime-ping.ps1"
```

Edit the `$urls` array in the script to add/remove sites.
