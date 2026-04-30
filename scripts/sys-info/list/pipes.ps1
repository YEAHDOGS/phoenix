param (
    [Alias("t")]
    [switch]$TableView
)

. "$PSScriptRoot\utils.ps1"
$ExportPath = Initialize-AuditFile -Name "Pipes"

Write-Host "--- AUDITING NAMED PIPES (Inter-process Comm) ---" -ForegroundColor Blue

# It is completely normal for that list to fluctuate constantly.

# Think of Named Pipes as temporary "phone lines" that applications use to talk to each other or to the operating system. Just as a phone line only stays active during a call, a named pipe usually only exists as long as the underlying process needs it. So, if you run this script multiple times, you might see different pipes each time, and that's perfectly normal. It's like checking which phone lines are active at any given moment; they can come and go as applications start and stop their communication.

# Fetch and filter pipes
$pipeObjects = [System.IO.Directory]::GetFiles("\\.\\pipe\\") | 
ForEach-Object { [PSCustomObject]@{ PipeName = $_ } }

# --- GUARD CLAUSE: Flip operand and return early if no pipes found ---
if (-not $pipeObjects) {
    Write-Host "[+] No named pipes detected." -ForegroundColor Green
    return
}

# --- MAIN LOGIC (Only runs if pipes were found) ---
Write-Host "[!] Found $($pipeObjects.Count) Pipe(s):" -ForegroundColor Red

# Export to CSV
$pipeObjects | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host "Pipe audit exported to $ExportPath" -ForegroundColor Cyan

# Check for the -t (TableView) flag
if ($TableView) {
    Import-Csv -Path $ExportPath | Out-GridView -Title "Named Pipe Audit"
}