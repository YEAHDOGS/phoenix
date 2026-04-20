param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string]$Path
)

$resolvedPath = Resolve-Path $Path

if (Test-Path $resolvedPath -PathType Leaf) {
    # File, get hash
    Get-FileHash -Path $resolvedPath
} 
elseif (Test-Path $resolvedPath -PathType Container) {
    # Folder, get clever
    Write-Host "Calculating aggregate hash for folder: $resolvedPath" -ForegroundColor Cyan
    
    $fileHashes = Get-ChildItem -Path $resolvedPath -Recurse -File | 
    Get-FileHash | 
    Select-Object -ExpandProperty Hash | 
    Sort-Object

    if ($fileHashes.Count -eq 0) {
        Write-Warning "The folder is empty or contains no files."
        return
    }

    # Combine all file hashes into one master string to represent the folder state
    $combinedString = $fileHashes -join ""
    $stringBytes = [System.Text.Encoding]::UTF8.GetBytes($combinedString)
    
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $finalHashBytes = $sha256.ComputeHash($stringBytes)
    
    # Format the byte array into a hex string
    $finalHash = [System.BitConverter]::ToString($finalHashBytes) -replace "-"
    
    [PSCustomObject]@{
        Path      = $resolvedPath
        Algorithm = "SHA256 (Aggregate)"
        Hash      = $finalHash
    }
}
else {
    Write-Error "The path '$Path' does not exist."
}