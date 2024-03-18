#!/bin/sh

#This is the more redable replacement for the init.c file

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
insmod ./virtio_scsi.ko

#tsm.ko is depdendency for sev-guest.ko
insmod ./tsm.ko
#kernel module for accessing the PSP from the guest
#used for getting the attestation report
insmod ./sev-guest.ko


#mount encrypted disk
insmod ./dm-crypt.ko

# load kernel module for ethernet support
insmod ./failover.ko
insmod ./net_failover.ko
insmod ./virtio_net.ko

# assign IP address
dhclient

echo "IP Data: $(ip addr)"

#start network server handle attestation + disk pw receival
./server || exit 1
#TODO:get pw via attestation server
PW=$(cat ./disk_key.txt)
shred -u ./disk_key.txt
echo "Disk key is ${PW}"
echo ${PW} | cryptsetup luksOpen /dev/sda3 sda3_crypt
 
#activate lvm2 (used by ubuntu as default when using crypto disk)
vgscan --mknodes
vgchange -ay
vgscan --mknodes

mount /dev/mapper/ubuntu--vg-ubuntu--lv /mnt

mount --move /proc /mnt/proc
mount --move /sys /mnt/sys
mount --move /dev /mnt/dev


exec switch_root /mnt/ /sbin/init
# exec /bin/bash
