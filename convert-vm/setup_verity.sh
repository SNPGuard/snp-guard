FS=fs-encrypted.qcow2
VERITY=verity
HASHFILE=roothash.txt
FS_DEVICE=/dev/nbd0
FS_DEVICE_ID=

set -e

echo "Initializing NBD module.."
sudo modprobe nbd max_part=8

echo "Mounting image.."
sudo qemu-nbd --connect=$FS_DEVICE $FS

echo "Computing hash tree.."
sudo veritysetup format $FS_DEVICE$FS_DEVICE_ID $VERITY | grep Root | cut -f2 > $HASHFILE

echo "Root hash: `cat $HASHFILE`"

echo "Cleaning up.."
sudo qemu-nbd --disconnect $FS_DEVICE
sleep 1
sudo rmmod nbd