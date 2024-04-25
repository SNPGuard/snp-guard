#!/bin/bash

set -e

FS_DEVICE=/dev/nbd0
FS_DEVICE_ID=

IMAGE=
HASH_TREE=verity
ROOT_HASH=roothash.txt

usage() {
  echo "$0 [options]"
  echo " -image <path to file>                  path to VM image"
  echo " -device <device>                       NBD device to use (default: $FS_DEVICE)"
  echo " -fs-id <id>                            optional ID of the device containing the root filesystem (e.g., /dev/sdaX) (default: none)"
  echo " -out-hash-tree <path to file>          output path to device hash tree (default: $HASH_TREE)"
  echo " -out-root-hash <path to file>          output path to root hash (default: $ROOT_HASH)"
  exit
}

while [ -n "$1" ]; do
	case "$1" in
		-image) IMAGE="$2"
			shift
			;;
		-device) FS_DEVICE="$2"
			shift
			;;
		-fs-id) FS_DEVICE_ID="p$2"
			shift
			;;
		-out-hash-tree) HASH_TREE="$2"
			shift
			;;
		-out-root-hash) ROOT_HASH="$2"
			shift
			;;
		*) 		usage
				;;
	esac

	shift
done


echo "Initializing NBD module.."
sudo modprobe nbd max_part=8

echo "Mounting image.."
sudo qemu-nbd --connect=$FS_DEVICE $IMAGE

echo "Computing hash tree.."
sudo veritysetup format $FS_DEVICE$FS_DEVICE_ID $HASH_TREE | grep Root | cut -f2 > $ROOT_HASH

echo "Root hash: `cat $ROOT_HASH`"

echo "Cleaning up.."
sudo qemu-nbd --disconnect $FS_DEVICE
sleep 1
sudo rmmod nbd