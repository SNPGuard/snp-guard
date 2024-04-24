#!/bin/bash

set -e

BUILD_DIR=$(realpath build)
INITRD=""
KERNEL_DIR=""
INIT_SCRIPT=""
INIT_PATCH=""
OUT="$BUILD_DIR/initramfs.cpio.gz"

# TODO add needed modules and executables: something about lvm2 maybe?

KERNEL_MODULES=(
    "drivers/md/dm-integrity.ko"
    "drivers/md/dm-verity.ko"
)

EXECUTABLES=(
    `which depmod`
    `which veritysetup`
)

usage() {
  echo "$0 [options]"
  echo " -initrd <path to file>                 path to original initrd file"
  echo " -kernel-dir <path to dir>              path to kernel directory"
  echo " -init <path to file>                   path to init script"
  echo " -init-patch <path to file>             path to init patch file"
  echo " -out <path to file>                    output file path (default: $OUT)"
  exit
}

while [ -n "$1" ]; do
	case "$1" in
		-initrd) INITRD="$2"
			shift
			;;
		-kernel-dir) KERNEL_DIR="$2"
			shift
			;;
		-init) INIT_SCRIPT="$2"
			shift
			;;
		-init-patch) INIT_PATCH="$2"
			shift
			;;
		-out) OUT="$2"
			shift
			;;
		*) 		usage
				;;
	esac

	shift
done

if [ ! -f "$INITRD" ]; then
    echo "Can't locate initrd file $INITRD"
    usage
fi

if [ ! -d "$KERNEL_DIR" ]; then
    echo "Can't locate kernel modules directory $KERNEL_DIR"
    usage
fi

echo "Preparing directories.."
INITRD_DIR=$BUILD_DIR/initramfs
rm -rf $INITRD_DIR
mkdir -p $INITRD_DIR

echo "Unpacking initrd.."
unmkinitramfs $INITRD $INITRD_DIR

echo "Adding kernel modules.."
KERNEL_VERSION=`ls $KERNEL_DIR/lib/modules`
KERNEL_MODULES_SRC="$KERNEL_DIR/lib/modules/$KERNEL_VERSION/kernel"
KERNEL_MODULES_DST="$INITRD_DIR/lib/modules/$KERNEL_VERSION/kernel"
for mod in "${KERNEL_MODULES[@]}"
do
   cp $KERNEL_MODULES_SRC/$mod $KERNEL_MODULES_DST/$mod
done

echo "Adding executables.."
BIN_DIR=$INITRD_DIR/bin
for exec in "${EXECUTABLES[@]}"
do
   cp $exec $BIN_DIR
done

if [ -f "$INIT_SCRIPT" ]; then
    echo "Copying init script.."
    cp $INIT_SCRIPT $INITRD_DIR/init
fi

if [ -f "$INIT_PATCH" ]; then
    echo "Patching init script.."
    cp $INIT_SCRIPT $INITRD_DIR/init
    patch $INITRD_DIR/init $INIT_PATCH
fi

echo "Repackaging initrd.."
(cd $INITRD_DIR ; find . -print0 | cpio --null -ov --format=newc 2>/dev/null | pv | gzip -1 > $OUT)

echo "Cleaning up.."
rm -rf $INITRD_DIR

echo "Done! New initrd can be found ad $OUT"