# Dogs uptime pinger — ZERO tokens. No AI, no agent, just web requests.
# Install on YOUR Windows machine (not mine):
#   1. Open Task Scheduler → Create Basic Task → Trigger: Daily, repeat every 1 minute
#   2. Action: Start a program → powershell.exe
#   3. Arguments: -ExecutionPolicy Bypass -File "C:\path\to\uptime-ping.ps1"
# Appends one line per site per minute to ~\uptime.log
$urls = @(
  "https://icecream.wearedogs.net",
  "https://yeahdogs.github.io/tower/",
  "https://yeahdogs.github.io/forge/",
  "https://wearedogs.net"
)
$log = Join-Path $env:USERPROFILE "uptime.log"
foreach ($u in $urls) {
  try {
    $code = (Invoke-WebRequest -Uri $u -TimeoutSec 15 -UseBasicParsing).StatusCode
  } catch {
    $code = "FAIL"
  }
  "$(Get-Date -Format o) $u $code" | Out-File -Append -FilePath $log -Encoding utf8
}
