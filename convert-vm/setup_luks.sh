#!/bin/bash
#This script clones the given partition on a qcow2 disk to a new encrypted partition
#on a new  qcow2 disk

#Path to qcow2 with input filesystem
FS=""
#Mounpoint for input filesystem
FS_DEVICE=/dev/nbd0
#FS_DEVICE specific name of the partition that we can to clone
FS_DEVICE_ID="p1"
#Path to qcow2 for encrypted output filesytem
FS_ENC=""
#Mountpoint for encrypted output filesystem
FS_ENC_DEVICE=/dev/nbd1
#Mount poitn for FS, populated with mktemp
SRC=""
#Mount point for FS_ENC, populated with mktemp
DST=""
#Paramters for the encryption
LUKS_PARAMS="--cipher aes-xts-random --integrity hmac-sha256"

set -e
clean_up() {
  echo "Cleaning up"
  #use "|| true" after each fallible common to preventing exiting from the cleanup
  #handler due to an error
  if [ -e "$SRC" ]; then
    echo "Unmounting $SRC"
    sudo umount -q "$SRC" 2>/dev/null || true
  fi 

  if [ -e "$DST" ]; then
    echo "Unmounting $DST"
    sudo umount -q "$DST" 2>/dev/null || true
  fi

  if [ -e "/dev/mapper/snpguard_root" ]; then
    echo "Closing luks device"
    sudo cryptsetup luksClose snpguard_root 2>/dev/null || true
  fi

  NEED_SLEEP=0
  if [ -e "$FS_DEVICE" ]; then 
    sudo qemu-nbd --disconnect $FS_DEVICE 2>/dev/null || true
    NEED_SLEEP=1
  fi

  if [ -e "$FS_ENC_DEVICE" ]; then
    sudo qemu-nbd --disconnect $FS_ENC_DEVICE 2>/dev/null || true
    NEED_SLEEP=1
  fi
  #qemu-nbd needs some time...
  if [ $NEED_SLEEP -eq 1 ]; then
    sleep 2
  fi
  sudo modprobe -r nbd || true
}
trap clean_up EXIT


usage() {
  echo "$0 [options]"
  echo ""
  echo "-in PATH.qcow2            [Mandatory] Path to unencrypted input qcow2 disk image. It is assumed that there are only a root partition and (optionally) and efi partition."
  echo "-in-rootpart INTEGER [Optional] 1 indexed partition number of the root partion on <in>. Defaults to 1."
  echo "-out PATH.qcow2 [Optional] Path where the encrypted qcow2 disk is created. Defaults to the directory of the input file with -encrypted suffix"
  echo ""
}

if [ $# -eq 0 ]; then
  usage
  exit
fi

while [ -n "$1" ]; do
  case "$1" in
    -in) FS="$2"
      shift
      ;;
    -in-rootpart) FS_DEVICE_ID="p${2}"
      shift
      ;;
    -out) FS_ENC="$2"
      shift
      ;;
    *)
      usage
      exit
      ;;
  esac
  shift
done

if [ -z "$FS_ENC" ]; then
  FILE_NO_EXTENSION="${FS%.*}"
  FS_ENC="${FILE_NO_EXTENSION}-encrypted.qcow2"
fi


#mountpoint for input filesytem
SRC=$(mktemp -d)
#mountpoint for output filesytem
DST=$(mktemp -d)

echo "Initializing NBD module.."
sudo modprobe nbd max_part=8

#After attaching with qemu-nbd, we can no longer execute this
SIZE=$(sudo qemu-img info "$FS" | awk '/virtual size:/ { print $3 "G" }')

echo "Mounting source FS.."
sudo qemu-nbd --connect=$FS_DEVICE $FS
#qemu-nbd returns before it finishes mounting
#Thus we need to wait. Here, we could check for the actual partition file
#with o timeout. However, this does not work for new newly created qcow
#below. Thus we also use sleep here
sleep 2

#check that partition specified by user exists
echo "Checking if ${FS_DEVICE}${FS_DEVICE_ID} exists"
if [ ! -e "${FS_DEVICE}${FS_DEVICE_ID}" ]; then
  ls "${FS_DEVICE}${FS_DEVICE_ID}"
  echo "Partition \"$FS_DEVICE_ID\" does not exist"
  echo "Existing Partitions are:"
  lsblk "$FS_DEVICE"
  echo "For the parameter, drop the leading p"
  exit 1
fi

sudo mount $FS_DEVICE$FS_DEVICE_ID $SRC

echo "Preparing destination FS.."
qemu-img create -f qcow2 $FS_ENC $SIZE
sudo qemu-nbd --connect=$FS_ENC_DEVICE $FS_ENC
sleep 2

echo "Formatting LUKS.."
sudo cryptsetup luksFormat --type luks2 $FS_ENC_DEVICE $LUKS_PARAMS
sudo cryptsetup luksOpen $FS_ENC_DEVICE snpguard_root


echo "Creating ext4 partition and mounting.."
sudo mkfs.ext4 /dev/mapper/snpguard_root


sudo mount /dev/mapper/snpguard_root $DST

echo "Copying files.."
#Without trailing slash rsync copies the directory itself and not just its content
#This messes up the directory structure
sudo rsync -axHAWXS --numeric-ids --info=progress2 $SRC/ $DST/

echo "Success. Youre encrypted disk image at $FS_ENC"

# echo "Cleaning up.."
# sudo umount $SRC
# sudo umount $DST
# sudo cryptsetup luksClose snpguard_root
# sudo qemu-nbd --disconnect $FS_DEVICE
# sudo qemu-nbd --disconnect $FS_ENC_DEVICE
# sleep 1
# sudo rmmod nbd
