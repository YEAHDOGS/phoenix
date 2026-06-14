# QEMU

https://www.qemu.org/

# OS

- CachyOS
- EndeavourOS
- Arch-based

# File System Partitions

- btrfs - Offers built-in RAID, copy-on-write, and instantaneous snapshots. If a Nextcloud update breaks something, you can roll back the entire data drive in seconds.
- ext4 - The gold standard for Linux. It’s rock-solid, incredibly stable, has low overhead, and perfectly handles the strict permission locks Nextcloud requires.
- ZFS - Enterprise-Grade - Incredible for multi-drive arrays. It protects against silent data corruption (bit rot) and has aggressive caching, though it is quite RAM-heavy.

# Desktops

- KDE Plasma -
- Niri -
- Hyprland -
- Openbox
- Xfce4
- LXDE

# Things to work on

- Linux boot time - Currently takes... oof. way too long to get to the desktop. Need to cut
- We need robust auditing, logging, and metrics. Anything installed, we need to have a record of it immediately
- Test the btrfs rollback feature. Can this be integrated with castle?
- Install scripts for everything

# Packages

- Wireguard..?
- Tailscale..?
- ufw (Uncomplicated Firewall), or something comparable
- pi-hole DNS filtering
- Samba network folder hosting
