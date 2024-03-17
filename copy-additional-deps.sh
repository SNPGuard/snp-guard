#!/bin/bash

#exit on first error
set -e

TARGET_DIR=$1

if [ -z "$2" ]; then
	exit
fi

SOURCE_FILE_LIST=$2

echo "Copying additional binaries to ${TARGET_DIR}"
for file in ${SOURCE_FILE_LIST}; do
	cp ${file} ${TARGET_DIR}/ 
done
