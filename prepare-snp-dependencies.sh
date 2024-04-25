#!/bin/bash

set -e

confirm_execution() {
    read -p "Are you sure you want to execute '$*'? (y/n): " choice
    case "$choice" in 
      y|Y ) eval $* ;;
      n|N ) exit ;;
      * ) echo "Invalid choice. Please enter 'y' or 'n'.";;
    esac
}

# Check for other build dependencies
if [ "$(which docker)" = "" ];then
	echo "Docker not found. Going to install it"
	curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
	sudo sh /tmp/get-docker.sh --dry-run
fi
if [ "$(which cargo)" = "" ]; then
	echo "Rust toolchain not found. Going to install it"
	confirm_execution "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
	source ~/.bashrc
	source ~/.profile
fi

echo "Installing build dependencies"
confirm_execution "sudo apt update && sudo apt install make whois pv"

# TODO: see if we need part below and update if necessary

#set env var for make file
ROOT_DIR=`realpath .`
BUILD_DIR=$ROOT_DIR/build
SEV_TOOLCHAIN_DIR=$BUILD_DIR/snp-release/usr/local
KERNEL_DIR=$BUILD_DIR/kernel
KERNEL_MODULES_DIR=$KERNEL_DIR/lib/modules

#ovmf_file = "path to OVMF.fd file used by QEMU"
#kernel_file = "path to kernel file that gets passed to QMEU"
#initrd_file = "path to initramdisk file that gets passed to QEMU"
OVMF_PATH=$SEV_TOOLCHAIN_DIR/share/qemu/DIRECT_BOOT_OVMF.fd
KERNEL_PATH=`ls $KERNEL_DIR/boot/vmlinuz*`
INITRD_PATH=$BUILD_DIR/initramfs.cpio.gz

echo "Creating .env file at $OUT_ENV_FILE"
mkdir -p $BUILD_DIR
OUT_ENV_FILE="$BUILD_DIR/build.env"
rm -rf $OUT_ENV_FILE

echo "export KERNEL_MODULES_DIR=$KERNEL_MODULES_DIR" >> "$OUT_ENV_FILE"
echo "export SEV_TOOLCHAIN_PATH=$SEV_TOOLCHAIN_DIR" >> "$OUT_ENV_FILE"

OUT_CONFIG_PATH="$BUILD_DIR/vm-config.toml"
echo "Creating default VM config file at $OUT_CONFIG_PATH"
cp ./tools/attestation_server/examples/vm-config.toml "$OUT_CONFIG_PATH"

sed -i "\@ovmf_file@c ovmf_file = \"${OVMF_PATH}\"" "$OUT_CONFIG_PATH"
sed -i "\@kernel_file@c kernel_file = \"${KERNEL_PATH}\"" "$OUT_CONFIG_PATH"
sed -i "\@initrd_file@c initrd_file = \"${INITRD_PATH}\"" "$OUT_CONFIG_PATH"
