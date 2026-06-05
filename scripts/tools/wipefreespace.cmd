@REM This should be run as admin to securely wipe free space on C: drive after moving data files to backup location. It will not delete the data files, but will make it much harder for anyone to recover them if they were deleted.
@REM It goes through all the registers of the drive and writes random data to them, effectively overwriting any deleted files that may still be recoverable. This is a good practice to ensure that sensitive data is not easily recoverable after deletion.

param (
        [Parameter(Mandatory = $false)]
        [string]$Passes = 1
        [Parameter(Mandatory = $false)]
        [string]$Drive = "C:"
    )

try {
    # Validate the drive letter
    if (-not (Test-Path -Path $Drive)) {
        throw "The specified drive '$Drive' does not exist. Please provide a valid drive letter."
    }

    # Validate the number of passes
    if ($Passes -lt 1) {
        throw "The number of passes must be at least 1. Please provide a valid number."
    }
}
catch {
    Write-Error "Error: $_"
    exit 1
}

try {
    Write-Host "Wiping free space on $Drive 🌌" -ForegroundColor Yellow
    Write-Host "You can cancel anytime by pressing Ctrl + C" -ForegroundColor Red

    for ($i = 1; $i -le $Passes; $i++) {
        Write-Host "Performing wipe $i of $Passes..." -ForegroundColor Yellow
        # Use the cipher command to wipe free space on the drive
        cipher /w:$Drive
    }

    Write-Host "Free space on $Drive has been wiped successfully! 🧹" -ForegroundColor Green
}
catch {
    Write-Error "An error occurred during the wiping process: $_"
    exit 1
}

@REM I don't trust the cipher.exe file at all. To examine the .exe yourself, you can locate the .exe with this command

@REM Get-ChildItem -Path C:\Windows\WinSxS -Filter "cipher.exe" -Recurse -ErrorAction SilentlyContinue

@REM The WinSxS folder is where Windows stores multiple versions of system files, and it can be quite large. On a fresh reflash of the system without updates this folder should be empty. I think? Only updated system files should be there...