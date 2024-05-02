#!/bin/bash

set -e

ROOT_DIR=$(realpath .)
SCRIPT_DIR=$ROOT_DIR/snp-builder
BUILD_DIR=$ROOT_DIR/build

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

mkdir -p $BUILD_DIR

echo "Installing build dependencies for kernel, OVMF and QEMU"
sudo apt update
xargs -a $SCRIPT_DIR/dependencies.txt sudo apt install -y --no-install-recommends

echo "Installing libslirp 4.7.1 packages, needed to enable user networking in QEMU"
wget http://se.archive.ubuntu.com/ubuntu/pool/main/libs/libslirp/libslirp0_4.7.0-1_amd64.deb -O libslirp0.deb
wget http://se.archive.ubuntu.com/ubuntu/pool/main/libs/libslirp/libslirp-dev_4.7.0-1_amd64.deb -O libslirp-dev.deb

sudo dpkg -i libslirp0.deb
sudo dpkg -i libslirp-dev.deb

rm -rf libslirp0.deb libslirp-dev.deb

if [ -z "$AMDPATH" ]; then
	AMDPATH=$BUILD_DIR/AMDSEV
    git clone https://github.com/AMDESE/AMDSEV.git --branch snp-latest --depth 1 $AMDPATH
else
  echo "Using AMDSEV repository: $(realpath $AMDPATH)"
fi

pushd $AMDPATH 2>/dev/null

echo "Applying patches"
git restore . # remove changes that may have been made before
git apply $SCRIPT_DIR/patches/*.patch

echo "Building AMDSEV Repo. This might take a while"
./build.sh --package

echo "Move SNP dir to root"
mv snp-release-*/ $BUILD_DIR/snp-release/

popd