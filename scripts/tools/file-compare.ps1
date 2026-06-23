# # Get paths for both files
# $file1 = "C:\Users\Brando\Downloads\Antigravity IDE.exe"
# $file2 = "C:\Users\Brando\Downloads\Antigravity IDE (1).exe"

# $file1 = $file1.Trim("`"'")
# $file2 = $file2.Trim("`"'")

# if (-not (Test-Path -Path $file1 -PathType Leaf)) { Write-Error "File 1 not found"; exit 1 }
# if (-not (Test-Path -Path $file2 -PathType Leaf)) { Write-Error "File 2 not found"; exit 1 }

# # Initialize MD5 crypto provider for quick block hashing
# $md5 = [System.Security.Cryptography.MD5]::Create()

# # Open both files as high-speed read-only streams
# $stream1 = [System.IO.File]::Open($file1, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
# $stream2 = [System.IO.File]::Open($file2, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)

# # 4MB Chunk Buffers
# $bufferSize = 4 * 1024 * 1024
# $buffer1 = New-Object byte[] $bufferSize
# $buffer2 = New-Object byte[] $bufferSize

# Write-Host "`n[+] Running high-speed binary block comparison (4MB chunks)..." -ForegroundColor Cyan

# $position = 0
# $mismatchFound = $false
# $hasDiverged = $false

# try {
#     while ($true) {
#         $bytesRead1 = $stream1.Read($buffer1, 0, $bufferSize)
#         $bytesRead2 = $stream2.Read($buffer2, 0, $bufferSize)
        
#         # Break out if both files hit EOF
#         if ($bytesRead1 -eq 0 -and $bytesRead2 -eq 0) { break }
        
#         # Check if one file is shorter than the other
#         if ($bytesRead1 -ne $bytesRead2) {
#             Write-Host "[!] Files diverge in size or structure at offset: $position bytes" -ForegroundColor Red
#             $hasDiverged = $true
#             break
#         }
        
#         # Hash the blocks to check for structural changes
#         $hash1 = [System.BitConverter]::ToString($md5.ComputeHash($buffer1, 0, $bytesRead1))
#         $hash2 = [System.BitConverter]::ToString($md5.ComputeHash($buffer2, 0, $bytesRead2))
        
#         if ($hash1 -ne $hash2) {
#             Write-Host "[!] Modification detected between offset $position and $($position + $bytesRead1) bytes" -ForegroundColor Yellow
#             $mismatchFound = $true
#         }
        
#         $position += $bytesRead1
#     }
    
#     if (-not $mismatchFound -and -not $hasDiverged) {
#         Write-Host "`n[+] Complete Success: Binaries are 100% identical block-for-block." -ForegroundColor Green
#     }
#     elseif ($mismatchFound) {
#         Write-Host "`n[+] Scan complete. The files are the same size, but changes were made inside the modified blocks listed above." -ForegroundColor Magenta
#     }
# }
# finally {
#     $stream1.Close(); $stream1.Dispose()
#     $stream2.Close(); $stream2.Dispose()
#     $md5.Dispose()
# }





# Get paths for both files
$file1 = "C:\Users\Brando\Downloads\Antigravity IDE.exe"
$file2 = "C:\Users\Brando\Downloads\Antigravity IDE (1).exe"

$file1 = $file1.Trim("`"'")
$file2 = $file2.Trim("`"'")

if (-not (Test-Path -Path $file1 -PathType Leaf)) { Write-Error "ERROR: Cannot find File 1. Check the path!"; exit 1 }
if (-not (Test-Path -Path $file2 -PathType Leaf)) { Write-Error "ERROR: Cannot find File 2. Check the path!"; exit 1 }

# Initialize MD5 for blazing fast comparison
$md5 = [System.Security.Cryptography.MD5]::Create()

# Open files cleanly
$stream1 = [System.IO.File]::Open($file1, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
$stream2 = [System.IO.File]::Open($file2, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)

$bufferSize = 4 * 1024 * 1024
$buffer1 = New-Object byte[] $bufferSize
$buffer2 = New-Object byte[] $bufferSize

Clear-Host
Write-Host "`n[~] Scanning binaries at high speed for text modifications..." -ForegroundColor Cyan

$filesAreIdentical = $true
$regex = [regex]"[ -~]{5,}" # Matches readable text strings 5+ characters long to skip background noise
$printedDiffs = 0
$maxDiffsToPrint = 40 # Prevent console flooding

try {
    while ($true) {
        $bytesRead1 = $stream1.Read($buffer1, 0, $bufferSize)
        $bytesRead2 = $stream2.Read($buffer2, 0, $bufferSize)
        
        # Stop if we hit the end of both files
        if ($bytesRead1 -eq 0 -and $bytesRead2 -eq 0) { break }
        
        # If one file ends early, they are instantly different
        if ($bytesRead1 -ne $bytesRead2) {
            $filesAreIdentical = $false
            Write-Host "`n[!] WARNING: Files diverge in physical size!" -ForegroundColor Red
            break
        }
        
        # Quick hash check of the entire 4MB block
        $hash1 = [System.BitConverter]::ToString($md5.ComputeHash($buffer1, 0, $bytesRead1))
        $hash2 = [System.BitConverter]::ToString($md5.ComputeHash($buffer2, 0, $bytesRead2))
        
        if ($hash1 -ne $hash2) {
            $filesAreIdentical = $false
            
            # Extract text ONLY from this specific modified 4MB block
            $text1 = [System.Text.Encoding]::ASCII.GetString($buffer1, 0, $bytesRead1)
            $text2 = [System.Text.Encoding]::ASCII.GetString($buffer2, 0, $bytesRead2)
            
            $strings1 = $regex.Matches($text1) | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique
            $strings2 = $regex.Matches($text2) | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique
            
            # Find strings that exist in File 2 but are entirely missing from File 1
            foreach ($str in $strings2) {
                if ($strings1 -notcontains $str) {
                    if ($printedDiffs -lt $maxDiffsToPrint) {
                        Write-Host "  [+] Added String Found: $str" -ForegroundColor Magenta
                        $printedDiffs++
                    }
                }
            }
        }
    }
    
    # --- DIRT FINAL SIMPLE OUTPUT ---
    Write-Host "`n==================================================" -ForegroundColor Yellow
    
    if ($filesAreIdentical) {
        Write-Host "  [+] THE TWO FILES ARE EXACTLY THE SAME!" -ForegroundColor Green
        Write-Host "  No changes found. They are identical twins." -ForegroundColor Green
    }
    else {
        Write-Host "  [!] WARNING: THE FILES ARE DIFFERENT!" -ForegroundColor Red
        Write-Host "  Review the unique text strings printed above to see what was injected." -ForegroundColor Red
    }
    
    Write-Host "==================================================" -ForegroundColor Yellow
    Write-Host ""
}
finally {
    $stream1.Close(); $stream1.Dispose()
    $stream2.Close(); $stream2.Dispose()
    $md5.Dispose()
}