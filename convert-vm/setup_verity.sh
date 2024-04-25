#!/bin/bash

set -e

SRC_DEVICE=/dev/nbd0
SRC_FOLDER=$(mktemp -d)
DST_DEVICE=/dev/nbd1
DST_FOLDER=$(mktemp -d)

clean_up() {
  echo "Cleaning up"
  #use "|| true" after each fallible common to preventing exiting from the cleanup
  #handler due to an error
  if [ -e "$SRC_FOLDER" ]; then
    echo "Unmounting $SRC_FOLDER"
    sudo umount -q "$SRC_FOLDER" 2>/dev/null || true
  fi 

  if [ -e "$DST_FOLDER" ]; then
    echo "Unmounting $DST_FOLDER"
    sudo umount -q "$DST_FOLDER" 2>/dev/null || true
  fi

  NEED_SLEEP=0
  if [ -e "$SRC_DEVICE" ]; then 
  	echo "Disconnecting $SRC_DEVICE" 
    sudo qemu-nbd --disconnect $SRC_DEVICE 2>/dev/null || true
    NEED_SLEEP=1
  fi

  if [ -e "$DST_DEVICE" ]; then
	echo "Disconnecting $DST_DEVICE" 
    sudo qemu-nbd --disconnect $DST_DEVICE 2>/dev/null || true
    NEED_SLEEP=1
  fi
  #qemu-nbd needs some time...
  if [ $NEED_SLEEP -eq 1 ]; then
    sleep 2
  fi
  sudo modprobe -r nbd || true
}
trap clean_up EXIT

FS_DEVICE_ID=
SRC_IMAGE=
DST_IMAGE=verity_image.qcow2
HASH_TREE=hash_tree.bin
ROOT_HASH=roothash.txt

usage() {
  echo "$0 [options]"
  echo " -image <path to file>                  path to VM image"
  echo " -device <device>                       NBD device to use (default: $FS_DEVICE)"
  echo " -fs-id <id>                            optional ID of the device containing the root filesystem (e.g., /dev/sdaX) (default: none)"
  echo " -out-image <path to file>              output path to verity image (default: $DST_IMAGE)"
  echo " -out-hash-tree <path to file>          output path to device hash tree (default: $HASH_TREE)"
  echo " -out-root-hash <path to file>          output path to root hash (default: $ROOT_HASH)"
  exit
}

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

while [ -n "$1" ]; do
	case "$1" in
		-image) SRC_IMAGE="$2"
			shift
			;;
		-device) FS_DEVICE="$2"
			shift
			;;
		-fs-id) FS_DEVICE_ID="p$2"
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
SIZE=$(qemu-img info "$SRC_IMAGE" | awk '/virtual size:/ { print $3 "G" }')
qemu-img create -f qcow2 $DST_IMAGE $SIZE

echo "Initializing NBD module.."
sudo modprobe nbd max_part=8

echo "Opening devices.."
sudo qemu-nbd --connect=$SRC_DEVICE $SRC_IMAGE
sudo qemu-nbd --connect=$DST_DEVICE $DST_IMAGE

echo "Creating ext4 partition on output image.."
sudo mkfs.ext4 $DST_DEVICE

echo "Mounting images.."
sudo mount $SRC_DEVICE$FS_DEVICE_ID $SRC_FOLDER 
sudo mount $DST_DEVICE $DST_FOLDER

echo "Copying files.."
#Without trailing slash rsync copies the directory itself and not just its content
#This messes up the directory structure
sudo rsync -axHAWXS --numeric-ids --info=progress2 $SRC_FOLDER/ $DST_FOLDER/

echo "Preparing output filesystem for dm-verity.."
prepare_verity_fs

echo "Unmounting images.."
sudo umount -q "$SRC_FOLDER"
sudo umount -q "$DST_FOLDER"

echo "Computing hash tree.."
sudo veritysetup format $DST_DEVICE $HASH_TREE | grep Root | cut -f2 > $ROOT_HASH

echo "Root hash: `cat $ROOT_HASH`"