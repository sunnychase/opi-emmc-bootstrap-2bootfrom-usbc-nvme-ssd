#!/usr/bin/env bash
set -euo pipefail

# Sync kernel/initrd/DTBs from SSD (live system) to eMMC /boot
# and refresh extlinux.conf with the correct SSD root UUID

EMMC_PART="/dev/mmcblk0p1"
EMMC_MNT="/mnt/emmcb"
SSD_UUID="43d74ec7-0ded-4794-813c-57774cb229c6"

mkdir -p "$EMMC_MNT"
if ! mountpoint -q "$EMMC_MNT"; then
  sudo mount "$EMMC_PART" "$EMMC_MNT"
fi

KVER="$(uname -r)"
echo "[*] Using kernel $KVER"

echo "[*] Copying kernel/initrd to eMMC..."
sudo rsync -aHAX /boot/vmlinuz-"$KVER"    "$EMMC_MNT/boot/"
sudo rsync -aHAX /boot/initrd.img-"$KVER" "$EMMC_MNT/boot/"

echo "[*] Copying DTBs..."
if [[ -d "/lib/firmware/$KVER/device-tree" ]]; then
  sudo mkdir -p "$EMMC_MNT/lib/firmware/$KVER/device-tree"
  sudo rsync -aHAX /lib/firmware/"$KVER"/device-tree/ "$EMMC_MNT/lib/firmware/$KVER"/device-tree/
fi

echo "[*] Writing extlinux.conf..."
sudo mkdir -p "$EMMC_MNT/extlinux"
sudo tee "$EMMC_MNT/extlinux/extlinux.conf" >/dev/null <<CONF
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
        append root=UUID=$SSD_UUID rw rootwait rootdelay=8 console=ttyS2,1500000 console=tty1 cgroup_enable=memory swapaccount=1 loglevel=7
CONF

sync
umount "$EMMC_MNT" || true
echo "[✓] eMMC /boot synced for kernel $KVER"
