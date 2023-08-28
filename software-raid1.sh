#!/usr/bin/env bash

#
# Software raid with mdadm() only lets the data sync, but it does not take the EPS partition into account.
# This script enables full redundancy for the EPS partition by an initial clone and continued syncing in case of changes.
# This allows the server to boot with either disk left in a raid 1 configuration
#

NUM_BOOT_DISKS=$(sudo fdisk -l | grep 'EFI System' | wc -l)

if [ "$NUM_BOOT_DISKS" -ne 2 ]; then
    echo "Two ESP partitions could not be found. Aborting."
    exit 1
fi

PRIMARY_BOOT_DISK=$(mount | grep /boot/efi | awk '{print $1}' | xargs basename)
SECONDARY_BOOT_DISK=$(sudo fdisk -l | grep 'EFI System' | awk '{print $1}' | grep -v "$PRIMARY_BOOT_DISK" | xargs basename)

echo "Cloning the in-use boot partition $PRIMARY_BOOT_DISK to the secondary disk $SECONDARY_BOOT_DISK"
echo "This will ensure we have a working ESP on both disks, the EFI partition will have the same UUID after this."
echo "Cloning..."
sudo dd if="/dev/${PRIMARY_BOOT_DISK}" of="/dev/${SECONDARY_BOOT_DISK}"

echo "Configure grub to update both disks on any future changes"
EFI_DISKS_FOR_GRUB=$(ls -lah /dev/disk/by-id/ | grep -e "../${PRIMARY_BOOT_DISK}$" -e "../${SECONDARY_BOOT_DISK}$" | grep -o -e 'nvme-eui.*' | awk '{print " /dev/disk/by-id/"$1}' | paste -sd ',' | xargs)
echo "Disks to be set for updates: $EFI_DISKS_FOR_GRUB"
echo "grub-efi-amd64 grub-efi/install_devices multiselect $EFI_DISKS_FOR_GRUB" | sudo debconf-set-selections -v
echo ""
sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure grub-efi-amd64

echo ""
echo "Configuration completed."
echo ""


raid_prompt() { awk '/^md/ {printf "%s: ", $1}; /blocks/ {print $NF}'  /proc/mdstat | awk '/\[U+\]/ {print "\033[32m" $0 "\033[0m"}; /\[.*_.*\]/ {print "\033[31m" $0 "\033[0m"}'; }
echo "Raid(s):"
raid_prompt

RAID_STATUS=$(sudo mdadm --detail --test --scan >/dev/null && echo OK || echo DEGRADED)
echo "Raid status: $RAID_STATUS"
