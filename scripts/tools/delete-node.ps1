$target = Join-Path $PWD "node_modules"

if (Test-Path $target) {
    $confirmation = Read-Host "Are you sure you want to delete the node_modules folder in $($PWD)? (y/N)"
    if ($confirmation -match '^[yY]') {
        Write-Host "Deleting node_modules..." -ForegroundColor Cyan
        
        # Using cmd.exe's rmdir is significantly faster for deep node_modules folders than PowerShell's Remove-Item
        cmd.exe /c "rmdir /s /q `"$target`""
        
        if (-Not (Test-Path $target)) {
            Write-Host "node_modules deleted successfully." -ForegroundColor Green
        } else {
            Write-Host "Failed to completely delete node_modules. Some files might be in use." -ForegroundColor Red
            
            Write-Host "Searching for associated processes..." -ForegroundColor Cyan
            
            $escapedTarget = [regex]::Escape($target)
            $processes = Get-CimInstance Win32_Process | Where-Object {
                ($_.CommandLine -match $escapedTarget) -or ($_.ExecutablePath -match $escapedTarget)
            }
            
            if ($processes) {
                Write-Host "Found the following processes using node_modules:" -ForegroundColor Yellow
                foreach ($p in $processes) {
                    Write-Host " - $($p.Name) (PID: $($p.ProcessId))"
                }
                
                $nukeConfirmation = Read-Host "`nDo you want to force kill these processes and nuke the folder? (y/N)"
                if ($nukeConfirmation -match '^[yY]') {
                    foreach ($p in $processes) {
                        Write-Host "Killing process $($p.Name) (PID: $($p.ProcessId))" -ForegroundColor Cyan
                        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                    }
                    
                    # Give processes a moment to terminate
                    Start-Sleep -Seconds 1
                    
                    Write-Host "Retrying deletion..." -ForegroundColor Cyan
                    cmd.exe /c "rmdir /s /q `"$target`""
                    
                    if (-Not (Test-Path $target)) {
                        Write-Host "node_modules deleted successfully after nuking processes." -ForegroundColor Green
                    } else {
                        Write-Host "Still failed to delete node_modules completely." -ForegroundColor Red
                    }
                } else {
                    Write-Host "Nuke cancelled." -ForegroundColor Yellow
                }
            } else {
                Write-Host "No associated processes found to kill." -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "Deletion cancelled." -ForegroundColor Yellow
    }
} else {
    Write-Host "No node_modules folder found in $($PWD)." -ForegroundColor Yellow
}
