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
confirm_execution "sudo apt update && sudo apt install make whois pv genisoimage"