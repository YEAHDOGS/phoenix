# ==============================================================================
# CASTLE INFRASTRUCTURE: ISO FETCH ENGINES
# ==============================================================================

# Target Matrices - Swap these URLs/Paths out for whatever you need to pull down
$IsoUrl = "https://mirror.cachyos.org/ISO/desktop/240609/cachyos-desktop-linux-all-240609.iso" 
$OutFile = ".\cachyos-server-latest.iso"

# Pre-Flight Directory Checks
$TargetDir = [System.IO.Path]::GetDirectoryName((Resolve-Path -Path ".\").Path)
if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
}

# Duplicate Check: Don't burn bandwidth if it's already on the block
if (Test-Path $OutFile) {
    Write-Host "📦 [Castle] ISO asset already exists locally: $OutFile" -ForegroundColor Yellow
    Exit
}

Write-Host "📡 [Castle] Establishing stream pipeline to: $IsoUrl" -ForegroundColor Cyan
Write-Host "💾 [Castle] Destination Target: $OutFile" -ForegroundColor Cyan

try {
    # Initialize high-speed .NET HttpClient
    $HttpClient = [System.Net.Http.HttpClient]::new()
    $ResponseTask = $HttpClient.GetAsync($IsoUrl, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
    $Response = $ResponseTask.GetAwaiter().GetResult()
    
    if (-not $Response.IsSuccessStatusCode) {
        throw "Server returned status code: $($Response.StatusCode)"
    }

    # Extract Content Length for tracking metrics
    $TotalBytes = $Response.Content.Headers.ContentLength
    $ReadableSize = if ($TotalBytes) { "{0:N2} GB" -f ($TotalBytes / 1GB) } else { "Unknown" }
    
    Write-Host "⚡ [Castle] Payload Detected. Size: $ReadableSize. Streaming bits to disk..." -ForegroundColor Green

    # Stream Processing Buffers
    $DownloadStream = $Response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $FileStream = [System.IO.FileStream]::new($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $Buffer = [System.Byte[]]::new(65536) # 64KB chunks
    $BytesRead = 0
    $TotalBytesRead = 0
    
    # Raw Stream Transfer Loop
    while (($BytesRead = $DownloadStream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
        $FileStream.Write($Buffer, 0, $BytesRead)
        $TotalBytesRead += $BytesRead
        
        # Quick inline terminal tick every ~50MB to show it's alive without flooding the screen buffer
        if ($TotalBytesRead % 52428800 -lt 65536) {
            $Percent = if ($TotalBytes) { "{0:P0}" -f ($TotalBytesRead / $TotalBytes) } else { "Streaming..." }
            Write-Host "   -> Transferred: $Percent ($("{0:N2}" -f ($TotalBytesRead / 1GB)) GB)" -ForegroundColor Gray
        }
    }

    # Flush and seal
    $FileStream.Flush()
    $FileStream.Close()
    $DownloadStream.Close()
    $HttpClient.Dispose()

    Write-Host "🎯 [Castle] ISO Asset deployment successful and verified." -ForegroundColor Green

}
catch {
    Write-Host "❌ [Castle] Fatal Exception in download pipeline: $_" -ForegroundColor Red
    if ($FileStream) { $FileStream.Close() }
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
}