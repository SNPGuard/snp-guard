#!/bin/bash

# variables that need to be set up before calling these functions:
#
# - {SRC,DST}_IMAGE: path to source and dest VM images
# - {SRC,DST}_DEVICE: path to source and dest devices connected to the VM images
# - {SRC,DST}_FOLDER: path to source and dest folders where the devices are mounted

# Additional variables for find_root_fs_device()
# Inputs:
# - NON_INTERACTIVE: do not ask for user confirmation
# Outputs:
# - SRC_ROOT_FS_DEVICE: device containing root filesystem


clean_up() {
    echo "Cleaning up"
    #use "|| true" after each fallible common to preventing exiting from the cleanup
    #handler due to an error
    if [ -e "$SRC_FOLDER" ]; then
        echo "Unmounting $SRC_FOLDER"
        sudo umount -q "$SRC_FOLDER" 2>/dev/null || true
        rm -rf $SRC_FOLDER
    fi 

    if [ -e "$DST_FOLDER" ]; then
        echo "Unmounting $DST_FOLDER"
        sudo umount -q "$DST_FOLDER" 2>/dev/null || true
        rm -rf $DST_FOLDER
    fi

    if [ -e "/dev/mapper/snpguard_root" ]; then
        echo "Closing mapper device"
        sudo cryptsetup luksClose snpguard_root 2>/dev/null || true
    fi

    unmount_lvm_device

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

find_root_fs_device() {
    get_lvm_device

    if [ -n "$SRC_ROOT_FS_DEVICE" ];then
        return
    fi

	SRC_ROOT_FS_DEVICE=$(sudo fdisk $SRC_DEVICE -l | grep -i "Linux filesystem" | awk '{print $1}')

	if [ -n "$NON_INTERACTIVE" ]; then
		return
	fi

    # show fdisk output to user
    sudo fdisk $SRC_DEVICE -l

	ROOT_FS_FOUND=""
	if [ -e "$SRC_ROOT_FS_DEVICE" ];then
		echo "Found the following filesystem: $SRC_ROOT_FS_DEVICE"
		while [ -z "$ROOT_FS_FOUND" ]; do
			read -p "Do you confirm that this is correct? (y/n): " choice
			case "$choice" in 
			y|Y ) ROOT_FS_FOUND="1" ;;
			n|N ) ROOT_FS_FOUND="0" ;;
			* ) echo "Invalid choice. Please enter 'y' or 'n'.";;
			esac
		done
	else
		echo "Failed to identify root filesystem $SRC_ROOT_FS_DEVICE."
        ROOT_FS_FOUND="0"
	fi

	if [ "$ROOT_FS_FOUND" = "0" ]; then
		read -p "Enter device containing the root filesystem: " SRC_ROOT_FS_DEVICE
		if [ ! -e "$SRC_ROOT_FS_DEVICE" ];then
			echo "Could not find root filesystem."
			exit 1
		fi
	fi
}

# We store the number of LVM devices prior to mounting the VM image
#
# If, after mounting the VM image, there is a new LVM device compared to before,
# it means that the VM image uses a LVM filesystem. Therefore, we try to access it.
#
# However, if there was already a LVM device mounted to the host before running the script,
# we might not be able to fetch the correct device due to conflicting names
check_lvm() {
    __LVM_DEVICES=$(sudo lvdisplay 2>/dev/null | grep "LV Path" | wc -l)

    if [ "$__LVM_DEVICES" -gt "0" ];then
        echo "Warning: a LVM filesystem is currently in use on your system."
        echo "If your guest VM image uses LVM as well, this script might not work as intended."
        sleep 2
    fi
}

get_lvm_device() {
    # check for errors first
    HAS_WARNING=$(sudo lvdisplay 2>&1 > /dev/null | grep "WARNING" | cat)
    if [ -n "$HAS_WARNING" ];then
        echo "Error: seems like the guest VM had a LVM filesystem that could not be mounted"
        echo "Cannot continue. Try creating a new VM using our guide."
        echo "Log from lvdisplay:"
        echo "$HAS_WARNING"
        exit 1
    fi

    LVM_DEVICES=$(sudo lvdisplay 2>/dev/null | grep "LV Path" | wc -l)

    if [ "$LVM_DEVICES" -gt "$__LVM_DEVICES" ];then
        SRC_ROOT_FS_DEVICE=$(sudo lvdisplay 2>/dev/null | grep "LV Path" | tail -n 1 | awk '{ print $3 }')
        echo "Found LVM2 filesystem: $SRC_ROOT_FS_DEVICE"
    fi
}

unmount_lvm_device() {
    LVM_DEVICES=$(sudo lvdisplay 2>/dev/null | grep "LV Path" | wc -l)

    if [ "$LVM_DEVICES" -gt "$__LVM_DEVICES" ];then
        echo "Unmounting LVM device"
        LVM_PATH=$(sudo lvdisplay 2>/dev/null | grep "LV Path" | tail -n 1 | awk '{ print $3 }')
        VG_NAME=$(sudo lvdisplay 2>/dev/null | grep "VG Name" | tail -n 1 | awk '{ print $3 }')
        sudo lvchange -an $LVM_PATH
        sudo vgchange -an $VG_NAME
    fi
}

initialize_nbd() {
    check_lvm
    sudo modprobe nbd max_part=8
    sudo qemu-nbd --connect=$SRC_DEVICE $SRC_IMAGE
    sudo qemu-nbd --connect=$DST_DEVICE $DST_IMAGE
}

create_output_image() {
    SIZE=$(qemu-img info "$SRC_IMAGE" | awk '/virtual size:/ { print $3 "G" }')
    qemu-img create -f qcow2 $DST_IMAGE $SIZE
}

copy_filesystem() {
    #Without trailing slash rsync copies the directory itself and not just its content
    #This messes up the directory structure
    sudo rsync -axHAWXS --numeric-ids --info=progress2 $SRC_FOLDER/ $DST_FOLDER/
}