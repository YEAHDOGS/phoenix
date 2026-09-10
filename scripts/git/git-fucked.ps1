param (
    [Switch]$Delete,
    # By default every push in this script is --dry-run (safe rehearsal).
    # Pass -RealPush to actually move remote refs. Modes that rewrite
    # history will tell you which mode they're in.
    [Switch]$RealPush
)

$PushFlags = if ($RealPush) { @() } else { @("--dry-run") }
if (-not $RealPush) {
    Write-Host "[dry-run] No remote refs will be moved. Pass -RealPush to execute for real." -ForegroundColor DarkYellow
}

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
    git push @PushFlags origin "temporary-purge-branch:$Branch" --force

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
    git push @PushFlags origin $Branch --force

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
Write-Host "7) Too many branches"
$Scope = Read-Host "Select an option (1-7)"

if ($Scope -notmatch '^[1234567]$') {
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
        
    git push @PushFlags origin $CurrentBranch --force-with-lease
    if ($LASTEXITCODE -ne 0) {
        $Override = Read-Host "--force-with-lease failed. Force overwrite anyway? (y/N)"
        if ($Override -match "^[yY](es)?$") { git push @PushFlags origin $CurrentBranch --force }
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
    git push @PushFlags origin $CurrentBranch

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

# --- MODE 7: MASS DELETE BRANCHES ---
if ($Scope -eq "7") {
    Write-Host "`n[➔] BRANCH PURGE MATRIX ACQUISITION [➔]" -ForegroundColor Magenta

    # Fetch latest remote references and clean up dead tracking refs
    Write-Host "Syncing with GitHub remote references..." -ForegroundColor Cyan
    git fetch origin --prune 2>$null

    # Get current branch so we don't accidentally try to delete it locally
    $CurrentBranch = (git branch --show-current).Trim()

    # Get a definitive real-time list of branch names that currently exist on GitHub
    $OnlineBranches = git ls-remote --heads origin | ForEach-Object {
        if ($_ -match "refs/heads/(.+)") { $Matches[1].Trim() }
    }

    # Gather local branch data: Name, Last Commit Relative Time, and Remotes tracking info
    $BranchRawData = git branch --format="%(refname:short)|%(committerdate:relative)|%(upstream)"
    
    $BranchList = [System.Collections.Generic.List[PSObject]]::new()
    $Index = 1

    foreach ($Line in $BranchRawData) {
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }
        $Parts = $Line.Split('|')
        $BName = $Parts[0].Trim()
        $Age   = $Parts[1].Trim()
        $Remote= $Parts[2].Trim()

        # Skip the currently active branch from deletion selection
        if ($BName -eq $CurrentBranch) { continue }

        # Determine online availability status based strictly on the live GitHub snapshot
        $StatusText = "Local Only"
        $StatusColor = "Yellow"

        if ($OnlineBranches -contains $BName) {
            $StatusText = "Available Online"
            $StatusColor = "Green"
        } elseif (![string]::IsNullOrWhiteSpace($Remote)) {
            # Upstream ref exists locally, but branch is missing from live GitHub query
            $StatusText = "Deleted Online"
            $StatusColor = "Red"
        }

        $BranchList.Add([PSCustomObject]@{
            Index       = $Index
            Name        = $BName
            Age         = $Age
            StatusText  = $StatusText
            StatusColor = $StatusColor
        })
        $Index++
    }

    if ($BranchList.Count -eq 0) {
        Write-Host "No other local branches available to delete. (Active branch: $CurrentBranch)" -ForegroundColor Yellow
        Exit 0
    }

    # Display Menu UI Matrix
    Write-Host "`nAvailable Local Branches for Purge:" -ForegroundColor Cyan
    Write-Host ("{0,-5} {1,-30} {2,-20} {3,-15}" -f "ID", "Branch Name", "Last Activity", "GitHub Status") -ForegroundColor White
    Write-Host ("{0,-5} {1,-30} {2,-20} {3,-15}" -f "--", "-----------", "-------------", "-------------") -ForegroundColor White

    foreach ($B in $BranchList) {
        Write-Host ("{0,-5} {1,-30} {2,-20} " -f $B.Index, $B.Name, $B.Age) -NoNewline
        Write-Host $B.StatusText -ForegroundColor $B.StatusColor
    }

    Write-Host "`nEnter the IDs of the branches you want to delete (comma-separated, e.g., 1,3,4):" -ForegroundColor Yellow
    $SelectionInput = Read-Host "Selection"

    if ([string]::IsNullOrWhiteSpace($SelectionInput)) {
        Write-Host "No selection made. Aborting." -ForegroundColor Red
        Exit 1
    }

    # Parse inputs (supporting individual IDs and ranges like 3-5, 6, 8-12)
    $SelectedIDs = [System.Collections.Generic.HashSet[string]]::new()
    $RawTokens = $SelectionInput.Split(',') | ForEach-Object { $_.Trim() }

    foreach ($Token in $RawTokens) {
        if ($Token -match '^(\d+)-(\d+)$') {
            # It's a range (e.g., 3-5)
            $Start = [int]$Matches[1]
            $End = [int]$Matches[2]
            
            # Ensure the range is valid, then loop through it
            if ($Start -le $End) {
                for ($i = $Start; $i -le $End; $i++) {
                    [void]$SelectedIDs.Add($i.ToString())
                }
            }
        } elseif ($Token -match '^\d+$') {
            # It's a single ID (e.g., 6)
            [void]$SelectedIDs.Add($Token)
        }
    }

    $TargetsToDelete = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($ID in $SelectedIDs) {
        $Match = $BranchList | Where-Object { $_.Index -eq $ID }
        if ($Match) { $TargetsToDelete.Add($Match) }
    }

    if ($TargetsToDelete.Count -eq 0) {
        Write-Host "No valid matching branch IDs selected. Aborting." -ForegroundColor Red
        Exit 1
    }

    # Action Confirmation Display
    Write-Host "`nSelected targets for extraction/purge:" -ForegroundColor Red
    foreach ($T in $TargetsToDelete) {
        Write-Host " ➔ $($T.Name) ($($T.Age))" -ForegroundColor White
    }

    Write-Host "`nHow do you want to handle unmerged changes?" -ForegroundColor Yellow
    Write-Host "1) Safe Delete (-d : Aborts execution if branch contains unmerged work)"
    Write-Host "2) Force Purge (-D : FORCE destroys branch irrespective of merge status!)"
    $PurgeAction = Read-Host "Select action (1-2)"

    $DeleteFlag = "-d"
    if ($PurgeAction -eq "2") {
        $Confirm = Read-Host "`nType 'PURGE' to verify lethal execution override"
        if ($Confirm -ne "PURGE") { Write-Host "Aborting force purge."; Exit 1 }
        $DeleteFlag = "-D"
    } elseif ($PurgeAction -ne "1") {
        Write-Host "Invalid action selected. Aborting." -ForegroundColor Red
        Exit 1
    }

    # Execution Loop
    Write-Host "`nExecuting branch purge pipeline..." -ForegroundColor Magenta
    foreach ($Target in $TargetsToDelete) {
        Write-Host "Deleting branch '$($Target.Name)'..." -ForegroundColor Cyan
        git branch $DeleteFlag $($Target.Name)
    }

    Write-Host "`nPurge operation complete." -ForegroundColor Green
}

# 5. Output the final Git status
Write-Host "`n--- Updated Git Status ---" -ForegroundColor Cyan
git status -s