# This should yield a quick way to test answerfiles and scripts on fresh installs
# Install QEMU https://www.qemu.org/

$QEMU_PATH = "C:\Program Files\qemu"
$VM_DIR = "C:\your\vm\folder"
$ISO_PATH = "C:\path\to\Win11.iso"

# This folder will act as a USB injected into qemu at launch. It should hold an autounattend.xml file
$ANSWERFILE_RELATIVE = "../../win-install"
$ANSWERFILE_DIR = (Get-Item $ANSWERFILE_RELATIVE).FullName

# Ensure the VARS file exists in the VM dir (copy from source if missing)
if (!(Test-Path "$VM_DIR\OVMF_VARS.fd")) {
    Copy-Item "$QEMU_PATH\OVMF_VARS.fd" "$VM_DIR\OVMF_VARS.fd"
}

# Optional: Reset the virtual disk to a clean state if you have a base image
# Copy-Item "$VM_DIR\win11_clean.qcow2" "$VM_DIR\win11.qcow2" -Force

# Start QEMU with WHPX and NVMe for max speed
& "$QEMU_PATH\qemu-system-x86_64.exe" `
-m 8G -smp 4 -accel whpx,kernel-irqchip=on -cpu host `
-drive if=pflash,format=raw,readonly=on,file="$QEMU_PATH\OVMF_CODE.fd" `
-drive if=pflash,format=raw,file="$VM_DIR\OVMF_VARS.fd" `
-device virtio-vga-gl -display sdl,gl=on `
-drive file="$VM_DIR\win11.qcow2",if=nvme,discard=on `
-cdrom $ISO_PATH `
-drive file=fat:rw:$ANSWERFILE_DIR,format=raw `
-device usb-tablet -net nic,model=virtio -net user