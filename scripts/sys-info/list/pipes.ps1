param (
    [Alias("t")]
    [switch]$TableView
)

. "$PSScriptRoot\utils.ps1"
$ExportPath = Initialize-AuditFile -Name "Pipes"

Write-Host "--- AUDITING NAMED PIPES (Inter-process Comm) ---" -ForegroundColor Blue

# Fetch and filter pipes
$pipeObjects = [System.IO.Directory]::GetFiles("\\.\\pipe\\") | 
ForEach-Object { [PSCustomObject]@{ PipeName = $_ } }

# --- GUARD CLAUSE: Flip operand and return early if no pipes found ---
if (-not $pipeObjects) {
    Write-Host "[+] No suspicious named pipes detected." -ForegroundColor Green
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