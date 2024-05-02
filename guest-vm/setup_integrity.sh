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

SCRIPT_PATH=$(realpath `dirname $0`)
. $SCRIPT_PATH/common.sh

trap clean_up EXIT

usage() {
  echo "$0 [options]"
  echo ""
  echo "-in PATH                  [Mandatory] Path to input qcow2 disk image"
  echo "-key PATH                 [Mandatory] Path to integrity key (max. 4096 bytes)"
  echo "-out PATH                 [Optional] Path where the encrypted qcow2 disk is created. Defaults to the directory of the input file with -encrypted suffix"
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
    -key) KEY_FILE="$2"
      shift
      ;;
    *)
      usage
      ;;
  esac
  shift
done

if [ ! -f "$KEY_FILE" ]; then
  echo "Invalid password file"
  usage
fi


#Paramters for integrity
INTEGRITY_PARAMS="--integrity hmac-sha256 --integrity-key-file $KEY_FILE --integrity-key-size $(stat --printf="%s" $KEY_FILE)"

echo "Creating output image.."
create_output_image

echo "Initializing NBD module.."
initialize_nbd

echo "Finding root filesystem.."
find_root_fs_device
echo "Rootfs device selected: $SRC_ROOT_FS_DEVICE"

echo "Formatting destination device.."
sudo integritysetup format $DST_DEVICE $INTEGRITY_PARAMS
sudo integritysetup open $DST_DEVICE snpguard_root $INTEGRITY_PARAMS

echo "Creating ext4 partition and mounting.."
sudo mkfs.ext4 /dev/mapper/snpguard_root

sudo mount $SRC_ROOT_FS_DEVICE $SRC_FOLDER
sudo mount /dev/mapper/snpguard_root $DST_FOLDER

echo "Copying files.."
copy_filesystem

echo "Success. Your integrity-protected disk image is at $DST_IMAGE"