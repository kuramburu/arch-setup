#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: bootstrap failed near line ${LINENO}. Nothing was unmounted; inspect /mnt before retrying." >&2' ERR

# Layout: the ESP is mounted at /efi and holds only the GRUB EFI binary.
# /boot is a plain directory inside the Btrfs @ subvolume, so kernels, initramfs
# images and microcode are part of every snapshot and roll back together with
# /usr/lib/modules. GRUB can read Btrfs; grub-btrfs adds snapshots to its menu.
# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------
TARGET_USER="xyz"
SYS_HOSTNAME="xyzA26"
TIMEZONE="Europe/Berlin"
SETUP_REPO_URL="https://github.com/yourusername/arch-setup.git"
CACHY_URL="https://mirror.cachyos.org/repo/x86_64/cachyos"
CACHY_KEY="F3B607488DB35A47"

die() { echo "Error: $*" >&2; exit 1; }

loadkeys de-latin1-nodeadkeys || true

echo "=== 0. Preflight checks ==="
[[ "${EUID}" -eq 0 ]] || die "Run this script as root from the Arch live ISO."
[[ -d /sys/firmware/efi/efivars ]] || die "Not booted in UEFI mode (the GRUB EFI install needs UEFI)."
curl -fsS --max-time 15 -o /dev/null "${CACHY_URL}/" || die "No network, or the CachyOS mirror is unreachable."

# Live ISO may be old: refresh its keyring so pacstrap signature checks don't fail
pacman -Sy --noconfirm archlinux-keyring || echo "Warning: could not refresh live keyring; continuing."
timedatectl set-ntp true || true

# x86-64-v4 (AVX-512) check. A v4 system on a CPU without it will not boot.
LD_HELP="$(/lib/ld-linux-x86-64.so.2 --help 2>&1 || true)"
if grep -q 'x86-64-v4 (supported' <<<"${LD_HELP}"; then
    USE_V4=1
    echo "CPU supports x86-64-v4: CachyOS v4 repositories will be enabled."
else
    USE_V4=0
    echo "WARNING: CPU does NOT support x86-64-v4. Using only the generic CachyOS repo."
fi

echo ""
echo "=== 1. Initialization & Security ==="
while true; do
    read -r -s -p "Enter password for ${TARGET_USER}: " USER_PASS
    echo ""
    read -r -s -p "Confirm password: " USER_PASS_CONFIRM
    echo ""
    if [[ "${USER_PASS}" = "${USER_PASS_CONFIRM}" && -n "${USER_PASS}" ]]; then
        break
    else
        echo "Passwords do not match or are empty. Please try again."
    fi
done
unset USER_PASS_CONFIRM

echo ""
echo "=== 2. Storage Drive Selection ==="
# Find the disk the live ISO booted from, so it cannot be selected
LIVE_DISK=""
if mountpoint -q /run/archiso/bootmnt 2>/dev/null; then
    LIVE_SRC="$(findmnt -n -o SOURCE /run/archiso/bootmnt || true)"
    if [[ -n "${LIVE_SRC}" ]]; then
        LIVE_DISK="$(lsblk -n -p -o PKNAME "${LIVE_SRC}" 2>/dev/null | head -n1 || true)"
        [[ -n "${LIVE_DISK}" ]] || LIVE_DISK="${LIVE_SRC}"
    fi
fi

# Physical disks only: exclude ramdisks (1), loop devices (7) and optical drives (11).
# DISK_MENU holds a human-readable line per disk (size, model, and the filesystem
# labels found on its partitions, e.g. "data"), index-aligned with AVAILABLE_DISKS.
AVAILABLE_DISKS=()
DISK_MENU=()
while IFS= read -r d; do
    [[ -n "${d}" && "${d}" != "${LIVE_DISK}" ]] || continue
    d_size="$(lsblk -dn -o SIZE "${d}" 2>/dev/null | xargs || true)"
    d_model="$(lsblk -dn -o MODEL "${d}" 2>/dev/null | xargs || true)"
    d_labels="$(lsblk -n -o LABEL "${d}" 2>/dev/null | awk 'NF' | paste -sd, - || true)"
    AVAILABLE_DISKS+=("${d}")
    DISK_MENU+=("${d}  ${d_size:-?}  ${d_model:-unknown model}  [labels: ${d_labels:-none}]")
done < <(lsblk -d -p -n -o NAME -e 1,7,11)

[[ "${#AVAILABLE_DISKS[@]}" -gt 0 ]] || die "No target disks detected."
[[ -z "${LIVE_DISK}" ]] || echo "(Excluding live installation medium: ${LIVE_DISK})"
# Full tree (no -d) so partition labels such as "data" are visible
lsblk -p -o NAME,SIZE,MODEL,TRAN,SERIAL,FSTYPE,LABEL "${AVAILABLE_DISKS[@]}"

echo ""
echo "Select the target disk to partition and install Arch Linux:"
PS3="Enter selection number (1-${#AVAILABLE_DISKS[@]}): "
select CHOICE in "${DISK_MENU[@]}"; do
    if [[ -n "${CHOICE:-}" && "${REPLY}" =~ ^[0-9]+$ ]]; then
        SELECTED_DISK="${AVAILABLE_DISKS[$((REPLY - 1))]}"
        if [[ -b "${SELECTED_DISK}" ]]; then
            DISK="${SELECTED_DISK}"
            break
        fi
    fi
    echo "Invalid selection. Enter a valid number from the list."
done

# Resolve canonical path in case a symlink or by-id path was passed
REAL_DISK="$(readlink -f "${DISK}")"

# Partition naming scheme (nvme0n1 -> nvme0n1p1, sda -> sda1)
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
echo "  - EFI Partition:  ${EFI_PART}  (2 GiB, FAT32 -> /efi, GRUB binary only)"
echo "  - Root Partition: ${ROOT_PART} (Rest of disk, Btrfs -> /, includes /boot)"
echo "======================================================================"
echo ""

read -r -p "Type 'DESTROY' in all capital letters to wipe this disk: " CONFIRM_WIPE
if [[ "${CONFIRM_WIPE}" != "DESTROY" ]]; then
    echo "Installation aborted by user. No disk modifications were made."
    exit 1
fi

echo "=== 3. Unmounting existing partitions ==="
# Prevent sfdisk/mkfs failures by ensuring nothing on the target drive is active
lsblk -n -o MOUNTPOINT "${REAL_DISK}" | awk 'NF' | sort -r | xargs -I {} umount -R {} || true
swapoff -a || true

echo "=== 4. Partitioning Disk ==="
wipefs -af "${REAL_DISK}"
sfdisk "${REAL_DISK}" <<EOF
label: gpt
,2G,U,
,,L,
EOF

# Ensure kernel registers the new partition table before formatting
udevadm settle
partprobe "${REAL_DISK}" || true
udevadm settle
for _ in {1..20}; do
    [[ -b "${EFI_PART}" && -b "${ROOT_PART}" ]] && break
    sleep 0.5
done
[[ -b "${EFI_PART}" && -b "${ROOT_PART}" ]] || die "Partition device nodes did not appear."

echo "=== 5. Formatting Filesystems ==="
mkfs.fat -F 32 -n ESP "${EFI_PART}"
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
# /boot is deliberately NOT a separate mount: it lives in @ so snapshots include the kernels
mount --mkdir -o fmask=0077,dmask=0077 "${EFI_PART}" /mnt/efi
mount --mkdir -o "${OPTS},subvol=@home" "${ROOT_PART}" /mnt/home
mount --mkdir -o "${OPTS},subvol=@snapshots" "${ROOT_PART}" /mnt/.snapshots
mount --mkdir -o "${OPTS},subvol=@var_log" "${ROOT_PART}" /mnt/var/log
mount --mkdir -o "${OPTS},subvol=@var_cache" "${ROOT_PART}" /mnt/var/cache
mount --mkdir -o "${OPTS},subvol=@var_tmp" "${ROOT_PART}" /mnt/var/tmp

echo "=== 8. Pacstrap Base & Networking Essentials ==="
# mkinitcpio is explicit so the 'initramfs' dependency can't resolve to another provider.
# linux-lts is the fallback kernel in case a CachyOS kernel/repo update breaks booting.
# grub + grub-btrfs (+ inotify-tools for grub-btrfsd) provide bootable snapshots.
pacstrap -K /mnt base base-devel linux-lts linux-firmware amd-ucode mkinitcpio \
    btrfs-progs grub efibootmgr grub-btrfs inotify-tools \
    sudo git python ansible networkmanager nano curl

echo "=== 9. Generating fstab ==="
genfstab -U /mnt >> /mnt/etc/fstab
# Pinned subvolids break snapper rollbacks / snapshot swaps; subvol= is enough
sed -i -E 's/,subvolid=[0-9]+//' /mnt/etc/fstab

echo "=== 10. Resolving Latest CachyOS Packages ==="
CACHY_LISTING="$(curl -fsS "${CACHY_URL}/")"
pick_latest() { grep -oE "$1" <<<"${CACHY_LISTING}" | sort -uV | tail -n1 || true; }

KEYRING_PKG="$(pick_latest 'cachyos-keyring-[0-9]+-[0-9]+-any\.pkg\.tar\.zst')"
MIRROR_PKG="$(pick_latest 'cachyos-mirrorlist-[0-9]+-[0-9]+-any\.pkg\.tar\.zst')"
V4_MIRROR_PKG=""
[[ -n "${KEYRING_PKG}" ]] || die "Could not resolve the cachyos-keyring package name."
[[ -n "${MIRROR_PKG}" ]] || die "Could not resolve the cachyos-mirrorlist package name."
if [[ "${USE_V4}" -eq 1 ]]; then
    V4_MIRROR_PKG="$(pick_latest 'cachyos-v4-mirrorlist-[0-9]+-[0-9]+-any\.pkg\.tar\.zst')"
    [[ -n "${V4_MIRROR_PKG}" ]] || die "Could not resolve the cachyos-v4-mirrorlist package name."
fi
echo "Keyring:  ${KEYRING_PKG}"
echo "Mirrors:  ${MIRROR_PKG} ${V4_MIRROR_PKG}"

echo "=== 11. Chroot Configuration ==="
# The chroot script is written with a QUOTED heredoc, so nothing is expanded
# on the host. Needed values are passed as environment variables below.
# The password is deliberately NOT passed here (see step 12).
cat > /mnt/root/chroot-setup.sh <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail

# Localization, time & keyboard
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc || echo "Warning: hwclock --systohc failed (no RTC?); continuing."

sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(de_DE.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen

cat > /etc/locale.conf <<'LOCALE_EOF'
LANG=en_US.UTF-8
LC_TIME=de_DE.UTF-8
LC_NUMERIC=de_DE.UTF-8
LC_MONETARY=de_DE.UTF-8
LC_PAPER=de_DE.UTF-8
LC_MEASUREMENT=de_DE.UTF-8
LOCALE_EOF

echo "KEYMAP=de-latin1" > /etc/vconsole.conf
echo "${SYS_HOSTNAME}" > /etc/hostname

# Services for first boot: network, NTP, TRIM, snapshot entries in the GRUB menu
systemctl enable NetworkManager.service
systemctl enable systemd-timesyncd.service
systemctl enable fstrim.timer
systemctl enable grub-btrfsd.service

# Make read-only snapshots bootable from GRUB: the overlayfs hook must be LAST in HOOKS.
# (Incompatible with the 'systemd' hook; the default 'udev' hooks used here are fine.)
if ! grep -qE '^HOOKS=.*grub-btrfs-overlayfs' /etc/mkinitcpio.conf; then
    sed -i -E '/^HOOKS=\(/ s/\)[[:space:]]*$/ grub-btrfs-overlayfs)/' /etc/mkinitcpio.conf
fi
grep -qE '^HOOKS=.*grub-btrfs-overlayfs' /etc/mkinitcpio.conf \
    || { echo "ERROR: could not add grub-btrfs-overlayfs to mkinitcpio HOOKS" >&2; exit 1; }

# Initialize pacman keys
pacman-key --init
pacman-key --populate archlinux

# CachyOS signing key: import and locally sign (official procedure),
# so the keyring/mirrorlist packages are signature-verified on install.
pacman-key --recv-keys "${CACHY_KEY}" --keyserver keyserver.ubuntu.com \
  || pacman-key --recv-keys "${CACHY_KEY}" --keyserver hkps://keys.openpgp.org
pacman-key --lsign-key "${CACHY_KEY}"

PKGS=("${CACHY_URL}/${KEYRING_PKG}" "${CACHY_URL}/${MIRROR_PKG}")
if [[ "${USE_V4}" -eq 1 ]]; then
    PKGS+=("${CACHY_URL}/${V4_MIRROR_PKG}")
fi
pacman -U --noconfirm "${PKGS[@]}"
pacman-key --populate cachyos

# Build the CachyOS repo block (must sit above [core])
if [[ "${USE_V4}" -eq 1 ]]; then
    cat > /tmp/cachyos-repos.conf <<'REPOS_EOF'
[cachyos-v4]
Include = /etc/pacman.d/cachyos-v4-mirrorlist

[cachyos-core-v4]
Include = /etc/pacman.d/cachyos-v4-mirrorlist

[cachyos-extra-v4]
Include = /etc/pacman.d/cachyos-v4-mirrorlist

[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist

REPOS_EOF
    # Explicitly un-comment and add both v4 and v3 architectures
    sed -i -E 's/^#?Architecture = .*/Architecture = auto x86_64_v4 x86_64_v3/' /etc/pacman.conf
else
    cat > /tmp/cachyos-repos.conf <<'REPOS_EOF'
[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist

REPOS_EOF
    # Ensure v3 is allowed for standard CachyOS packages
    sed -i -E 's/^#?Architecture = .*/Architecture = auto x86_64_v3/' /etc/pacman.conf
fi

# Insert the repo block right before the first [core] section
awk -v repo_file=/tmp/cachyos-repos.conf '
    /^\[core\]/ && !done {
        while ((getline line < repo_file) > 0) print line
        done = 1
    }
    { print }
' /etc/pacman.conf > /etc/pacman.conf.new
mv /etc/pacman.conf.new /etc/pacman.conf
rm -f /tmp/cachyos-repos.conf

# Full upgrade (never a bare -Sy) + CachyOS kernel
pacman -Syu --noconfirm linux-cachyos linux-cachyos-headers
mkinitcpio -P

# ---------------------------------------------------------------------
# GRUB bootloader
# grub-mkconfig detects the Btrfs root and adds rootflags=subvol=@ itself, so no
# kernel command line is hardcoded here. grub-btrfs adds the snapshots submenu.
# ---------------------------------------------------------------------
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
# Without this, GRUB sorts linux-lts above linux-cachyos and boots the LTS kernel by default
sed -i '/^GRUB_TOP_LEVEL=/d' /etc/default/grub
echo 'GRUB_TOP_LEVEL="/boot/vmlinuz-linux-cachyos"' >> /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB --recheck
# Second copy at the removable/fallback path for firmware that forgets NVRAM entries
grub-install --target=x86_64-efi --efi-directory=/efi --removable --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# Safety net: without rootflags=subvol=@ the system would mount the Btrfs top level and fail to boot
grep -q 'rootflags=subvol=@' /boot/grub/grub.cfg \
    || { echo "ERROR: grub.cfg has no rootflags=subvol=@; refusing to continue." >&2; exit 1; }
grep -q 'vmlinuz-linux-cachyos' /boot/grub/grub.cfg \
    || { echo "ERROR: grub.cfg has no CachyOS kernel entry." >&2; exit 1; }

# User & sudo (password is set from outside the chroot)
useradd -m -G wheel -s /bin/bash "${TARGET_USER}"
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel
visudo -cf /etc/sudoers.d/wheel
CHROOT_EOF
chmod 700 /mnt/root/chroot-setup.sh

arch-chroot /mnt /usr/bin/env \
    TIMEZONE="${TIMEZONE}" \
    SYS_HOSTNAME="${SYS_HOSTNAME}" \
    TARGET_USER="${TARGET_USER}" \
    USE_V4="${USE_V4}" \
    CACHY_URL="${CACHY_URL}" \
    CACHY_KEY="${CACHY_KEY}" \
    KEYRING_PKG="${KEYRING_PKG}" \
    MIRROR_PKG="${MIRROR_PKG}" \
    V4_MIRROR_PKG="${V4_MIRROR_PKG}" \
    /bin/bash /root/chroot-setup.sh
rm -f /mnt/root/chroot-setup.sh

echo "=== 12. Setting password for ${TARGET_USER} ==="
# Passed via stdin as data, so $, backticks, quotes and backslashes are safe
printf '%s:%s\n' "${TARGET_USER}" "${USER_PASS}" | arch-chroot /mnt chpasswd
unset USER_PASS

echo "=== 13. Pre-cloning setup repo ==="
if ! arch-chroot /mnt su - "${TARGET_USER}" -c "git clone '${SETUP_REPO_URL}' ~/.arch-setup"; then
    echo "Warning: could not clone ${SETUP_REPO_URL} (private repo or placeholder URL?)."
    echo "         Clone it manually after first boot."
fi

echo ""
echo "=== Installation complete ==="
echo "After reboot, log in as ${TARGET_USER} and run your playbook with:"
echo "  ansible-playbook -K <your-playbook>.yml"
echo "Snapper itself is configured by that playbook; once it is, grub-btrfsd adds snapshots to the GRUB menu."
echo ""
umount -R /mnt
echo "Rebooting in 5 seconds (Ctrl+C to cancel)..."
sleep 5
reboot
