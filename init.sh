#!/bin/sh

set -e 

#This is the init binary/script for the first stage

#Static config variable for the root filesytem
ROOT_FS_DEV=/dev/sda

mkdir -p /dev
mount -t devtmpfs /dev /dev

mkdir -p /proc
mount -t proc /proc /proc

mkdir -p /sys
mount -t sysfs /sys sys

mkdir -p /dev/pts
mount -t devpts /dev/pts /dev/pts


#default launch config for sev uses virto as device driver
#we need this module to detect the disk supplied with "-hda"
modprobe virtio_scsi

#kernel module for accessing the PSP from the guest
#used for getting the attestation report
modprobe sev-guest


#kernel module for networking
modprobe virtio_net

# assign IP address
dhclient

echo "IP Data: $(ip addr)"

#start network server handle attestation + disk pw receival
./server || exit 1
PW=$(cat ./disk_key.txt)
shred -u ./disk_key.txt
echo "Disk key is ${PW}"
ROOT_FS_CRYPTDEV="$(basename $ROOT_FS_DEV)_crypt"
echo "ROOT_FS_CRYPTDEV = $ROOT_FS_CRYPTDEV"
echo "${PW}" | cryptsetup luksOpen "$ROOT_FS_DEV" "$ROOT_FS_CRYPTDEV"
 
#activate lvm2 (used by ubuntu as default when using crypto disk)
# vgscan --mknodes
# vgchange -ay
# vgscan --mknodes
# mount /dev/mapper/ubuntu--vg-ubuntu--lv /mnt

mount /dev/mapper/"$ROOT_FS_CRYPTDEV" /mnt

mount --move /proc /mnt/proc
mount --move /sys /mnt/sys
mount --move /dev /mnt/dev
exec switch_root /mnt/ /sbin/init
# exec /bin/bash
