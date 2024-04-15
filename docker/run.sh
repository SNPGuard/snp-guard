#!/bin/bash

package() {
    INSTALL_DIR="`pwd`/usr/local"
    OUTPUT_DIR="../snp-release"

    rm -rf $OUTPUT_DIR
    mkdir -p $OUTPUT_DIR/linux/guest
    mkdir -p $OUTPUT_DIR/linux/host
    mkdir -p $OUTPUT_DIR/usr
    cp -dpR $INSTALL_DIR $OUTPUT_DIR/usr/
    cp source-commit.* $OUTPUT_DIR/
    cp stable-commits $OUTPUT_DIR/source-config

    cp linux/linux-*-guest-*.deb $OUTPUT_DIR/linux/guest -v
	cp linux/linux-*-host-*.deb $OUTPUT_DIR/linux/host -v

    # do not package debug kernel versions to save space
    rm -rf $OUTPUT_DIR/linux/guest/*-dbg_*.deb
    rm -rf $OUTPUT_DIR/linux/host/*-dbg_*.deb

    cp launch-qemu.sh ${OUTPUT_DIR} -v
    cp install.sh ${OUTPUT_DIR} -v
    cp kvm.conf ${OUTPUT_DIR} -v
    tar zcvf ${OUTPUT_DIR}.tar.gz ${OUTPUT_DIR}
}

cd AMDSEV
./build.sh
package