#!/bin/bash
#This script clones the given partition on a qcow2 disk to a new encrypted partition
#on a new  qcow2 disk

set -e

SRC_DEVICE=/dev/nbd0
SRC_FOLDER=$(mktemp -d)
DST_DEVICE=/dev/nbd1
DST_FOLDER=$(mktemp -d)

SRC_IMAGE=
DST_IMAGE=
HASH_TREE=hash_tree.bin
ROOT_HASH=roothash.txt

NON_INTERACTIVE=""

#Paramters for the encryption
LUKS_PARAMS="--cipher aes-xts-random --integrity hmac-sha256"

SCRIPT_PATH=$(realpath `dirname $0`)
. $SCRIPT_PATH/common.sh

trap clean_up EXIT

usage() {
  echo "$0 [options]"
  echo ""
  echo "-in PATH.qcow2            [Mandatory] Path to unencrypted input qcow2 disk image"
  echo "-out PATH.qcow2           [Optional] Path where the encrypted qcow2 disk is created. Defaults to the directory of the input file with -encrypted suffix"
  echo ""
  exit
}

if [ $# -eq 0 ]; then
  usage
fi

while [ -n "$1" ]; do
  case "$1" in
    -in) SRC_IMAGE="$2"
      shift
      ;;
    -out) DST_IMAGE="$2"
      shift
      ;;
    *)
      usage
      ;;
  esac
  shift
done

if [ -z "$DST_IMAGE" ]; then
  FILE_NO_EXTENSION="${SRC_IMAGE%.*}"
  DST_IMAGE="${FILE_NO_EXTENSION}-encrypted.qcow2"
fi

echo "Creating output image.."
create_output_image

echo "Initializing NBD module.."
initialize_nbd

echo "Finding root filesystem.."
find_root_fs_device
echo "Rootfs device selected: $SRC_ROOT_FS_DEVICE"

echo "Formatting LUKS.."
sudo cryptsetup luksFormat --type luks2 $DST_DEVICE $LUKS_PARAMS
sudo cryptsetup luksOpen $DST_DEVICE snpguard_root

echo "Creating ext4 partition and mounting.."
sudo mkfs.ext4 /dev/mapper/snpguard_root

sudo mount $SRC_ROOT_FS_DEVICE $SRC_FOLDER
sudo mount /dev/mapper/snpguard_root $DST_FOLDER

echo "Copying files (this may take some time).."
copy_filesystem

echo "Success. Your encrypted disk image is at $DST_IMAGE"