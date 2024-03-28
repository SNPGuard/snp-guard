FS=fs.qcow2
FS_DEVICE=/dev/nbd0
FS_DEVICE_ID=p2
FS_INT=fs-integrity.qcow2
FS_INT_DEVICE=/dev/nbd1
SRC=src/
DST=dst/
INTEGRITY_PARAMS="--integrity hmac-sha256 --integrity-key-file password.txt --integrity-key-size 4"

set -eux

mkdir -p $SRC
mkdir -p $DST

echo "Initializing NBD module.."
sudo modprobe nbd max_part=8

echo "Mounting source FS.."
sudo qemu-nbd --connect=$FS_DEVICE $FS
sudo mount $FS_DEVICE$FS_DEVICE_ID $SRC

echo "Preparing destination FS.."
qemu-img create -f qcow2 $FS_INT 10G
sudo qemu-nbd --connect=$FS_INT_DEVICE $FS_INT

echo "Formatting destination device.."
sudo integritysetup format $FS_INT_DEVICE $INTEGRITY_PARAMS
sudo integritysetup open $FS_INT_DEVICE root $INTEGRITY_PARAMS

echo "Creating ext4 partition and mounting.."
sudo mkfs.ext4 /dev/mapper/root
sudo mount /dev/mapper/root $DST

echo "Copying files.."
sudo rsync -axHAWXS --numeric-ids --info=progress2 $SRC $DST

echo "Cleaning up.."
sudo umount $SRC
sudo umount $DST
sudo integritysetup close root
sudo qemu-nbd --disconnect $FS_DEVICE
sudo qemu-nbd --disconnect $FS_INT_DEVICE
sleep 1
sudo rmmod nbd