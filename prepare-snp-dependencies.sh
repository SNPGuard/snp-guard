#!/bin/bash

set -e


usage() {
  echo "$0 [options]"
  echo " -use-existing-amdsev <path to dir>   This will skip cloning and building the AMDSEV repository and instead use the one located at the specified location. It it assumed that you already took care of building the required components"
  exit
}

confirm_execution() {
    read -p "Are you sure you want to execute '$*'? (y/n): " choice
    case "$choice" in 
      y|Y ) eval $* ;;
      n|N ) exit ;;
      * ) echo "Invalid choice. Please enter 'y' or 'n'.";;
    esac
}

while [ -n "$1" ]; do
	case "$1" in
		# -some-boolean-option)	SOME_FLAG="1"
		# 		;;
		-use-existing-amdsev) AMDPATH="$2"
			shift
			;;
		*) 		usage
				;;
	esac

	shift
done

#we populate this with the env vars required for the main makefile
OUT_ENV_FILE="./build.env"
echo "" > "$OUT_ENV_FILE"

#IF -use-existing-amdsev was not specified, clone AMDSEV repo
# install all build deps and build app components
if [ -z "$AMDPATH" ]; then

	#The build depedency installation currently only works for Ubuntu
	if [ "$(lsb_release -si)" = "Ubuntu" ]; then
		DEB_REPOS=$(grep -E "^\s*deb " /etc/apt/sources.list| wc -l)
		DEB_SRC_REPOS=$(grep -E "^\s*deb-src " /etc/apt/sources.list| wc -l)
		if [ $DEB_SRC_REPOS -ne $DEB_REPOS ]; then
			TMP_APT=$(mktemp)
			sed -e '/deb-src/ s/^[[:space:]]*#*//' /etc/apt/sources.list > "$TMP_APT"

			echo "It looks you have don't have the deb-src repos enabled. We need them to lookup the build dependencies."
			#!/bin/bash
			echo "Review the revised sources.list file at ${TMP_APT}"
			confirm_execution "sudo cp "$TMP_APT" /etc/apt/sources.list"
		fi #if deb-src not enabled
		echo "Installing build dependencies for kernel, OVMF and QEMU"
		confirm_execution "sudo apt update && sudo apt install build-essential ninja-build python-is-python3 flex bison libncurses-dev gawk openssl libssl-dev dkms libelf-dev libudev-dev libpci-dev libiberty-dev autoconf llvm && sudo apt build-dep ovmf qemu-system-x86 linux"
  AMDPATH="$(pwd)/AMDSEV"
  echo "Cloning AMDSEV repo to $AMDPATH..."
  git clone https://github.com/AMDESE/AMDSEV.git "$AMDPATH"
fi #if on ubuntu


  #Patch and build AMDSEV repo
  pushd "$AMDPATH" 2>/dev/null
    git checkout snp-latest
    git checkout -b openend2e-sev-snp
    echo "Applying openend2e-sev specific patches..."
    git am < ../0001-build-direct-boot-ovmf.patch

    echo "Building AMDSEV Repo. This might take a while"
    ./build.sh
	echo "Installing KVM config"
	confirm_execution "sudo cp kvm.conf /etc/modprobe.d/"
  popd
else #AMDPATH is set
  echo "Skipping cloning and building the AMD repo"
fi #if AMDPATH not set


#Copy and extract vm kernel .deb file
echo "Locating guest kernel"
GUEST_DEB=$(find "${AMDPATH}/linux" -maxdepth 1 -name "linux-image*-snp-guest*")
if [ -z "$GUEST_DEB" ]; then
  echo "Unable to find .deb package for guest kernel. Did something go wrong with the build?"
  exit 1
fi
mkdir -p vm-kernel
cp "$GUEST_DEB" vm-kernel/
dpkg -x vm-kernel/*.deb vm-kernel/


# Check for other build dependencies
if [ "$(which docker)" = "" ];then
	read -p "It looks like you don't have docker installed. Please visit https://docs.docker.com/engine/install/ubuntu/ to install it. Afterwards press enter to continue"
fi
if [ "$(which cargo)" = "" ]; then
	echo "Rust toolchain not found. Going to install it"
	confirm_execution "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
	source ~/.bashrc
	source ~/.profile
fi
echo "Installing dependencies for our tool"
confirm_execution "sudo apt install make podman pv whois"


#set env var for make file
echo "Creating .env file at $OUT_ENV_FILE"
echo "export KERNEL_MODULES_DIR=$(pwd)/vm-kernel/lib/modules" >> "$OUT_ENV_FILE"
echo "export SEV_TOOLCHAIN_PATH=${AMDPATH}/usr/local/" >> "$OUT_ENV_FILE"

echo "Creating VM config file"
cp ./attestation_server/examples/vm-config.toml  ./build/binaries/default-vm-config.toml

#ovmf_file = "path to OVMF.fd file used by QEMU"
#kernel_file = "path to kernel file that gets passed to QMEU"
#initrd_file = "path to initramdisk file that gets passed to QEMU"
OVMF_PATH=${AMDPATH}/usr/local/share/qemu/DIRECT_BOOT_OVMF.fd
sed -i "\@ovmf_file@c ovmf_file = \"${OVMF_PATH}\"" ./build/binaries/default-vm-config.toml
KERNEL_PATH="$(pwd)/$(ls ./vm-kernel/boot/vmlinuz*)"
sed -i "\@kernel_file@c kernel_file = \"${KERNEL_PATH}\"" ./build/binaries/default-vm-config.toml
INITRD_FILE="./build/binaries/initramfs.cpio.gz"
sed -i "\@initrd_file@c initrd_file = \"${INITRD_FILE}\"" ./build/binaries/default-vm-config.toml
