param (
    [Switch]$Delete
)

# 1. Verify we are actually inside a Git repository
if (-not (git rev-parse --is-inside-work-tree 2>$null)) {
    Write-Host "Error: Current directory is not a Git repository." -ForegroundColor Red
    Exit 1
}

# 2. Extract and display repo info
$RepoRoot = git rev-parse --show-toplevel
$CurrentBranch = git branch --show-current
Write-Host "Repository Found: $RepoRoot" -ForegroundColor Cyan
Write-Host "Current Branch:   $CurrentBranch" -ForegroundColor Cyan
Write-Host "----------------------------------------"

# 3. Ask how deep the damage goes
$CommitInput = Read-Host "How many commits back are fucked up? [Default: 1]"
if ([string]::IsNullOrWhiteSpace($CommitInput)) {
    $CommitCount = 1
}
elseif ($CommitInput -match '^\d+$' -and [int]$CommitInput -gt 0) {
    $CommitCount = [int]$CommitInput
}
else {
    Write-Host "Invalid number of commits, exiting." -ForegroundColor Red
    Exit 1
}

# 4. Assess the Damage Scope (Local vs. Cloud)
Write-Host "`nHow bad is the damage?" -ForegroundColor Yellow
Write-Host "1) It's just local (Committed, but NOT pushed yet)"
Write-Host "2) It's in the cloud (Already pushed to remote)"
$Scope = Read-Host "Select an option (1-2)"

if ($Scope -notmatch '^[12]$') {
    Write-Host "Invalid response, exiting." -ForegroundColor Red
    Exit 1
}

# ==========================================
# --- MODE 1: LOCAL CLEANUP LOGIC ---
# ==========================================
if ($Scope -eq "1") {
    $ShouldDelete = $Delete

    if (-not $Delete) {
        Write-Host "`nYou are about to undo the last $CommitCount commit(s)." -ForegroundColor Yellow
        $Choice = Read-Host "Do you want to completely DELETE the data/changes in these commits? (y/N)"
        
        if ($Choice -match "^[yY](es)?$") { $ShouldDelete = $true }
        elseif ($Choice -match "^[nN](o)?$" -or [string]::IsNullOrEmpty($Choice)) { $ShouldDelete = $false }
        else { Write-Host "Invalid response, exiting." -ForegroundColor Red; Exit 1 }
    }

    Write-Host ""
    if ($ShouldDelete) {
        Write-Host "Nuking the last $CommitCount commit(s) and wiping all changes..." -ForegroundColor Red
        git reset --hard "HEAD~$CommitCount"
    }
    else {
        Write-Host "Undoing the last $CommitCount commit(s) but keeping your changes staged..." -ForegroundColor Green
        git reset --soft "HEAD~$CommitCount"
    }
}

# ==========================================
# --- MODE 2: CLOUD CLEANUP LOGIC ---
# ==========================================
if ($Scope -eq "2") {
    Write-Host "`nHandling remote cleanup for $CommitCount commit(s)..." -ForegroundColor Yellow
    Write-Host "Is this a shared public branch (e.g., main, master, dev) or your own isolated feature branch?"
    Write-Host "1) Shared Branch (Safe approach: creates reverting commits)"
    Write-Host "2) Isolated Feature Branch (Force-push approach: obliterates remote history)"
    $RemoteStrategy = Read-Host "Select an option (1-2)"

    if ($RemoteStrategy -notmatch '^[12]$') {
        Write-Host "Invalid response, exiting." -ForegroundColor Red
        Exit 1
    }

    # Strategy 2.1: Safe Revert
    if ($RemoteStrategy -eq "1") {
        Write-Host "`nCreating safe revert commits for the last $CommitCount commit(s)..." -ForegroundColor Green
        for ($i = 0; $i -lt $CommitCount; $i++) {
            git revert HEAD --no-edit
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Conflict or error encountered during revert sequence. Aborting loop." -ForegroundColor Red
                Exit 1
            }
        }
        Write-Host "`nReversal commits created locally. Run 'git push' to sync the fixes to the cloud." -ForegroundColor Yellow
    }

    # Strategy 2.2: Force Push
    if ($RemoteStrategy -eq "2") {
        Write-Host "`nWARNING: This will rewrite remote history and overwrite the cloud branch back $CommitCount commit(s)." -ForegroundColor Red
        $Confirm = Read-Host "Are you absolutely sure you want to force-push? (type 'FORCE' to confirm)"
        
        if ($Confirm -ne "FORCE") {
            Write-Host "Aborting force-push operation." -ForegroundColor Yellow
            Exit 1
        }

        if ($Delete) {
            Write-Host "`nWiping local commits, changes..." -ForegroundColor Red
            git reset --hard "HEAD~$CommitCount"
        }
        else {
            Write-Host "`nWiping local commits (keeping changes staged)..." -ForegroundColor Red
            git reset --soft "HEAD~$CommitCount"
        }
        
        Write-Host "Attempting safe force-push (--force-with-lease)..." -ForegroundColor Cyan
        git push origin $CurrentBranch --force-with-lease

        # If lease check passes, skip the override prompt
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Remote history updated successfully via force-with-lease." -ForegroundColor Green
        }
        else {
            Write-Host "`n[!] ALERT: --force-with-lease FAILED." -ForegroundColor Red
            Write-Host "This means the remote branch contains upstream changes you don't have locally." -ForegroundColor Yellow
            
            $Override = Read-Host "Do you want to override this safety check and forcefully overwrite the cloud branch anyway? (y/N)"
            if ($Override -match "^[yY](es)?$") {
                Write-Host "`nBypassing protection and executing full force-push..." -ForegroundColor Red
                git push origin $CurrentBranch --force
            }
            else {
                Write-Host "Aborting. Your local branch has been reset, but the remote branch remains untouched." -ForegroundColor Yellow
                Exit 1
            }
        }
    }
}

# 5. Output the final Git status
Write-Host "`n--- Updated Git Status ---" -ForegroundColor Cyan
git status -s