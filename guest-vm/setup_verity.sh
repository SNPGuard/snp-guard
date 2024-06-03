#!/bin/bash

set -e

SRC_DEVICE=/dev/nbd0
SRC_FOLDER=$(mktemp -d)
DST_DEVICE=/dev/nbd1
DST_FOLDER=$(mktemp -d)

SRC_IMAGE=
DST_IMAGE=verity_image.qcow2
HASH_TREE=hash_tree.bin
ROOT_HASH=roothash.txt

NON_INTERACTIVE=""

SCRIPT_PATH=$(realpath `dirname $0`)
. $SCRIPT_PATH/common.sh

trap clean_up EXIT

prepare_verity_fs() {
	# removing SSH keys: they will be regenerated later
	sudo rm -rf $DST_FOLDER/etc/ssh/ssh_host_*

	# remove any data in tmp folder
	sudo rm -rf $DST_FOLDER/tmp

	# rename home, etc, var dirs
	sudo mv $DST_FOLDER/home $DST_FOLDER/home_ro
	sudo mv $DST_FOLDER/etc $DST_FOLDER/etc_ro
	sudo mv $DST_FOLDER/var $DST_FOLDER/var_ro

	# create new home, etc, var dirs (original will be mounted as R/W tmpfs)
	sudo mkdir -p $DST_FOLDER/home $DST_FOLDER/etc $DST_FOLDER/var $DST_FOLDER/tmp
}

usage() {
  echo "$0 [options]"
  echo " -y                                     non-interactive option (do not ask if rootfs device is correct)"
  echo " -image <path to file>                  path to VM image"
  echo " -device <device>                       NBD device to use (default: $FS_DEVICE)"
  echo " -out-image <path to file>              output path to verity image (default: $DST_IMAGE)"
  echo " -out-hash-tree <path to file>          output path to device hash tree (default: $HASH_TREE)"
  echo " -out-root-hash <path to file>          output path to root hash (default: $ROOT_HASH)"
  exit
}

while [ -n "$1" ]; do
	case "$1" in
		-y) NON_INTERACTIVE="1"
			;;
		-image) SRC_IMAGE="$2"
			shift
			;;
		-device) FS_DEVICE="$2"
			shift
			;;
		-out-image) DST_IMAGE="$2"
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

echo "Creating output image.."
create_output_image

echo "Initializing NBD module.."
initialize_nbd

echo "Finding root filesystem.."
find_root_fs_device
echo "Rootfs device selected: $SRC_ROOT_FS_DEVICE"

echo "Creating ext4 partition on output image.."
sudo mkfs.ext4 $DST_DEVICE

echo "Mounting images.."
sudo mount $SRC_ROOT_FS_DEVICE $SRC_FOLDER 
sudo mount $DST_DEVICE $DST_FOLDER

echo "Copying files (this may take some time).."
copy_filesystem

echo "Preparing output filesystem for dm-verity.."
prepare_verity_fs

echo "Unmounting images.."
sudo umount -q "$SRC_FOLDER"
sudo umount -q "$DST_FOLDER"

echo "Computing hash tree.."
sudo veritysetup format $DST_DEVICE $HASH_TREE | grep Root | cut -f2 > $ROOT_HASH

echo "Root hash: `cat $ROOT_HASH`"

echo "All done!"