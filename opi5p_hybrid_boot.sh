#!/usr/bin/env bash
set -euo pipefail

# One-shot hybrid setup for Orange Pi 5 Plus (RK3588):
# - Partitions eMMC with /boot starting at 32MiB
# - Copies SSD /boot into eMMC /boot
# - Writes U-Boot SPL+ITB to eMMC at Rockchip offsets
# - Generates extlinux.conf pointing root to the SSD root UUID

EMMC_DEV="/dev/mmcblk0"
EMMC_BOOT_PART="${EMMC_DEV}p1"
EMMC_BOOT_MNT="/mnt/emmcb"

SSD_BOOT_DEV="/dev/sda1"
SSD_ROOT_DEV="/dev/sda2"
SSD_BOOT_MNT="/media/lion/boot"

UBOOT_IDB="/usr/lib/u-boot/idbloader.img"
UBOOT_ITB="/usr/lib/u-boot/u-boot.itb"

BOOT_PART_SIZE_MIB="1056"  # ~1 GiB
ROOTDELAY="8"

require_root() { [[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }; }

require_root
echo "[1/9] Checking devices..."
for d in "$EMMC_DEV" "$SSD_BOOT_DEV" "$SSD_ROOT_DEV"; do
  [[ -b "$d" ]] || { echo "Missing block device: $d"; exit 1; }
done
echo "  OK."

echo "[2/9] Installing tools..."
apt-get update -y
apt-get install -y u-boot-tools u-boot-menu parted rsync

echo "[3/9] Verifying U-Boot images..."
[[ -f "$UBOOT_IDB" && -f "$UBOOT_ITB" ]] || { echo "Missing $UBOOT_IDB or $UBOOT_ITB"; exit 1; }
echo "  OK."

echo "[4/9] Partition eMMC with /boot starting at 32MiB..."
umount "$EMMC_BOOT_PART" 2>/dev/null || true
parted -s "$EMMC_DEV" mklabel gpt
parted -s "$EMMC_DEV" mkpart boot ext4 32MiB ${BOOT_PART_SIZE_MIB}MiB
udevadm settle || true; sleep 1

[[ -b "$EMMC_BOOT_PART" ]] || { echo "Partition not found: $EMMC_BOOT_PART"; exit 1; }

echo "Formatting $EMMC_BOOT_PART..."
mkfs.ext4 -F -L BOOT_EMMC "$EMMC_BOOT_PART" > /dev/null

echo "[5/9] Mounting eMMC /boot and SSD /boot..."
mkdir -p "$EMMC_BOOT_MNT"
mount "$EMMC_BOOT_PART" "$EMMC_BOOT_MNT"
mountpoint -q "$SSD_BOOT_MNT" || mount "$SSD_BOOT_DEV" "$SSD_BOOT_MNT"

echo "[6/9] Copy SSD /boot -> eMMC /boot..."
rsync -aHAX --delete "$SSD_BOOT_MNT"/ "$EMMC_BOOT_MNT"/
sync

echo "[7/9] Write U-Boot SPL+ITB to eMMC raw device..."
dd if="$UBOOT_IDB" of="$EMMC_DEV" bs=512 seek=64 conv=sync,fsync status=none
dd if="$UBOOT_ITB" of="$EMMC_DEV" bs=512 seek=16384 conv=sync,fsync status=none
sync

echo "[8/9] Generate extlinux.conf pointing root to SSD..."
SSD_ROOT_UUID=$(blkid -s UUID -o value "$SSD_ROOT_DEV")
KVER=$(ls "$EMMC_BOOT_MNT"/boot/vmlinuz-* 2>/dev/null | sed 's#.*vmlinuz-##' | sort -V | tail -1)

mkdir -p "$EMMC_BOOT_MNT/extlinux"
cat > "$EMMC_BOOT_MNT/extlinux/extlinux.conf" <<CONF
## /boot/extlinux/extlinux.conf
default l0
menu title U-Boot menu
prompt 1
timeout 20

label l0
        menu label Ubuntu (primary)
        linux /boot/vmlinuz-$KVER
        initrd /boot/initrd.img-$KVER
        fdtdir /lib/firmware/$KVER/device-tree/
        append root=UUID=$SSD_ROOT_UUID rw rootwait rootdelay=$ROOTDELAY console=ttyS2,1500000 console=tty1 cgroup_enable=memory swapaccount=1 loglevel=7

label l0r
        menu label Ubuntu (rescue target)
        linux /boot/vmlinuz-$KVER
        initrd /boot/initrd.img-$KVER
        fdtdir /lib/firmware/$KVER/device-tree/
        append root=UUID=$SSD_ROOT_UUID rw rootwait rootdelay=$ROOTDELAY console=ttyS2,1500000 console=tty1 cgroup_enable=memory swapaccount=1 loglevel=7
CONF

echo "[9/9] Finalize..."
sync
umount "$EMMC_BOOT_MNT" || true

echo "✅ Done. Poweroff, REMOVE microSD, boot with eMMC + SSD only."
