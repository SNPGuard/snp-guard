#!/bin/bash

set -e

SCRIPT_DIR=$(realpath `dirname $0`)

BUILD_DIR=$(realpath build)
KERNEL_DIR=""
INIT_SCRIPT=""
INIT_PATCH=""
OUT="$BUILD_DIR/initramfs.cpio.gz"

usage() {
  echo "$0 [options]"
  echo " -kernel-dir <path to dir>              path to kernel directory"
  echo " -init <path to file>                   path to init script"
  echo " -init-patch <path to file>             path to init patch file"
  echo " -out <path to file>                    output file path (default: $OUT)"
  exit
}

while [ -n "$1" ]; do
	case "$1" in
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

if [ ! -d "$KERNEL_DIR" ]; then
    echo "Can't locate kernel modules directory $KERNEL_DIR"
    usage
fi

if [ ! -f "$INIT_SCRIPT" ]; then
    echo "Can't locate init script $INIT_SCRIPT"
    usage
fi

echo "Preparing directories.."
INITRD_DIR=$BUILD_DIR/initramfs
rm -rf $INITRD_DIR
mkdir -p $INITRD_DIR

echo "Building Docker image.."
DOCKER_IMG="nano-vm-rootfs"
docker build -t $DOCKER_IMG $SCRIPT_DIR

echo "Running container.."
docker stop $DOCKER_IMG > /dev/null 2>&1 || true
docker run --rm -d --name $DOCKER_IMG $DOCKER_IMG sleep 3600

echo "Exporting filesystem.."
docker export $DOCKER_IMG | tar xpf - -C $INITRD_DIR

echo "Copying kernel modules.."
cp -r $KERNEL_DIR/lib $INITRD_DIR/usr

echo "Copying binaries.."
cp -r $BUILD_DIR/bin $INITRD_DIR/usr

echo "Copying init script.."
cp $INIT_SCRIPT $INITRD_DIR/init

if [ -f "$INIT_PATCH" ]; then
    echo "Patching init script.."
    cp $INIT_SCRIPT $INITRD_DIR/init
    patch $INITRD_DIR/init $INIT_PATCH
fi

echo "Removing unnecessary files and directories.."
rm -rf $INITRD_DIR/dev $INITRD_DIR/proc $INITRD_DIR/sys $INITRD_DIR/boot \
	$INITRD_DIR/home $INITRD_DIR/media $INITRD_DIR/mnt $INITRD_DIR/opt \
	$INITRD_DIR/root $INITRD_DIR/srv $INITRD_DIR/tmp $INITRD_DIR/.dockerenv

# We need to clear the "s" permission bit from some executables lime `mount`
echo "Changing permissions.."
chmod -st $INITRD_DIR/usr/bin/* > /dev/null 2>&1 || true

echo "Repackaging initrd.."
(cd $INITRD_DIR ; find . -print0 | cpio --null -ov --format=newc 2>/dev/null | pv | gzip -1 > $OUT)

echo "Cleaning up.."
docker stop $DOCKER_IMG > /dev/null 2>&1
#rm -rf $INITRD_DIR

echo "Done! New initrd can be found ad $OUT"