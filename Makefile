BUILD_DIR         ?= $(shell realpath build)
GUEST_DIR         ?= $(BUILD_DIR)/guest
SNP_DIR           ?= $(BUILD_DIR)/snp-release

IMAGE             ?= $(GUEST_DIR)/sevsnptest.qcow2
CLOUD_CONFIG      ?= $(GUEST_DIR)/config-blob.img

HEADERS_DEB       ?= $(SNP_DIR)/linux/guest/linux-headers-*.deb
KERNEL_DEB        ?= $(SNP_DIR)/linux/guest/linux-image-*.deb

VM_CONF_TEMPLATE  ?= $(shell realpath ./tools/attestation_server/examples/vm-config.toml)

#These config values are only used by the demo/debug targets ()
#The luks and verity targets pick their config value from the toml VM config file. This file is used by both the launch script and the 
#tools that checks the attestation report. This ways, we want to avoid missmatches due to config missmatches
OVMF              ?= $(BUILD_DIR)/snp-release/usr/local/share/qemu/DIRECT_BOOT_OVMF.fd
POLICY            ?= 0x30000
LOAD_CONFIG       ?= $(BUILD_DIR)/vm-config.toml
KERNEL_DIR        ?= $(BUILD_DIR)/kernel
KERNEL            ?= $(KERNEL_DIR)/boot/vmlinuz-*
INITRD            ?= $(BUILD_DIR)/initramfs.cpio.gz
ROOT              ?= /dev/sda
KERNEL_CMDLINE    ?= console=ttyS0 earlyprintk=serial root=$(ROOT)
MEMORY            ?= 2048

OVMF_PATH          = $(shell realpath $(OVMF))
IMAGE_PATH         = $(shell realpath $(IMAGE))
KERNEL_PATH        = $(shell realpath $(KERNEL))
INITRD_PATH        = $(shell realpath $(INITRD))

INITRD_ORIG       ?= $(KERNEL_DIR)/initrd.img-*
INIT_SCRIPT       ?= initramfs/init.sh

VERITY_IMAGE      ?= $(BUILD_DIR)/verity/image.qcow2
VERITY_HASH_TREE  ?= $(BUILD_DIR)/verity/hash_tree.bin
VERITY_ROOT_HASH  ?= $(BUILD_DIR)/verity/roothash.txt
VERITY_VM_CONFIG  ?= $(BUILD_DIR)/verity/vm-config-verity.toml
VERITY_PARAMS     ?= boot=verity verity_disk=/dev/sdb

LUKS_IMAGE        ?= $(BUILD_DIR)/luks/image.qcow2
LUKS_VM_CONFIG    ?= $(BUILD_DIR)/luks/vm-config-LUKS.toml
LUKS_PARAMS       ?= boot=encrypted

INTEGRITY_IMAGE     ?= $(BUILD_DIR)/integrity/image.qcow2
INTEGRITY_KEY       ?= $(BUILD_DIR)/integrity/dummy.key
INTEGRITY_VM_CONFIG ?= $(BUILD_DIR)/integrity/vm-config-integrity.toml
INTEGRITY_PARAMS    ?= boot=integrity

QEMU_LAUNCH_SCRIPT = ./launch.sh
QEMU_DEF_PARAMS    = -default-network -log $(BUILD_DIR)/stdout.log -mem $(MEMORY)
QEMU_EXTRA_PARAMS  = -bios $(OVMF) -policy $(POLICY)
QEMU_SNP_PARAMS    = -sev-snp
QEMU_KERNEL_PARAMS = -append "$(KERNEL_CMDLINE)"

run:
	sudo -E $(QEMU_LAUNCH_SCRIPT) $(QEMU_DEF_PARAMS) $(QEMU_EXTRA_PARAMS) -hda $(IMAGE_PATH)

run_setup:
	sudo -E $(QEMU_LAUNCH_SCRIPT) $(QEMU_DEF_PARAMS) $(QEMU_EXTRA_PARAMS) -hda $(IMAGE_PATH) -hdb $(CLOUD_CONFIG)

run_sev_snp:
	sudo -E $(QEMU_LAUNCH_SCRIPT) $(QEMU_DEF_PARAMS) $(QEMU_EXTRA_PARAMS) $(QEMU_SNP_PARAMS) -hda $(IMAGE_PATH)

run_sev_snp_direct_boot:
	sudo -E $(QEMU_LAUNCH_SCRIPT) $(QEMU_DEF_PARAMS) $(QEMU_SNP_PARAMS) $(QEMU_KERNEL_PARAMS) -hda $(IMAGE_PATH) -load-config $(LOAD_CONFIG)

run_sev_snp_verity:
	sudo -E $(QEMU_LAUNCH_SCRIPT) $(QEMU_DEF_PARAMS) $(QEMU_SNP_PARAMS) -hda $(VERITY_IMAGE) -hdb $(VERITY_HASH_TREE) -load-config $(VERITY_VM_CONFIG)

run_sev_snp_luks:
	sudo -E $(QEMU_LAUNCH_SCRIPT) $(QEMU_DEF_PARAMS) $(QEMU_SNP_PARAMS) -hda $(LUKS_IMAGE) -load-config $(LUKS_VM_CONFIG)

install_dependencies:
	./prepare-snp-dependencies.sh

unpack_kernel: init_dir
	dpkg -x $(KERNEL_DEB) $(KERNEL_DIR)

build_tools: init_dir build_attestation_server

build_attestation_server:
	cargo build --manifest-path=tools/attestation_server/Cargo.toml
	cp ./tools/attestation_server/target/debug/server $(BUILD_DIR)/bin
	cp ./tools/attestation_server/target/debug/client $(BUILD_DIR)/client
	cp ./tools/attestation_server/target/debug/get_report $(BUILD_DIR)/get_report
	cp ./tools/attestation_server/target/debug/idblock-generator $(BUILD_DIR)/idblock-generator
	cp ./tools/attestation_server/target/debug/sev-feature-info $(BUILD_DIR)/sev-feature-info
	cp ./tools/attestation_server/target/debug/verify_report $(BUILD_DIR)/verify_report

initramfs_from_existing:
	./initramfs/build-initramfs.sh -initrd $(INITRD_ORIG) -kernel-dir $(KERNEL_DIR) -init $(INIT_SCRIPT) -out $(INITRD)

initramfs:
	./initramfs/build-initramfs-docker.sh -kernel-dir $(KERNEL_DIR) -init $(INIT_SCRIPT) -out $(INITRD)

create_new_vm:
	./guest-vm/create-new-vm.sh -image-name sevsnptest.qcow2 -build-dir $(GUEST_DIR)

setup_verity:
	mkdir -p $(BUILD_DIR)/verity
	./guest-vm/setup_verity.sh -image $(IMAGE) -out-image $(VERITY_IMAGE) -out-hash-tree $(VERITY_HASH_TREE) -out-root-hash $(VERITY_ROOT_HASH)
	./guest-vm/create-vm-config.sh -ovmf $(OVMF_PATH) -kernel $(KERNEL_PATH) -initrd $(INITRD_PATH) -template $(VM_CONF_TEMPLATE) -cmdline "$(KERNEL_CMDLINE) $(VERITY_PARAMS) verity_roothash=$(shell cat $(VERITY_ROOT_HASH))" -out $(VERITY_VM_CONFIG)

setup_luks:
	mkdir -p $(BUILD_DIR)/luks
	./guest-vm/setup_luks.sh -in $(IMAGE) -out $(LUKS_IMAGE)
	./guest-vm/create-vm-config.sh -ovmf $(OVMF_PATH) -kernel $(KERNEL_PATH) -initrd $(INITRD_PATH) -template $(VM_CONF_TEMPLATE) -cmdline "$(KERNEL_CMDLINE) $(LUKS_PARAMS)" -out $(LUKS_VM_CONFIG)

setup_integrity:
	mkdir -p $(BUILD_DIR)/integrity
	echo test > $(BUILD_DIR)/integrity/dummy.key
	./guest-vm/setup_integrity.sh -in $(IMAGE) -out $(INTEGRITY_IMAGE) -key $(INTEGRITY_KEY)
	./guest-vm/create-vm-config.sh -ovmf $(OVMF_PATH) -kernel $(KERNEL_PATH) -initrd $(INITRD_PATH) -template $(VM_CONF_TEMPLATE) -cmdline "$(KERNEL_CMDLINE) $(INTEGRITY_PARAMS)" -out $(INTEGRITY_VM_CONFIG)

attest_luks_vm:
	$(BUILD_DIR)/client --disk-key $(LUKS_KEY) --vm-definition $(LUKS_VM_CONFIG) --dump-report $(BUILD_DIR)/luks/attestation_report.json

init_dir:
	mkdir -p $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)/bin

clean:
	rm -rf $(BUILD_DIR)

.PHONY: *