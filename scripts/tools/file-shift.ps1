[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, Position = 0)]
    [Alias('p')]
    [string]$Prefix
)

# 1. Handle Prefix Input
if ([string]::IsNullOrWhiteSpace($Prefix)) {
    $Prefix = Read-Host "Enter the prefix for renaming (e.g., 'wedding-photo-')"
}

# 2. Gather target files (Excluding the script itself)
$TargetFiles = Get-ChildItem -File | Where-Object { $_.Name -ne $MyInvocation.MyCommand.Name }

if ($TargetFiles.Count -eq 0) {
    Write-Host "No files found in the current directory to rename." -ForegroundColor Yellow
    exit
}

# 3. Generate Previews and Confirm
Write-Host "`n--- FILES FOUND & PREVIEW ---" -ForegroundColor Cyan
Write-Host "Total files found: $($TargetFiles.Count)`n" -ForegroundColor Cyan

$Counter = 1
$RenameList = [System.Collections.Generic.List[PSObject]]::new()

foreach ($file in $TargetFiles) {
    $NewName = "${Prefix}${Counter}$($file.Extension)"
    
    # Print the side-by-side preview directly
    Write-Host "  -> $($file.Name) " -ForegroundColor White -NoNewline
    Write-Host "---> " -ForegroundColor DarkGray -NoNewline
    Write-Host $NewName -ForegroundColor Yellow
    
    # Store the details for the actual execution loop later
    $RenameList.Add([PSCustomObject]@{
            File    = $file
            NewName = $NewName
        })
    
    $Counter++
}
Write-Host "----------------------------`n"

$Confirm = Read-Host "Are you sure you want to execute these renames? (Y/N)"
if ($Confirm -notmatch '^[Yy]') {
    Write-Host "Operation cancelled." -ForegroundColor Yellow
    exit
}

# 4. Perform the renaming
Write-Host ""
$SuccessCount = 0
foreach ($item in $RenameList) {
    try {
        Rename-Item -Path $item.File.FullName -NewName $item.NewName -ErrorAction Stop
        Write-Host "Successfully Renamed: $($item.File.Name) -> $($item.NewName)" -ForegroundColor Green
        $SuccessCount++
    }
    catch {
        Write-Host "Failed to rename $($item.File.Name): $_" -ForegroundColor Red
    }
}

Write-Host "`nDone! Successfully renamed $SuccessCount files." -ForegroundColor Cyan