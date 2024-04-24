IMAGE             ?= vm-data/sevsnptest.qcow2
SNP_DIR           ?= snp-release

BUILD_DIR         ?= $(shell realpath build)

HEADERS_DEB       ?= $(SNP_DIR)/linux/guest/linux-headers-*.deb
KERNEL_DEB        ?= $(SNP_DIR)/linux/guest/linux-image-*.deb

KERNEL_DIR        ?= $(BUILD_DIR)/kernel
KERNEL            ?= $(KERNEL_DIR)/boot/vmlinuz-*
INITRD            ?= $(BUILD_DIR)/initramfs.cpio.gz
KERNEL_CMDLINE    ?= "console=ttyS0 earlyprintk=serial root=/dev/sda1 boot=normal"

IMAGE_PATH         = $(shell realpath $(IMAGE))
KERNEL_PATH        = $(shell realpath $(KERNEL))
INITRD_PATH        = $(shell realpath $(INITRD))

INITRD_ORIG       ?= $(KERNEL_DIR)/initrd.img-*
INIT_SCRIPT       ?= init.sh

run:
	cd $(SNP_DIR) && sudo ./launch-qemu.sh -hda $(IMAGE_PATH) -default-network

run_sev_snp:
	cd $(SNP_DIR) && sudo ./launch-qemu.sh -hda $(IMAGE_PATH) -sev-snp -default-network

run_sev_snp_direct_boot:
	cd $(SNP_DIR) && sudo ./launch-qemu.sh -hda $(IMAGE_PATH) -sev-snp -default-network -kernel $(KERNEL_PATH) -initrd $(INITRD_PATH) -append $(KERNEL_CMDLINE)

unpack_kernel: init_dir
	dpkg -x $(KERNEL_DEB) $(KERNEL_DIR)

build_tools: build_attestation_server

build_attestation_server:
	cargo build --manifest-path=attestation_server/Cargo.toml
	cp ./attestation_server/target/debug/server $(BUILD_DIR)/bin

initramfs_from_existing:
	./scripts/build-initramfs.sh -initrd $(INITRD_ORIG) -kernel-dir $(KERNEL_DIR) -init $(INIT_SCRIPT) -out $(INITRD)

initramfs:
	./scripts/build-initramfs-docker.sh -kernel-dir $(KERNEL_DIR) -init $(INIT_SCRIPT) -out $(INITRD)

init_dir:
	mkdir -p $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)/bin

clean:
	rm -rf $(BUILD_DIR)