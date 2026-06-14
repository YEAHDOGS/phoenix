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
    git push origin "temporary-purge-branch:$Branch" --force

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
    git push origin $Branch --force

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
$Scope = Read-Host "Select an option (1-4)"

if ($Scope -notmatch '^[1234]$') {
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
        
    git push origin $CurrentBranch --force-with-lease
    if ($LASTEXITCODE -ne 0) {
        $Override = Read-Host "--force-with-lease failed. Force overwrite anyway? (y/N)"
        if ($Override -match "^[yY](es)?$") { git push origin $CurrentBranch --force }
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

# 5. Output the final Git status
Write-Host "`n--- Updated Git Status ---" -ForegroundColor Cyan
git status -s