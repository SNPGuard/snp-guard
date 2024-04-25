BUILD_DIR         ?= $(shell realpath build)
GUEST_DIR         ?= $(BUILD_DIR)/guest
SNP_DIR           ?= $(BUILD_DIR)/snp-release

IMAGE             ?= $(GUEST_DIR)/sevsnptest.qcow2
CLOUD_CONFIG      ?= $(GUEST_DIR)/config-blob.img

HEADERS_DEB       ?= $(SNP_DIR)/linux/guest/linux-headers-*.deb
KERNEL_DEB        ?= $(SNP_DIR)/linux/guest/linux-image-*.deb

OVMF              ?= $(BUILD_DIR)/snp-release/usr/local/share/qemu/DIRECT_BOOT_OVMF.fd
LOAD_CONFIG       ?= $(BUILD_DIR)/vm-config.toml
KERNEL_DIR        ?= $(BUILD_DIR)/kernel
KERNEL            ?= $(KERNEL_DIR)/boot/vmlinuz-*
INITRD            ?= $(BUILD_DIR)/initramfs.cpio.gz
ROOT              ?= /dev/sda
KERNEL_CMDLINE    ?= console=ttyS0 earlyprintk=serial root=$(ROOT)

OVMF_PATH          = $(shell realpath $(OVMF))
IMAGE_PATH         = $(shell realpath $(IMAGE))
KERNEL_PATH        = $(shell realpath $(KERNEL))
INITRD_PATH        = $(shell realpath $(INITRD))

INITRD_ORIG       ?= $(KERNEL_DIR)/initrd.img-*
INIT_SCRIPT       ?= initramfs/init.sh

VERITY_IMAGE      ?= $(BUILD_DIR)/verity/image.qcow2
VERITY_HASH_TREE  ?= $(BUILD_DIR)/verity/hash_tree.bin
VERITY_ROOT_HASH  ?= $(BUILD_DIR)/verity/roothash.txt
VERITY_PARAMS     ?= boot=verity verity_disk=/dev/sdb verity_roothash=$(shell cat $(VERITY_ROOT_HASH))

run:
	cd $(SNP_DIR) && sudo ./launch-qemu.sh -hda $(IMAGE_PATH) -default-network

run_setup:
	cd $(SNP_DIR) && sudo ./launch-qemu.sh -hda $(IMAGE_PATH) -hdb $(CLOUD_CONFIG) -default-network

run_sev_snp:
	cd $(SNP_DIR) && sudo ./launch-qemu.sh -hda $(IMAGE_PATH) -sev-snp -default-network

run_sev_snp_direct_boot:
	cd $(SNP_DIR) && sudo ./launch-qemu.sh -hda $(IMAGE_PATH) -sev-snp -default-network -kernel $(KERNEL_PATH) -initrd $(INITRD_PATH) -append "$(KERNEL_CMDLINE)"

run_sev_snp_verity:
	cd $(SNP_DIR) && sudo ./launch-qemu.sh -hda $(VERITY_IMAGE) -hdb $(VERITY_HASH_TREE) -sev-snp -default-network -kernel $(KERNEL_PATH) -initrd $(INITRD_PATH) -append "$(KERNEL_CMDLINE) $(VERITY_PARAMS)"

install_dependencies:
	./prepare-snp-dependencies.sh

unpack_kernel: init_dir
	dpkg -x $(KERNEL_DEB) $(KERNEL_DIR)

build_tools: build_attestation_server

build_attestation_server:
	cargo build --manifest-path=tools/attestation_server/Cargo.toml
	cp ./tools/attestation_server/target/debug/server $(BUILD_DIR)/bin

initramfs_from_existing:
	./initramfs/build-initramfs.sh -initrd $(INITRD_ORIG) -kernel-dir $(KERNEL_DIR) -init $(INIT_SCRIPT) -out $(INITRD)

initramfs:
	./initramfs/build-initramfs-docker.sh -kernel-dir $(KERNEL_DIR) -init $(INIT_SCRIPT) -out $(INITRD)

create_new_vm:
	./guest-vm/create-new-vm.sh -image-name sevsnptest.qcow2 -build-dir $(GUEST_DIR)

setup_verity:
	mkdir -p $(BUILD_DIR)/verity
	./guest-vm/setup_verity.sh -image $(IMAGE) -fs-id 1 -out-image $(VERITY_IMAGE) -out-hash-tree $(VERITY_HASH_TREE) -out-root-hash $(VERITY_ROOT_HASH)

init_dir:
	mkdir -p $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)/bin

clean:
	rm -rf $(BUILD_DIR)

.PHONY: *