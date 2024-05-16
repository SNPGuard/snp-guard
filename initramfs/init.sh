#!/bin/sh

set -e 

# Default PATH differs between shells, and is not automatically exported
# by klibc dash.  Make it consistent.
# Furthermore, this PATH ends up being used by the init, set it to the
# Standard PATH, without /snap/bin as documented in
# https://wiki.ubuntu.com/PATH
# This also matches /etc/environment, but without games path
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[ -d /dev ] || mkdir -m 0755 /dev
[ -d /root ] || mkdir -m 0700 /root
[ -d /sys ] || mkdir /sys
[ -d /proc ] || mkdir /proc
[ -d /tmp ] || mkdir /tmp
mkdir -p /var/lock
mount -t sysfs -o nodev,noexec,nosuid sysfs /sys
mount -t proc -o nodev,noexec,nosuid proc /proc

# Note that this only becomes /dev on the real filesystem if udev's scripts
# are used; which they will be, but it's worth pointing out
mount -t devtmpfs -o nosuid,mode=0755 udev /dev
mkdir /dev/pts
mount -t devpts -o noexec,nosuid,gid=5,mode=0620 devpts /dev/pts || true

MNT_DIR=/root

# Command-line parameters
ROOT=/dev/sda
BOOT=normal

# Parse command line options
# shellcheck disable=SC2013
for x in $(cat /proc/cmdline); do
	case $x in
	root=*)
		ROOT=${x#root=}
		;;
	boot=*)
		BOOT=${x#boot=}
		;;
	verity_disk=*)
		VERITY_DISK=${x#verity_disk=}
		;;
	verity_roothash=*)
		VERITY_ROOT_HASH=${x#verity_roothash=}
		;;
	esac
done

boot_normal() {
    echo "Booting normal filesystem.."
    mount $ROOT $MNT_DIR
}

boot_encrypted() {
    echo "Booting encrypted filesystem.."

    #kernel module for accessing the PSP from the guest
    #used for getting the attestation report
    modprobe sev-guest

    #kernel module for networking
    modprobe virtio_net

    # assign IP address
    dhclient

    #start network server handle attestation + disk pw receival
    /bin/server || exit 1
    PW=$(cat ./disk_key.txt)
    shred -u ./disk_key.txt

    ROOT_FS_CRYPTDEV="$(basename $ROOT)_crypt"
    echo "${PW}" | cryptsetup luksOpen "$ROOT" "$ROOT_FS_CRYPTDEV"

    #activate lvm2 (used by ubuntu as default when using crypto disk)
    # vgscan --mknodes
    # vgchange -ay
    # vgscan --mknodes
    # mount /dev/mapper/ubuntu--vg-ubuntu--lv $MNT_DIR

    mount /dev/mapper/"$ROOT_FS_CRYPTDEV" $MNT_DIR
}

boot_verity() {
    echo "Booting dm-verity filesystem.."

    # enable kernel module for accessing the PSP from the guest
    # used for getting the attestation report
    modprobe sev-guest

    # unlock verity device
    veritysetup open $ROOT root $VERITY_DISK $VERITY_ROOT_HASH

    # mount root disk as read-only
    mount -o ro,noload /dev/mapper/root $MNT_DIR

    # create RAM filesystems (protected by SEV-SNP)
    mount -t tmpfs -o size=8192M tmpfs $MNT_DIR/home
    mount -t tmpfs -o size=1024M tmpfs $MNT_DIR/etc
    mount -t tmpfs -o size=2048M tmpfs $MNT_DIR/var
    mount -t tmpfs -o size=1024M tmpfs $MNT_DIR/tmp

    # copy home, etc, var contents to RAM fs
    rsync -paxHAWXS $MNT_DIR/home_ro/ $MNT_DIR/home/
    rsync -paxHAWXS $MNT_DIR/etc_ro/ $MNT_DIR/etc/
    rsync -paxHAWXS $MNT_DIR/var_ro/ $MNT_DIR/var/

    # generate new SSH key for SSH server
    ssh-keygen -t ecdsa -f $MNT_DIR/etc/ssh/ssh_host_ecdsa_key -N "" >/dev/null 2>&1

    # generate attestation report with SSH fingerprint as user data
    FINGERPRINT=`ssh-keygen -lf $MNT_DIR/etc/ssh/ssh_host_ecdsa_key.pub | awk '{ print $2 }' | cut -d ":" -f 2`
    /bin/get_report --report-data $FINGERPRINT --out $MNT_DIR/etc/report.json
}

#default launch config for sev uses virto as device driver
#we need this module to detect the disk supplied with "-hda"
modprobe virtio_scsi

if [ $BOOT = "normal" ]; then
    boot_normal
elif [ $BOOT = "encrypted" ]; then
    boot_encrypted
elif [ $BOOT = "verity" ]; then
    boot_verity
else
    echo "Invalid boot option: $BOOT"
    exit 1
fi

mount --move /proc $MNT_DIR/proc
mount --move /sys $MNT_DIR/sys
exec switch_root $MNT_DIR/ /sbin/init
# exec /bin/bash
