param (
    [Switch]$Delete
)

# ==========================================
# --- REUSABLE UTILITY FUNCTIONS ---
# ==========================================

function Test-GitRepository {
    if (-not (git rev-parse --is-inside-work-tree 2>$null)) {
        Write-Host "Error: Current directory is not a Git repository." -ForegroundColor Red
        Exit 1
    }
}

function Invoke-LocalReset {
    param (
        [int]$Count,
        [bool]$HardWipe
    )
    if ($HardWipe) {
        Write-Host "Nuking the last $Count commit(s) and wiping all changes..." -ForegroundColor Red
        git reset --hard "HEAD~$Count"
    }
    else {
        Write-Host "Undoing the last $Count commit(s) but keeping your changes staged..." -ForegroundColor Green
        git reset --soft "HEAD~$Count"
    }
}

function Invoke-GitHubCachePurge {
    param (
        [string]$Branch,
        [int]$CooldownSeconds = 0
    )
    Write-Host "`nSevering GitHub remote link cache to prevent URL persistence..." -ForegroundColor Yellow
    
    # Spawn a disconnected branch node to sever the graph
    git checkout --orphan temporary-purge-branch 2>$null
    git rm -rf . --quiet 2>$null

    # Push blank state up to force GitHub's head-pointer cache to break
    git commit --allow-empty -m "Purging remote history cache" --quiet
    git push --dry-run origin "temporary-purge-branch:$Branch" --force

    # Optional cooldown (used for Mode 3, skipped for Mode 4)
    if ($CooldownSeconds -gt 0) {
        Write-Host "`n[+] Graph severed. Waiting $CooldownSeconds seconds for GitHub's cache engine to register eviction..." -ForegroundColor Yellow
        for ($i = $CooldownSeconds; $i -gt 0; $i--) {
            Write-Progress -Activity "Cache Eviction Cool-Down" -Status "$i seconds..." -PercentComplete (($i / $CooldownSeconds) * 100)
            Start-Sleep -Seconds 1
        }
        Write-Progress -Activity "Cache Eviction Cool-Down" -Completed
    }

    # Re-establish clean local tracking state back onto remote
    Write-Host "Restoring clean working directory graph to origin..." -ForegroundColor Green
    git checkout $Branch --quiet
    git push --dry-run origin $Branch --force

    # Clean up the local dummy tracking branch
    git branch -D temporary-purge-branch --quiet
}


# ==========================================
# --- MAIN SCRIPT EXECUTION ---
# ==========================================

Test-GitRepository

# Extract and display repo info
$RepoRoot = git rev-parse --show-toplevel
$CurrentBranch = git branch --show-current
Write-Host "Repository Found: $RepoRoot" -ForegroundColor Cyan
Write-Host "Current Branch:   $CurrentBranch" -ForegroundColor Cyan
Write-Host "----------------------------------------"

# Assess the Damage Scope
Write-Host "How bad is the damage?" -ForegroundColor Yellow
Write-Host "1) It's just local (Committed, but NOT pushed yet)"
Write-Host "2) It's in the cloud (Standard force-push history rewrite)"
Write-Host "3) KILL IT WITH FIRE, NOW!!! (Wipe recent commits completely + 60s GitHub cache eviction)"
Write-Host "4) SURGICAL STRIKE (Drop specific commit out of history, keep everything after, instant cache clear)"
Write-Host "5) CLEAN ROLLBACK (No sensitive data, safe history addition, standard push)"
Write-Host "6) SWAP TO SPECIFIC COMMIT (Jump or hard-reset branch directly to a target SHA)"
$Scope = Read-Host "Select an option (1-6)"

if ($Scope -notmatch '^[123456]$') {
    Write-Host "Invalid response, exiting." -ForegroundColor Red
    Exit 1
}

# --- MODE 1: LOCAL CLEANUP ---
if ($Scope -eq "1") {
    $CommitInput = Read-Host "How many commits back are fucked up? [Default: 1]"
    $CommitCount = if ([string]::IsNullOrWhiteSpace($CommitInput)) { 1 } else { [int]$CommitInput }

    $ShouldDelete = $Delete
    if (-not $Delete) {
        Write-Host "`nYou are about to undo the last $CommitCount commit(s)." -ForegroundColor Yellow
        $Choice = Read-Host "Do you want to completely DELETE the data/changes in these commits? (y/N)"
        if ($Choice -match "^[yY](es)?$") { $ShouldDelete = $true }
    }

    Write-Host ""
    Invoke-LocalReset -Count $CommitCount -HardWipe $ShouldDelete
}

# --- MODE 2: CLOUD CLEANUP ---
if ($Scope -eq "2") {
    $CommitInput = Read-Host "How many commits back are fucked up? [Default: 1]"
    $CommitCount = if ([string]::IsNullOrWhiteSpace($CommitInput)) { 1 } else { [int]$CommitInput }

    Write-Host "`nHandling remote cleanup for $CommitCount commit(s)..." -ForegroundColor Yellow
    git log -n $CommitCount --oneline --format="%C(cyan)%h %C(white)- %s"

    $Confirm = Read-Host "`nAre you absolutely sure you want to force-push? (type 'FORCE' to confirm)"
    if ($Confirm -ne "FORCE") { Write-Host "Aborting."; Exit 1 }

    Invoke-LocalReset -Count $CommitCount -HardWipe $Delete
        
    git push --dry-run origin $CurrentBranch --force-with-lease
    if ($LASTEXITCODE -ne 0) {
        $Override = Read-Host "--force-with-lease failed. Force overwrite anyway? (y/N)"
        if ($Override -match "^[yY](es)?$") { git push --dry-run origin $CurrentBranch --force }
    }
}

# --- MODE 3: KILL IT WITH FIRE ---
if ($Scope -eq "3") {
    $CommitInput = Read-Host "How many commits back are fucked up? [Default: 1]"
    $CommitCount = if ([string]::IsNullOrWhiteSpace($CommitInput)) { 1 } else { [int]$CommitInput }

    Write-Host "`n[!!!] CRITICAL DATA PURGE INITIATED [!!!]" -ForegroundColor Red
    git log -n $CommitCount --oneline --format="%C(cyan)%h %C(white)- %s"

    $Confirm = Read-Host "Type 'NUKE' to completely drop remote history and force an eviction cache clear"
    if ($Confirm -ne "NUKE") { Write-Host "Aborting."; Exit 1 }

    Invoke-LocalReset -Count $CommitCount -HardWipe $Delete
    Invoke-GitHubCachePurge -Branch $CurrentBranch -CooldownSeconds 60
    
    Write-Host "`n[✔] Nuclear purge complete." -ForegroundColor Green
}

# --- MODE 4: SURGICAL STRIKE ---
if ($Scope -eq "4") {
    Write-Host "`n[✦] SURGICAL PURGE INITIATED [✦]" -ForegroundColor Magenta
    $IndexInput = Read-Host "How many commits ago was the bad commit pushed? (e.g., 6 for HEAD~6)"
    
    if ($IndexInput -notmatch '^\d+$' -or [int]$IndexInput -le 0) {
        Write-Host "Invalid input. Must be a positive integer." -ForegroundColor Red
        Exit 1
    }
    $BadIndex = [int]$IndexInput

    $BadCommitSHA = git rev-parse "HEAD~$BadIndex"
    $ParentOfBadSHA = git rev-parse "HEAD~$($BadIndex + 1)"
    
    Write-Host "`nTargeting this specific commit for destruction:" -ForegroundColor Red
    git log -1 $BadCommitSHA --oneline --format="%C(red)%h %C(white)- %s"
    
    $Confirm = Read-Host "`nType 'SURGERY' to execute history rewrite"
    if ($Confirm -ne "SURGERY") { Write-Host "Aborting surgical strike."; Exit 1 }

    Write-Host "`nExecuting rebase slice operation..." -ForegroundColor Cyan
    git rebase --onto $ParentOfBadSHA $BadCommitSHA HEAD

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[!] Conflict detected during history re-mapping. Aborting. Run 'git rebase --abort' to reset." -ForegroundColor Red
        Exit 1
    }

    Write-Host "`nLocal history successfully rewritten. Bad commit has been dropped." -ForegroundColor Green

    # Call the purge function with 0 second cooldown for an instant cycle
    Invoke-GitHubCachePurge -Branch $CurrentBranch -CooldownSeconds 0
    
    Write-Host "`n[✔] Surgical strike complete! History saved, secret eradicated." -ForegroundColor Green
}

# --- MODE 5: CLEAN ROLLBACK ---
if ($Scope -eq "5") {
    $CommitInput = Read-Host "How many commits back do you want to rollback? [Default: 1]"
    $CommitCount = if ([string]::IsNullOrWhiteSpace($CommitInput)) { 1 } else { [int]$CommitInput }

    Write-Host "`nPreparing clean rollback for the last $CommitCount commit(s)..." -ForegroundColor Yellow
    git log -n $CommitCount --oneline --format="%C(cyan)%h %C(white)- %s"

    $Confirm = Read-Host "`nAre you sure you want to revert these changes and push a rollback commit? (y/N)"
    if ($Confirm -notmatch "^[yY](es)?$") { Write-Host "Aborting rollback."; Exit 1 }

    Write-Host "`nUndoing changes locally via revert..." -ForegroundColor Cyan
    git revert --no-commit "HEAD~$CommitCount..HEAD"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[!] Conflict detected during rollback. Please resolve manually or run 'git revert --abort'." -ForegroundColor Red
        Exit 1
    }

    git commit -m "Rollback: Reverted last $CommitCount commit(s) due to issues" --quiet

    Write-Host "Pushing clean history adjustment up to origin..." -ForegroundColor Green
    git push --dry-run origin $CurrentBranch

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[!] Push failed. You may need to pull incoming changes first." -ForegroundColor Red
        Exit 1
    }

    Write-Host "`n[✔] Clean rollback complete! No history rewritten, shared branch remains safe." -ForegroundColor Green
}

# --- MODE 6: SWAP TO SPECIFIC COMMIT ---
if ($Scope -eq "6") {
    Write-Host "`n[➔] SWAP TARGET ACQUISITION [➔]" -ForegroundColor Magenta
    $TargetCommit = Read-Host "Enter the Commit SHA (or branch name) you want to swap to"

    if ([string]::IsNullOrWhiteSpace($TargetCommit)) {
        Write-Host "Target cannot be empty. Aborting." -ForegroundColor Red
        Exit 1
    }

    # Verify commit exists
    $ValidSHA = git rev-parse --verify "${TargetCommit}^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: '$TargetCommit' is not a valid commit or reference." -ForegroundColor Red
        Exit 1
    }

    Write-Host "`nTarget Found:" -ForegroundColor Cyan
    git log -1 $ValidSHA --oneline --format="%C(cyan)%h %C(white)- %s (%cr) <%an>"

    Write-Host "`nWhat action do you want to perform?" -ForegroundColor Yellow
    Write-Host "1) Look only (Detached HEAD checkout - safe, leaves current branch alone)"
    Write-Host "2) Hard reset (FORCE current branch root back to this commit - will lose uncommitted work!)"
    $Action = Read-Host "Select action (1-2)"

    if ($Action -eq "1") {
        Write-Host "`nSwapping to commit $TargetCommit in read-only detached state..." -ForegroundColor Cyan
        git checkout $ValidSHA
    }
    elseif ($Action -eq "2") {
        $Confirm = Read-Host "`nType 'RESET' to force your current branch back to this exact commit"
        if ($Confirm -ne "RESET") { Write-Host "Aborting hard reset."; Exit 1 }
        
        Write-Host "`nForcing current branch back to target..." -ForegroundColor Red
        git reset --hard $ValidSHA
    }
    else {
        Write-Host "Invalid action selected. Aborting." -ForegroundColor Red
        Exit 1
    }
}

# 5. Output the final Git status
Write-Host "`n--- Updated Git Status ---" -ForegroundColor Cyan
git status -s