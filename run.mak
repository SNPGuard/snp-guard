IMAGE             ?= vm-data/sevsnptest.qcow2
SNP_DIR           ?= snp-release

BUILD_DIR         ?= $(shell realpath build)

HEADERS_DEB       ?= $(SNP_DIR)/linux/guest/linux-headers-*.deb
KERNEL_DEB        ?= $(SNP_DIR)/linux/guest/linux-image-*.deb

KERNEL_DIR        ?= $(BUILD_DIR)/kernel
KERNEL            ?= $(KERNEL_DIR)/boot/vmlinuz-*
INITRD            ?= $(BUILD_DIR)/initramfs.cpio.gz
KERNEL_CMDLINE    ?= console=ttyS0 earlyprintk=serial root=/dev/sda1

IMAGE_PATH         = $(shell realpath $(IMAGE))
KERNEL_PATH        = $(shell realpath $(KERNEL))
INITRD_PATH        = $(shell realpath $(INITRD))

INITRD_ORIG       ?= $(KERNEL_DIR)/initrd.img-*
INIT_SCRIPT       ?= init.sh

VERITY_HASH_TREE ?= $(BUILD_DIR)/verity/hash_tree
VERITY_ROOT_HASH ?= $(BUILD_DIR)/verity/roothash.txt
VERITY_PARAMS    ?= boot=verity verity_disk=/dev/sdb verity_roothash=$(shell cat $(VERITY_ROOT_HASH))


run:
	cd $(SNP_DIR) && sudo ./launch-qemu.sh -hda $(IMAGE_PATH) -default-network

run_sev_snp:
	cd $(SNP_DIR) && sudo ./launch-qemu.sh -hda $(IMAGE_PATH) -sev-snp -default-network

run_sev_snp_direct_boot:
	cd $(SNP_DIR) && sudo ./launch-qemu.sh -hda $(IMAGE_PATH) -sev-snp -default-network -kernel $(KERNEL_PATH) -initrd $(INITRD_PATH) -append "$(KERNEL_CMDLINE)"

run_sev_snp_verity:
	cd $(SNP_DIR) && sudo ./launch-qemu.sh -hda $(IMAGE_PATH) -hdb $(VERITY_HASH_TREE) -sev-snp -default-network -kernel $(KERNEL_PATH) -initrd $(INITRD_PATH) -append "$(KERNEL_CMDLINE) $(VERITY_PARAMS)"

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

setup_verity:
	mkdir -p $(BUILD_DIR)/verity
	./convert-vm/setup_verity.sh -image $(IMAGE) -fs-id 1 -out-hash-tree $(VERITY_HASH_TREE) -out-root-hash $(VERITY_ROOT_HASH)

init_dir:
	mkdir -p $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)/bin

clean:
	rm -rf $(BUILD_DIR)