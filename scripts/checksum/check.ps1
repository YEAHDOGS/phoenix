param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string]$Path
)

$resolvedPath = (Resolve-Path $Path).Path
$item = Get-Item $resolvedPath

# Common function to get owner/creator info
function Get-FileOwner ($itemPath) {
    return (Get-Acl $itemPath).Owner
}

if (Test-Path $resolvedPath -PathType Leaf) {
    # SINGLE FILE LOGIC
    $hash = Get-FileHash -Path $resolvedPath
    
    [PSCustomObject]@{
        Path         = $resolvedPath
        Algorithm    = $hash.Algorithm
        Hash         = $hash.Hash
        Size_KB      = [math]::Round($item.Length / 1KB, 2)
        Created      = $item.CreationTime
        LastModified = $item.LastWriteTime
        Owner        = Get-FileOwner $resolvedPath
    }
} 
elseif (Test-Path $resolvedPath -PathType Container) {
    # FOLDER LOGIC
    Write-Host "Calculating aggregate metadata for folder: $resolvedPath" -ForegroundColor Cyan
    
    $allFiles = Get-ChildItem -Path $resolvedPath -Recurse -File
    
    if ($allFiles.Count -eq 0) {
        Write-Warning "The folder is empty or contains no files."
        return
    }

    $fileHashes = $allFiles | Get-FileHash | Sort-Object Path

    # PURE LOGIC: If 1 file, treat folder as that file
    if ($fileHashes.Count -eq 1) {
        $singleFile = $allFiles[0]
        return [PSCustomObject]@{
            Path         = $resolvedPath
            Algorithm    = $fileHashes[0].Algorithm
            Hash         = $fileHashes[0].Hash
            Size_KB      = [math]::Round($singleFile.Length / 1KB, 2)
            Created      = $singleFile.CreationTime
            LastModified = $singleFile.LastWriteTime
            Owner        = Get-FileOwner $singleFile.FullName
        }
    }

    # AGGREGATE LOGIC: Multiple files
    $combinedString = ($fileHashes | Select-Object -ExpandProperty Hash) -join ""
    $stringBytes = [System.Text.Encoding]::UTF8.GetBytes($combinedString)
    $finalHashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash($stringBytes)
    $finalHash = [System.BitConverter]::ToString($finalHashBytes) -replace "-"

    # Calculate Aggregate Metadata
    $totalSize = ($allFiles | Measure-Object -Property Length -Sum).Sum
    $latestUpdate = ($allFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime

    [PSCustomObject]@{
        Path         = $resolvedPath
        Algorithm    = "SHA256 (Aggregate)"
        Hash         = $finalHash
        Size_KB      = [math]::Round($totalSize / 1KB, 2)
        Created      = $item.CreationTime
        LastModified = $latestUpdate # Shows the latest change within the folder
        Owner        = Get-FileOwner $resolvedPath
    }
}