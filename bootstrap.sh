#!/usr/bin/env bash
set -euo pipefail

loadkeys de-latin1-nodeadkeys
TARGET_USER="xyz"

echo "=== 1. Initialization & Security ==="
# Secure password prompt with confirmation to prevent typos
while true; do
    read -s -p "Enter password for ${TARGET_USER}: " USER_PASS
    echo ""
    read -s -p "Confirm password: " USER_PASS_CONFIRM
    echo ""
    if [ "${USER_PASS}" = "${USER_PASS_CONFIRM}" ] && [ -n "${USER_PASS}" ]; then
        break
    else
        echo "Passwords do not match or are empty. Please try again."
    fi
done

echo ""
echo "=== 2. Storage Drive Selection ==="
# Display all physical disks, excluding loop devices (7) and optical drives (11)
lsblk -d -p -o NAME,SIZE,MODEL,TRAN,SERIAL -e 7,11
mapfile -t AVAILABLE_DISKS < <(lsblk -d -p -n -o NAME -e 7,11)

if [ "${#AVAILABLE_DISKS[@]}" -eq 0 ]; then
    echo "Error: No target disks detected." >&2
    exit 1
fi

echo ""
echo "Select the target disk to partition and install Arch Linux:"
PS3="Enter selection number (1-${#AVAILABLE_DISKS[@]}): "
select SELECTED_DISK in "${AVAILABLE_DISKS[@]}"; do
    if [[ -n "${SELECTED_DISK:-}" && -b "${SELECTED_DISK}" ]]; then
        DISK="${SELECTED_DISK}"
        break
    else
        echo "Invalid selection. Enter a valid number from the list."
    fi
done

# Resolve canonical path in case a symlink or by-id path was passed
REAL_DISK="$(readlink -f "${DISK}")"

# Determine correct partition naming scheme (e.g., nvme0n1 -> nvme0n1p1 vs sda -> sda1)
if [[ "${REAL_DISK}" =~ [0-9]$ ]]; then
    EFI_PART="${REAL_DISK}p1"
    ROOT_PART="${REAL_DISK}p2"
else
    EFI_PART="${REAL_DISK}1"
    ROOT_PART="${REAL_DISK}2"
fi

echo ""
echo "======================================================================"
echo "                          CRITICAL WARNING                            "
echo "======================================================================"
echo "Target Disk: ${DISK}"
if [[ "${DISK}" != "${REAL_DISK}" ]]; then
    echo "Canonical:   ${REAL_DISK}"
fi
echo ""
echo "Existing layout on this drive:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "${REAL_DISK}" || echo "No existing partitions."
echo ""
echo "Planned layout:"
echo "  - EFI Partition:  ${EFI_PART}  (1 GiB, FAT32 -> /boot)"
echo "  - Root Partition: ${ROOT_PART} (Rest of disk, Btrfs -> /)"
echo "======================================================================"
echo ""

read -r -p "Type 'DESTROY' in all capital letters to wipe this disk: " CONFIRM_WIPE
if [[ "${CONFIRM_WIPE}" != "DESTROY" ]]; then
    echo "Installation aborted by user. No disk modifications were made."
    exit 1
fi

echo "=== 3. Unmounting existing partitions ==="
# Prevent sfdisk/mkfs failures by ensuring no partitions on the target drive are active
lsblk -n -o MOUNTPOINT "${REAL_DISK}" | awk 'NF' | sort -r | xargs -I {} umount -R {} || true
swapoff -a || true

echo "=== 4. Partitioning Disk ==="
sfdisk "${REAL_DISK}" <<EOF
label: gpt
,1G,U,
,,L,
EOF

# Ensure kernel registers the new partition table before formatting
udevadm settle
partprobe "${REAL_DISK}" || true
udevadm settle

echo "=== 5. Formatting Filesystems ==="
mkfs.fat -F 32 "${EFI_PART}"
mkfs.btrfs -f -L archlinux "${ROOT_PART}"

echo "=== 6. Creating Btrfs Subvolumes ==="
mount "${ROOT_PART}" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_cache
btrfs subvolume create /mnt/@var_tmp
umount /mnt

echo "=== 7. Mounting Subvolumes ==="
OPTS="noatime,compress=zstd:1,ssd,discard=async"
mount -o "${OPTS},subvol=@" "${ROOT_PART}" /mnt
mount --mkdir -o fmask=0077,dmask=0077 "${EFI_PART}" /mnt/boot
mount --mkdir -o "${OPTS},subvol=@home" "${ROOT_PART}" /mnt/home
mount --mkdir -o "${OPTS},subvol=@snapshots" "${ROOT_PART}" /mnt/.snapshots
mount --mkdir -o "${OPTS},subvol=@var_log" "${ROOT_PART}" /mnt/var/log
mount --mkdir -o "${OPTS},subvol=@var_cache" "${ROOT_PART}" /mnt/var/cache
mount --mkdir -o "${OPTS},subvol=@var_tmp" "${ROOT_PART}" /mnt/var/tmp
mount --mkdir "${EFI_PART}" /mnt/boot

echo "=== 8. Pacstrap Base & Networking Essentials ==="
# Note: curl added for dynamic CachyOS fetching inside chroot
pacstrap -K /mnt base base-devel linux-firmware amd-ucode btrfs-progs sudo git python ansible networkmanager nano curl

echo "=== 9. Generating fstab ==="
genfstab -U /mnt >> /mnt/etc/fstab

echo "=== 10. Resolving Latest CachyOS Packages ==="
# Fetch latest URLs dynamically to prevent 404s when versions change upstream
CACHY_URL="https://mirror.cachyos.org/repo/x86_64/cachyos"
KEYRING_PKG=$(curl -s "${CACHY_URL}/" | grep -o 'cachyos-keyring-[0-9]*-[0-9]*-any\.pkg\.tar\.zst' | head -n1)
MIRROR_PKG=$(curl -s "${CACHY_URL}/" | grep -o 'cachyos-mirrorlist-[0-9]*-[0-9]*-any\.pkg\.tar\.zst' | head -n1)
V4_MIRROR_PKG=$(curl -s "${CACHY_URL}/" | grep -o 'cachyos-v4-mirrorlist-[0-9]*-[0-9]*-any\.pkg\.tar\.zst' | head -n1)

echo "=== 11. Chroot Configuration ==="
arch-chroot /mnt /bin/bash <<EOF
# Enable strict error handling inside the chroot
set -euo pipefail

# Localization, Time & Keyboard
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc

sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(de_DE.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen

cat << 'LOCALE_EOF' > /etc/locale.conf
LANG=en_US.UTF-8
LC_TIME=de_DE.UTF-8
LC_NUMERIC=de_DE.UTF-8
LC_MONETARY=de_DE.UTF-8
LC_PAPER=de_DE.UTF-8
LC_MEASUREMENT=de_DE.UTF-8
LOCALE_EOF

echo "KEYMAP=de-latin1" > /etc/vconsole.conf
echo "xyzA26" > /etc/hostname

# Enable Networking for first boot
systemctl enable NetworkManager

# Initialize pacman keys
pacman-key --init
pacman-key --populate archlinux

# Download cachyos-keyring directly and extract its keys into pacman
curl -sL "${CACHY_URL}/${KEYRING_PKG}" -o /tmp/cachyos-keyring.pkg.tar.zst
tar -xf /tmp/cachyos-keyring.pkg.tar.zst -C /
pacman-key --populate cachyos

# Install packages
pacman -U --noconfirm --overwrite "*" \
  /tmp/cachyos-keyring.pkg.tar.zst \
  "${CACHY_URL}/${MIRROR_PKG}" \
  "${CACHY_URL}/${V4_MIRROR_PKG}"

# Enable v4 repositories
sed -i '/^\[core\]/i \
[cachyos-v4]\n\
Include = /etc/pacman.d/cachyos-v4-mirrorlist\n\
\n\
[cachyos-core-v4]\n\
Include = /etc/pacman.d/cachyos-v4-mirrorlist\n\
\n\
[cachyos-extra-v4]\n\
Include = /etc/pacman.d/cachyos-v4-mirrorlist\n\
\n\
[cachyos]\n\
Include = /etc/pacman.d/cachyos-mirrorlist\n' /etc/pacman.conf

# Allow x86_64_v4 architecture
sed -i 's/^Architecture = .*/Architecture = auto x86_64_v4/' /etc/pacman.conf

# Install Kernel & build initramfs
pacman -Sy --noconfirm linux-cachyos linux-cachyos-headers
mkinitcpio -P

# Systemd-boot Setup
bootctl install

# Create boot entry (uses safely escaped blkid evaluation)
cat <<ENTRY > /boot/loader/entries/arch.conf
title Arch Linux (CachyOS)
linux /vmlinuz-linux-cachyos
initrd /amd-ucode.img
initrd /initramfs-linux-cachyos.img
options root=PARTUUID=\$(blkid -s PARTUUID -o value ${ROOT_PART}) rootflags=subvol=@ rw
ENTRY

echo "default arch.conf" > /boot/loader/loader.conf

# User & Sudo setup
useradd -m -G wheel -s /bin/bash ${TARGET_USER}
echo "=== Setting password for ${TARGET_USER} ==="
echo "${TARGET_USER}:${USER_PASS}" | chpasswd

echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Pre-clone setup repo into user home (ensure directory ownership is correct)
su - ${TARGET_USER} -c "git clone https://github.com/yourusername/arch-setup.git ~/arch-setup"

EOF

echo "=== Installation complete. Rebooting into installed system ==="
umount -R /mnt
reboot
