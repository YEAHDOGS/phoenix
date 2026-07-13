<#
.SYNOPSIS
    Records video and audio using FFmpeg, saving the output in a date-based format and extracting the audio track as an MP3.

.PARAMETER Source
    The video source to record. Options are 'Webcam' (default) or 'Screen'.

.PARAMETER Duration
    Optional recording duration in seconds. If not specified (or 0), records until stopped by user (by pressing 'q').

.PARAMETER VideoDevice
    Specific DirectShow video device to record from. If not specified, the script attempts to find 'HP 5MP Camera', or falls back to the first available camera.

.PARAMETER AudioDevice
    Specific DirectShow audio device to record from. If not specified, the script attempts to find 'Microphone Array (Intel® Smart Sound Technology for Digital Microphones)', or falls back to the first available audio input.

.PARAMETER OutputDir
    Output directory where the recording will be saved. Defaults to 'C:\Users\Brando\Music\Dogs'.

.EXAMPLE
    .\record.ps1 -Source Webcam -Duration 5
    .\record.ps1 -Source Screen
#>

param (
    [ValidateSet('Webcam', 'Screen')]
    [string]$Source = 'Webcam',

    [int]$Duration = 0,

    [string]$VideoDevice = $null,

    [string]$AudioDevice = $null,

    [string]$OutputDir = 'C:\Users\Brando\Music\Dogs'
)

# Enable error action preference
$ErrorActionPreference = "Stop"

# Helper function to discover available DirectShow devices using FFmpeg
function Get-FFmpegDevices {
    Write-Host "Scanning system for audio/video capture devices..." -ForegroundColor Cyan
    # Run ffmpeg to query DirectShow devices (outputs to stderr)
    $pInfo = New-Object System.Diagnostics.ProcessStartInfo
    $pInfo.FileName = "ffmpeg.exe"
    $pInfo.Arguments = "-list_devices true -f dshow -i dummy"
    $pInfo.RedirectStandardError = $true
    $pInfo.UseShellExecute = $false
    $pInfo.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $pInfo
    [void]$proc.Start()
    $stderr = $proc.StandardError.ReadToEnd()
    [void]$proc.WaitForExit()

    $videoDevices = [System.Collections.Generic.List[string]]::new()
    $audioDevices = [System.Collections.Generic.List[string]]::new()

    # Parse stdout/stderr lines
    $lines = $stderr -split "`r?`n"
    foreach ($line in $lines) {
        # Skip lines containing alternative names
        if ($line -match 'Alternative name') { continue }

        # Match lines like: [in#0 @ 0000017e2e80e100] "HP 5MP Camera" (video)
        # Or: [dshow @ 0000017e2e80e100] "Microphone Array (...)" (audio)
        if ($line -match '"([^"]+)"\s+\((video|audio)\)') {
            $name = $Matches[1]
            $type = $Matches[2]
            if ($type -eq 'video') {
                $videoDevices.Add($name)
            } elseif ($type -eq 'audio') {
                $audioDevices.Add($name)
            }
        }
    }

    return [PSCustomObject]@{
        Video = $videoDevices
        Audio = $audioDevices
    }
}

# 1. Ensure output directory exists
if (!(Test-Path -Path $OutputDir)) {
    Write-Host "Creating output directory: $OutputDir" -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# 2. Get the date-based base filename
$year = (Get-Date).Year
$month = (Get-Date).ToString("MMMM").ToLower()
$day = (Get-Date).Day
$baseName = "tiktok$year-$month-$day"

$finalPathMp4 = Join-Path $OutputDir "$baseName.mp4"
$finalPathMp3 = Join-Path $OutputDir "$baseName.mp3"

# Handle file name collisions (add increment suffix if file exists)
$counter = 1
while ((Test-Path -Path $finalPathMp4) -or (Test-Path -Path $finalPathMp3)) {
    $finalPathMp4 = Join-Path $OutputDir "${baseName}_$counter.mp4"
    $finalPathMp3 = Join-Path $OutputDir "${baseName}_$counter.mp3"
    $counter++
}

# 3. Resolve Devices
$devices = Get-FFmpegDevices

# Video Device (only needed for Webcam source)
$selectedVideo = $null
if ($Source -eq 'Webcam') {
    if (-not [string]::IsNullOrEmpty($VideoDevice)) {
        $selectedVideo = $VideoDevice
    } else {
        # Default target
        $targetVideo = "HP 5MP Camera"
        if ($devices.Video.Contains($targetVideo)) {
            $selectedVideo = $targetVideo
        } elseif ($devices.Video.Count -gt 0) {
            $selectedVideo = $devices.Video[0]
            Write-Host "Webcam '$targetVideo' not found. Falling back to '$selectedVideo'." -ForegroundColor Yellow
        } else {
            Write-Error "No video recording devices (webcams) found on the system."
        }
    }
}

# Audio Device
$selectedAudio = $null
if (-not [string]::IsNullOrEmpty($AudioDevice)) {
    $selectedAudio = $AudioDevice
} else {
    # Default target
    $targetAudio = "Microphone Array (Intel® Smart Sound Technology for Digital Microphones)"
    if ($devices.Audio.Contains($targetAudio)) {
        $selectedAudio = $targetAudio
    } elseif ($devices.Audio.Count -gt 0) {
        $selectedAudio = $devices.Audio[0]
        Write-Host "Microphone '$targetAudio' not found. Falling back to '$selectedAudio'." -ForegroundColor Yellow
    } else {
        Write-Error "No audio recording devices (microphones) found on the system."
    }
}

# 4. Construct FFmpeg arguments
$ffmpegArgs = [System.Collections.Generic.List[string]]::new()

# Global thread queue sizes to avoid buffering warnings/dropped packets
$ffmpegArgs.Add("-thread_queue_size")
$ffmpegArgs.Add("1024")

if ($Source -eq 'Webcam') {
    Write-Host "Configuring recording from Webcam: '$selectedVideo' with Audio: '$selectedAudio'" -ForegroundColor Green
    $ffmpegArgs.Add("-f")
    $ffmpegArgs.Add("dshow")
    $ffmpegArgs.Add("-i")
    $ffmpegArgs.Add("video=$selectedVideo:audio=$selectedAudio")
} else {
    Write-Host "Configuring recording from Screen (desktop) with Audio: '$selectedAudio'" -ForegroundColor Green
    # First input: GDI screen grabber
    $ffmpegArgs.Add("-f")
    $ffmpegArgs.Add("gdigrab")
    $ffmpegArgs.Add("-framerate")
    $ffmpegArgs.Add("30")
    $ffmpegArgs.Add("-i")
    $ffmpegArgs.Add("desktop")
    
    # Second input: DirectShow audio
    $ffmpegArgs.Add("-thread_queue_size")
    $ffmpegArgs.Add("1024")
    $ffmpegArgs.Add("-f")
    $ffmpegArgs.Add("dshow")
    $ffmpegArgs.Add("-i")
    $ffmpegArgs.Add("audio=$selectedAudio")
}

# Encoding settings for a standard MP4 file compatible with Windows Media Player
$ffmpegArgs.Add("-c:v")
$ffmpegArgs.Add("libx264")
$ffmpegArgs.Add("-pix_fmt")
$ffmpegArgs.Add("yuv420p")
$ffmpegArgs.Add("-preset")
$ffmpegArgs.Add("veryfast")
$ffmpegArgs.Add("-c:a")
$ffmpegArgs.Add("aac")
$ffmpegArgs.Add("-b:a")
$ffmpegArgs.Add("192k")

# Set duration if requested
if ($Duration -gt 0) {
    Write-Host "Recording will automatically stop after $Duration seconds." -ForegroundColor Cyan
    $ffmpegArgs.Add("-t")
    $ffmpegArgs.Add([string]$Duration)
}

# Overwrite if exists (our name collision logic makes sure it's unique anyway)
$ffmpegArgs.Add("-y")
$ffmpegArgs.Add($finalPathMp4)

Write-Host "==========================================================" -ForegroundColor Green
Write-Host "Recording is starting..." -ForegroundColor Green
Write-Host "Output Video: $finalPathMp4" -ForegroundColor Cyan
if ($Duration -eq 0) {
    Write-Host "Press 'q' in this window and then press [Enter] to STOP recording." -ForegroundColor Yellow
}
Write-Host "==========================================================" -ForegroundColor Green

# Start the recording
$procInfo = New-Object System.Diagnostics.ProcessStartInfo
$procInfo.FileName = "ffmpeg.exe"
# Join arguments safely with quotes where needed
$argList = @()
foreach ($arg in $ffmpegArgs) {
    if ($arg -match '\s' -or $arg -match '=') {
        $argList += "`"$arg`""
    } else {
        $argList += $arg
    }
}
$procInfo.Arguments = $argList -join " "
$procInfo.UseShellExecute = $false

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $procInfo

# Start FFmpeg and wait for exit
[void]$proc.Start()
$proc.WaitForExit()

# Check if recording file exists
if (Test-Path -Path $finalPathMp4) {
    Write-Host "Video recording saved successfully to: $finalPathMp4" -ForegroundColor Green
    
    # 5. Extract audio track to MP3
    Write-Host "Extracting audio track to MP3..." -ForegroundColor Cyan
    
    $mp3Args = @(
        "-i", "`"$finalPathMp4`"",
        "-vn",
        "-c:a", "libmp3lame",
        "-q:a", "2",
        "-y",
        "`"$finalPathMp3`""
    )
    
    $mp3ProcInfo = New-Object System.Diagnostics.ProcessStartInfo
    $mp3ProcInfo.FileName = "ffmpeg.exe"
    $mp3ProcInfo.Arguments = $mp3Args -join " "
    $mp3ProcInfo.UseShellExecute = $false
    $mp3ProcInfo.CreateNoWindow = $true
    
    $mp3Proc = New-Object System.Diagnostics.Process
    $mp3Proc.StartInfo = $mp3ProcInfo
    [void]$mp3Proc.Start()
    $mp3Proc.WaitForExit()
    
    if (Test-Path -Path $finalPathMp3) {
        Write-Host "Audio track saved successfully to: $finalPathMp3" -ForegroundColor Green
        Write-Host "Recording and extraction complete!" -ForegroundColor Green
    } else {
        Write-Warning "Failed to extract audio track to MP3."
    }
} else {
    Write-Error "Recording failed. Video file was not created."
}
