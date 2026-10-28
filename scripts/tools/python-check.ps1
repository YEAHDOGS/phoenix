# Save this code as test-py.ps1 and run it in your PowerShell terminal

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    Write-Host "[$Level] $Message"
}

function Find-Python {
    Write-Log "Looking for Python via py.exe..."

    # Try Python Launcher for Windows
    if (Get-Command "py" -ErrorAction SilentlyContinue) {
        try {
            $version = py -3 --version 2>&1
            if ($version -match "Python 3\.(\d+)\.") {
                $minorVersion = [int]$matches[1]
                if ($minorVersion -ge 10) {
                    Write-Log "Found compatible Python: $version using Python Launcher"
                    return "py -3"
                }
            }
        } catch { }
    }

    Write-Log "Python 3.10+ is required via py.exe but not found." "ERROR"
    throw "Python 3.10+ not found"
}

# --- Test Execution ---
try {
    $result = Find-Python
    Write-Host "`n[PASS] Verified successfully with: $result" -ForegroundColor Green
} catch {
    Write-Host "`n[FAIL] Verification failed: $_" -ForegroundColor Red
}