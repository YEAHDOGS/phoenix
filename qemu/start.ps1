# 1. ---- SYSTEM ANALYSIS ----
Write-Host "🔍 [Castle] Analyzing host system hardware..." -ForegroundColor Cyan

# Dynamically calculate CPU Cores (Leave 2 cores for the host OS to prevent freezing)
$HostCores = (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors
$CpuCores = [Math]::Max(2, $HostCores - 2)

# Dynamically calculate Memory (Allocate 50% of available RAM, up to a sensible 8GB limit)
$TotalRamKB = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1KB
$TotalRamGB = [Math]::Round($TotalRamKB / 1MB)
$MemoryGB = [Math]::Min(8, [Math]::Max(4, [Math]::Round($TotalRamGB / 2)))
$Memory = "${MemoryGB}G"

# Dynamically determine CPU Vendor to pick a safe, high-performance profile
$CpuVendor = (Get-CimInstance Win32_Processor).Manufacturer
if ($CpuVendor -like "*Intel*") {
    $CpuProfile = "Haswell-v4"  # Highly compatible, avoids the APX/MPX WHPX crash
} elseif ($CpuVendor -like "*Advanced Micro Devices*") {
    $CpuProfile = "EPYC-v4"     # Safe, high-performance AMD profile for WHPX
} else {
    $CpuProfile = "max"         # Fallback default
}

# Print the analyzed configuration
Write-Host "📊 [Castle] Analysis Complete. Optimal Settings Applied:" -ForegroundColor Gray
Write-Host "   • CPU Cores: $CpuCores (Host Total: $HostCores)"
Write-Host "   • Memory:    $Memory (Host Total: ${TotalRamGB}GB)"
Write-Host "   • CPU Model: $CpuProfile ($CpuVendor)"
# ---

# 2. ---- ENVIRONMENT SETUP ----
$IsoImg = ".\data\cachyos-server-latest.iso"
$DiskImg = ".\data\castle_root.qcow2"

if (-not (Test-Path $DiskImg)) {
    Write-Host "📦 [Castle] Virtual storage disk not found. Provisioning 40GB raw block..." -ForegroundColor Cyan
    & "C:\Program Files\qemu\qemu-img.exe" create -f qcow2 $DiskImg 40G
}

# 3. ---- DYNAMIC ARGUMENT LAUNCH ----
Write-Host "🚀 [Castle] Injecting WHPX hypervisor and booting GUI node..." -ForegroundColor Green

$qemuArgs = @(
    "-accel", "whpx"
    "-cpu", $CpuProfile        # Dynamically selected safe profile
    "-smp", $CpuCores          # Dynamically calculated cores
    "-m", $Memory              # Dynamically calculated RAM
    "-drive", "file=$DiskImg,if=virtio,format=qcow2"
    "-drive", "file=$IsoImg,media=cdrom,readonly=on"
    "-boot", "order=d"
    "-vga", "virtio"
    "-display", "gtk"          # GTK is highly stable on Windows
    "-usb"
    "-device", "usb-tablet"
)

# Run QEMU
& "C:\Program Files\qemu\qemu-system-x86_64.exe" $qemuArgs