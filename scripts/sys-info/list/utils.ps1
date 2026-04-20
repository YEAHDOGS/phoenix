# utils.ps1

function Initialize-AuditFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    # 1. Use an existing shared timestamp, or create a new one if it doesn't exist
    # We use $script: to ensure the variable persists across dotsourced calls
    if (-not $script:SharedTimestamp) {
        $script:SharedTimestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    }
    
    $FileName = "Sys-$Name-$script:SharedTimestamp.csv"

    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    $DataFolder = Join-Path $ProjectRoot "data"
    $BackupFolder = Join-Path $ProjectRoot "data-backup"
    $ExportPath = Join-Path $DataFolder $FileName

    if (-not (Test-Path $DataFolder)) { New-Item $DataFolder -ItemType Directory -Force | Out-Null }
    if (-not (Test-Path $BackupFolder)) { New-Item $BackupFolder -ItemType Directory -Force | Out-Null }

    # Handle Archiving (clears old runs of this specific module)
    Get-ChildItem -Path $DataFolder -Filter "Sys-$Name-*.csv" | Where-Object { $_.Name -ne $FileName } | ForEach-Object {
        # Visual Output
        Write-Host "[!] " -ForegroundColor DarkGray -NoNewline
        Write-Host "$Name " -ForegroundColor DarkGreen -NoNewline
        Write-Host "Archiving old csv file. Destination: $(Join-Path $BackupFolder $_.Name)" -ForegroundColor DarkGray
    
        # Logic (Now on a new line, so it won't print)
        Move-Item -Path $_.FullName -Destination (Join-Path $BackupFolder $_.Name) -Force
    }

    return $ExportPath
}