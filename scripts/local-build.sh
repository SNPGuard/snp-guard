#!/bin/bash

set -e

ROOT_DIR=$(realpath .)

usage() {
  echo "$0 [options]"
  echo " -amdsev <path to dir> Use local AMDSEV repository (e.g., for incremental builds)"
  exit
}

while [ -n "$1" ]; do
	case "$1" in
		-amdsev) AMDPATH="$2"
			shift
			;;
		*) 		usage
				;;
	esac

	shift
done

echo "Installing build dependencies for kernel, OVMF and QEMU"
sudo apt update
xargs -a dependencies.txt sudo apt install -y --no-install-recommends

if [ -z "$AMDPATH" ]; then
    git clone https://github.com/AMDESE/AMDSEV.git --branch snp-latest --depth 1
    AMDPATH="AMDSEV"
else
  echo "Using AMDSEV repository: $(realpath $AMDPATH)"
fi

pushd $AMDPATH 2>/dev/null

echo "Applying OVMF patch.."
git restore . # remove changes that may have been made before
git apply $ROOT_DIR/0001-build-direct-boot-ovmf.patch

echo "Building AMDSEV Repo. This might take a while"
./build.sh --package

echo "Move SNP dir to root"
mv snp-release-*/ $ROOT_DIR/snp-release/

popd