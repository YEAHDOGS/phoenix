param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string]$Path
)

$resolvedPath = (Resolve-Path $Path).Path
$item = Get-Item $resolvedPath

# Helper function for Owner info
function Get-FileOwner ($itemPath) {
    return (Get-Acl $itemPath).Owner
}

# Helper function for .NET hashing
function Get-NetHash ($filePath) {
    $stream = [System.IO.File]::OpenRead($filePath)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha.ComputeHash($stream)
    $stream.Close()
    return [System.Convert]::ToHexString($hashBytes)
}

if (Test-Path $resolvedPath -PathType Leaf) {
    # SINGLE FILE LOGIC
    [PSCustomObject]@{
        Path         = $resolvedPath
        Algorithm    = "SHA256"
        Hash         = Get-NetHash $resolvedPath
        Size_KB      = [math]::Round($item.Length / 1KB, 2)
        Created      = $item.CreationTime
        LastModified = $item.LastWriteTime
        Owner        = Get-FileOwner $resolvedPath
    }
} 
elseif (Test-Path $resolvedPath -PathType Container) {
    # FOLDER LOGIC
    Write-Host "Calculating aggregate metadata for folder (Parallel .NET): $resolvedPath" -ForegroundColor Cyan
    
    $allFiles = Get-ChildItem -Path $resolvedPath -Recurse -File
    
    if ($allFiles.Count -eq 0) {
        Write-Warning "The folder is empty or contains no files."
        return
    }

    # Parallel Processing for Speed
    # We collect all metadata in one pass to avoid multiple disk hits
    $fileData = $allFiles | ForEach-Object -Parallel {
        $stream = [System.IO.File]::OpenRead($_.FullName)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hBytes = $sha.ComputeHash($stream)
        $stream.Close()
        
        [PSCustomObject]@{
            FullName      = $_.FullName
            Hash          = [System.Convert]::ToHexString($hBytes)
            Length        = $_.Length
            CreationTime  = $_.CreationTime
            LastWriteTime = $_.LastWriteTime
        }
    } -ThrottleLimit 8

    # Sort by FullName to ensure deterministic aggregate hashing
    $sortedData = $fileData | Sort-Object FullName

    # PURE LOGIC: If 1 file, treat folder as that file
    if ($sortedData.Count -eq 1) {
        $single = $sortedData[0]
        return [PSCustomObject]@{
            Path         = $resolvedPath
            Algorithm    = "SHA256"
            Hash         = $single.Hash
            Size_KB      = [math]::Round($single.Length / 1KB, 2)
            Created      = $single.CreationTime
            LastModified = $single.LastWriteTime
            Owner        = Get-FileOwner $single.FullName
        }
    }

    # AGGREGATE LOGIC: Multiple files
    $combinedString = ($sortedData | Select-Object -ExpandProperty Hash) -join ""
    $stringBytes = [System.Text.Encoding]::UTF8.GetBytes($combinedString)
    $finalHashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash($stringBytes)
    $finalHash = [System.Convert]::ToHexString($finalHashBytes)

    # Aggregate Metadata
    $totalSize = ($sortedData | Measure-Object -Property Length -Sum).Sum
    $latestUpdate = ($sortedData | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime

    [PSCustomObject]@{
        Path         = $resolvedPath
        Algorithm    = "SHA256 (Aggregate)"
        Hash         = $finalHash
        Size_KB      = [math]::Round($totalSize / 1KB, 2)
        Created      = $item.CreationTime
        LastModified = $latestUpdate
        Owner        = Get-FileOwner $resolvedPath
    }
}
else {
    Write-Error "The path '$Path' does not exist."
}