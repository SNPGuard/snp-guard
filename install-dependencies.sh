#!/bin/bash

set -e

Color_Off='\033[0m'       # Text Reset
BBlack='\033[1;30m'       # Black
BRed='\033[1;31m'         # Red
BGreen='\033[1;32m'       # Green
BYellow='\033[1;33m'      # Yellow
BBlue='\033[1;34m'        # Blue
BWhite='\033[1;37m'       # White

wait_for_enter() {
    while [ true ]
    do
        read -s -n 1 key
        case $key in 
            "")
                break
                ;;
            *)
                ;;
        esac
    done
}

check_root() {
    if [ "$EUID" -eq 0 ]
    then 
        warn "Please do not run this script as root"
    exit 1
    fi
}

check_sudo() {
    if ! command -v sudo &> /dev/null
    then
        warn "'sudo' is not installed on the machine. Please log in as 'root' and run 'apt-get update && apt-get install sudo'"
        exit 1
    fi
    
    if ! sudo ls > /dev/null
    then
        warn "It seems like you don't have root privileges. Please make sure you are added to the 'sudo' group."
        exit 1
    fi
}

check_distro() {
    os=`cat /etc/os-release 2> /dev/null || echo ""`
    if  echo $os | grep 'NAME="Ubuntu"' > /dev/null || echo $os | grep 'NAME="Debian GNU/Linux"' > /dev/null
    then :
    else
        echo -e -n "${BYellow}"
        echo "It seems like you are running a different OS than Ubuntu or Debian, which this script does not support."
        echo "If you think this is an error or if you want to continue anyway, press ENTER, otherwise exit with CTRL-C"
        echo -e -n "${Color_Off}"
        wait_for_enter
    fi
}

start() {
    echo -e -n "${BWhite}"
    echo "Welcome! This script will install all the required dependencies to run our artifacts."
    if [ $FORCE -eq 0 ]
    then
        echo "By default, this script will *not* attempt to install components that are already installed."
        echo "This means that if you have outdated versions installed, you *might* encounter problems when running the artifacts."
        echo "If you want to install up-to-date packages, run this script with '-f' instead."
    else
        echo "You are running the script in *force* mode: any existing dependencies will be replaced with up-to-date versions."
        echo "If you do *not* want to overwrite the current packages, run this script without '-f' instead."
    fi
    echo -e -n "${BGreen}"
    echo "Press ENTER to continue, or CTRL-C to exit"
    echo -e -n "${Color_Off}"
    wait_for_enter
}

err_report() {
    echo -e -n "${BRed}"
    echo "Could not install all dependencies correctly due to an error on line $1"
    echo "Running the artifacts with the current setup might cause errors."
    echo "We recommend fixing the error and then running this script again to complete the installation."
    echo -e -n "${Color_Off}"
}

print_section() {
    echo
    echo -e -n "${BYellow}"
    echo "### Installing $1 ###"
    echo -e -n "${Color_Off}"
}

success() {
    echo
    echo -e -n "${BGreen}"
    echo "Success! Your machine is now set up correctly for running the artifacts."
	echo "You may need to reload your shell to use certain components."
    echo -e -n "${Color_Off}"
}

info() {
    echo -e -n "${BBlue}"
    echo $1
    echo -e -n "${Color_Off}"
}

warn() {
    echo -e -n "${BYellow}"
    echo $1
    echo -e -n "${Color_Off}"
}

trap 'err_report $LINENO' ERR

if [ "$1" = "-f" ]; then
   FORCE=1
else
  FORCE=0
fi

check_distro
check_root
check_sudo
start

print_section "apt dependencies"
sudo apt update && sudo apt install -y git curl wget make whois pv genisoimage \
    qemu-utils pkg-config gcc libssl-dev cpio kmod fdisk rsync cryptsetup

print_section "Docker"
if ! command -v docker &> /dev/null || [ $FORCE -eq 1 ]
then
    info "Uninstalling old versions (if present).."
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do sudo apt-get remove $pkg || true; done
    info "Getting docker. Note: you may see a warning from the docker script, you can safely ignore it"
    sleep 5
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh ./get-docker.sh
    rm get-docker.sh
    sudo usermod -aG docker $USER
else
    echo "Seems like Docker is already installed, skipping."
fi

print_section "Rust toolchain"
if ! command -v cargo &> /dev/null || [ $FORCE -eq 1 ]
then
    info "Getting Rust toolchain. We recommend to choose the default install option."
    sleep 5
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
else
    echo "Seems like Rust is already installed, skipping."
fi

print_section "libslirp 4.7.0 (Needed to enable user networking in QEMU)"

LIBSLIRP_VERS=$(dpkg -l | grep libslirp0 | awk '{ print $3 }')
LIBSLIRP_DEV_VERS=$(dpkg -l | grep libslirp-dev | awk '{ print $3 }')

if [[ $LIBSLIRP_VERS != 4.7.0* ]]; then
	info "Installing libslirp0 4.7.0"
	wget -nv http://se.archive.ubuntu.com/ubuntu/pool/main/libs/libslirp/libslirp0_4.7.0-1_amd64.deb -O libslirp0.deb
	sudo dpkg -i libslirp0.deb
	rm -rf libslirp0.deb
else
	echo "Seems like libslirp0 4.7.0 is already installed, skipping."
fi

if [[ $LIBSLIRP_DEV_VERS != 4.7.0* ]]; then
	info "Installing libslirp-dev 4.7.0"
	wget -nv http://se.archive.ubuntu.com/ubuntu/pool/main/libs/libslirp/libslirp-dev_4.7.0-1_amd64.deb -O libslirp-dev.deb
	sudo dpkg -i libslirp-dev.deb
	rm -rf libslirp-dev.deb
else
	echo "Seems like libslirp-dev 4.7.0 is already installed, skipping."
fi

success