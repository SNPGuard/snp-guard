FS=fs.qcow2
FS_DEVICE=/dev/nbd0
FS_DEVICE_ID=p2
FS_ENC=fs-encrypted.qcow2
FS_ENC_DEVICE=/dev/nbd1
SRC=src/
DST=dst/
LUKS_PARAMS="--cipher aes-xts-random --integrity hmac-sha256"

set -eux

mkdir -p $SRC
mkdir -p $DST

echo "Initializing NBD module.."
sudo modprobe nbd max_part=8

echo "Mounting source FS.."
sudo qemu-nbd --connect=$FS_DEVICE $FS
sudo mount $FS_DEVICE$FS_DEVICE_ID $SRC

echo "Preparing destination FS.."
qemu-img create -f qcow2 $FS_ENC 10G
sudo qemu-nbd --connect=$FS_ENC_DEVICE $FS_ENC

echo "Formatting LUKS.."
sudo cryptsetup luksFormat --type luks2 $FS_ENC_DEVICE $LUKS_PARAMS
sudo cryptsetup luksOpen $FS_ENC_DEVICE root

# if integrity is used, the device is already wiped
#echo "Zero-ing the device.."
#sudo dd if=/dev/zero of=/dev/mapper/root || true

echo "Creating ext4 partition and mounting.."
sudo mkfs.ext4 /dev/mapper/root
sudo mount /dev/mapper/root $DST

echo "Copying files.."
sudo rsync -axHAWXS --numeric-ids --info=progress2 $SRC $DST

echo "Cleaning up.."
sudo umount $SRC
sudo umount $DST
sudo cryptsetup luksClose root
sudo qemu-nbd --disconnect $FS_DEVICE
sudo qemu-nbd --disconnect $FS_ENC_DEVICE
sleep 1
sudo rmmod nbd