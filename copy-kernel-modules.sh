#!/bin/bash
#Helper script to copy kernel modules into the ROOT_FS folder before
#compressing it to initramfs

#exit on first error
set -e


if [ -z "$1" ]; then
	echo "Set first arg to TARGET_DIR"
	exit 1
fi
if [ -z "$2" ]; then
	echo "Set second arg to list of kernel modules"
	exit 1
fi
if [ -z "$3" ]; then
	echo "Set third arg to base dir that contains the kernel modules"
	exit 1
fi

TARGET_DIR="$1"
KERNEL_MODULES="$2"
BASE_DIR="$3"

echo "Copying kernel modules to $TARGET_DIR"
for MODULE_NAME in ${KERNEL_MODULES}; do
	X=$(find "$BASE_DIR" -name "$MODULE_NAME")
	HITS=$(echo "$X" | wc -l)
	if [ $HITS -ne 1 ]; then
		echo "Failed to find module $MODULE_NAME or got multiple results"
		echo "Results: $X"
		exit 1
	fi
	cp "$X" "${TARGET_DIR}/"
done

