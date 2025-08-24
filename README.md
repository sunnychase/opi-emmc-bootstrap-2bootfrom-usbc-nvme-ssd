# Orange Pi 5 Plus — Boot Ubuntu 24.04 from USB-C NVMe SSD (eMMC as Bootstrap)

This repository documents how to configure the **Orange Pi 5 Plus (RK3588)** to boot **Ubuntu 24.04.1 LTS** from a **USB-C NVMe SSD**, while using the **eMMC only as the bootstrap** (U-Boot + `/boot`).  

The **microSD card is not required after setup**.  

---

## 📋 Hardware / OS

- **Board**: Orange Pi 5 Plus (RK3588, 32GB RAM)  
- **OS**: Ubuntu 24.04.1 LTS (Joshua Riek build)  
- **Kernel**: `6.1.0-1025-rockchip`  
- **Rootfs**: `/dev/sda2` (USB-C NVMe SSD in Sabrent enclosure)  
- **eMMC**: `/dev/mmcblk0` — contains only U-Boot + `/boot`  
- **microSD**: only used during setup  

---

## 🔄 Boot Flow

```text
Power On
   │
   ├─> ROM loads SPL (idbloader.img) from eMMC @ 32 KiB
   │
   ├─> U-Boot FIT (u-boot.itb) from eMMC @ 8 MiB
   │
   ├─> U-Boot reads eMMC /boot/extlinux/extlinux.conf
   │       ├─ loads kernel + initrd from eMMC /boot
   │       └─ uses fdtdir DTBs from eMMC (/lib/firmware/<KVER>/device-tree)
   │
   └─> Kernel mounts rootfs on SSD (/dev/sda2 by UUID)
````

---

## ⚡ Quick Start

### 1. Clone this repo

```bash
git clone https://github.com/<your-username>/opi5p-hybrid-boot.git
cd opi5p-hybrid-boot
```

### 2. Run the one-shot setup script

This partitions eMMC, installs U-Boot, copies kernel/initrd/DTBs, and writes `extlinux.conf` pointing to the SSD rootfs.

```bash
chmod +x opi5p_hybrid_boot.sh
sudo ./opi5p_hybrid_boot.sh
```

### 3. Remove microSD & reboot

```bash
sudo poweroff
# remove microSD, leave eMMC + USB-C SSD
# power on
```

Verify:

```bash
mount | grep " / "      # should show /dev/sda2 on /
cat /proc/cmdline | tr ' ' '\n' | grep ^root=
# should show root=UUID=<SSD UUID>
```

---

## 🔄 Maintenance After Kernel Updates

After kernel upgrades, sync `/boot` from SSD → eMMC:

```bash
sudo ./sync_emmc_boot.sh
```

This copies:

* Kernel + initrd → eMMC `/boot`
* DTBs → eMMC firmware tree
* Regenerates `extlinux.conf`

---

## 📜 Scripts

### 🔹 `opi5p_hybrid_boot.sh`

```bash
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
```

---

### 🔹 `sync_emmc_boot.sh`

```bash
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
```

---

## 🐞 Troubleshooting

* **Black screen / no boot**

  * Verify SPL + ITB are written:

    ```bash
    sudo dd if=/dev/mmcblk0 bs=512 skip=64 count=1 | hexdump -C | head
    sudo dd if=/dev/mmcblk0 bs=512 skip=16384 count=1 | hexdump -C | head
    ```
  * Increase `rootdelay=10` in `extlinux.conf`.

* **Kernel mismatch**

  * Run `sudo ./sync_emmc_boot.sh` after kernel upgrades.

* **Missing DTBs**

  * Try using `/boot/dtbs-<KVER>/rockchip/` as `fdtdir`.

---

## ✅ Verification Checklist

```bash
mount | grep " / "          # shows /dev/sda2 on /
cat /proc/cmdline | grep root=UUID
blkid /dev/sda2             # UUID matches extlinux.conf
uname -r                    # matches kernel copied to eMMC
```

---

## 📜 License

All Rights Reserved, Sunny Chase 2025
