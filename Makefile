BUILD_DIR         ?= $(shell realpath build)
GUEST_DIR         ?= $(BUILD_DIR)/guest
SNP_DIR           ?= $(BUILD_DIR)/snp-release
BIN_DIR           ?= $(BUILD_DIR)/bin

IMAGE             ?= $(GUEST_DIR)/sevsnptest.qcow2
CLOUD_CONFIG      ?= $(GUEST_DIR)/config-blob.img

HEADERS_DEB       ?= $(SNP_DIR)/linux/guest/linux-headers-*.deb
KERNEL_DEB        ?= $(SNP_DIR)/linux/guest/linux-image-*.deb

OVMF              ?= $(BUILD_DIR)/snp-release/usr/local/share/qemu/DIRECT_BOOT_OVMF.fd
KERNEL_DIR        ?= $(BUILD_DIR)/kernel
KERNEL            ?= $(KERNEL_DIR)/boot/vmlinuz-*
INITRD            ?= $(BUILD_DIR)/initramfs.cpio.gz
ROOT              ?= /dev/sda
KERNEL_CMDLINE    ?= console=ttyS0 earlyprintk=serial root=$(ROOT)

MEMORY            ?= 4096
CPUS			  ?= 1
POLICY            ?= 0x30000

VM_HOST           ?= localhost
VM_PORT           ?= 2222
VM_USER           ?= ubuntu
SSH_HOSTS_FILE    ?= $(BUILD_DIR)/known_hosts

OVMF_PATH          = $(shell realpath $(OVMF))
IMAGE_PATH         = $(shell realpath $(IMAGE))
KERNEL_PATH        = $(shell realpath $(KERNEL))
INITRD_PATH        = $(shell realpath $(INITRD))

INITRD_ORIG       ?= $(KERNEL_DIR)/initrd.img-*
INIT_SCRIPT       ?= initramfs/init.sh

VERITY_IMAGE      ?= $(BUILD_DIR)/verity/image.qcow2
VERITY_HASH_TREE  ?= $(BUILD_DIR)/verity/hash_tree.bin
VERITY_ROOT_HASH  ?= $(BUILD_DIR)/verity/roothash.txt
VERITY_PARAMS     ?= boot=verity verity_disk=/dev/sdb verity_roothash=`cat $(VERITY_ROOT_HASH)`

LUKS_IMAGE        ?= $(BUILD_DIR)/luks/image.qcow2
LUKS_PARAMS       ?= boot=encrypted
LUKS_KEY          ?=

QEMU_LAUNCH_SCRIPT = ./launch.sh
QEMU_DEF_PARAMS    = -default-network -log $(BUILD_DIR)/stdout.log -mem $(MEMORY) -smp $(CPUS)
QEMU_EXTRA_PARAMS  = -bios $(OVMF) -policy $(POLICY)
QEMU_SNP_PARAMS    = -sev-snp
QEMU_KERNEL_PARAMS = -kernel $(KERNEL_PATH) -initrd $(INITRD_PATH) -append "$(KERNEL_CMDLINE)"

VM_CONF_PATH       = $(shell realpath ./tools/attestation_server/examples/vm-config.toml)
VM_CONF_TEMPLATE   = $(GUEST_DIR)/vm-config-template.toml
VM_CONFIG_FILE     = $(GUEST_DIR)/vm-config.toml
VM_CONFIG_PARAMS   = -ovmf $(OVMF_PATH) -kernel $(KERNEL_PATH) -initrd $(INITRD_PATH) -template $(VM_CONF_TEMPLATE) -cpus $(CPUS) -policy $(POLICY)

run:
	sudo -E $(QEMU_LAUNCH_SCRIPT) $(QEMU_DEF_PARAMS) $(QEMU_EXTRA_PARAMS) -hda $(IMAGE_PATH)

run_setup:
	sudo -E $(QEMU_LAUNCH_SCRIPT) $(QEMU_DEF_PARAMS) $(QEMU_EXTRA_PARAMS) -hda $(IMAGE_PATH) -hdb $(CLOUD_CONFIG)

run_sev_snp:
	sudo -E $(QEMU_LAUNCH_SCRIPT) $(QEMU_DEF_PARAMS) $(QEMU_EXTRA_PARAMS) $(QEMU_SNP_PARAMS) -hda $(IMAGE_PATH)

run_sev_snp_direct_boot:
	sudo -E $(QEMU_LAUNCH_SCRIPT) $(QEMU_DEF_PARAMS) $(QEMU_EXTRA_PARAMS) $(QEMU_SNP_PARAMS) $(QEMU_KERNEL_PARAMS) -hda $(IMAGE_PATH)

run_verity_workflow:
	./guest-vm/create-vm-config.sh $(VM_CONFIG_PARAMS) -cmdline "$(KERNEL_CMDLINE) $(VERITY_PARAMS)" -out $(VM_CONFIG_FILE)
	sudo -E $(QEMU_LAUNCH_SCRIPT) $(QEMU_DEF_PARAMS) $(QEMU_SNP_PARAMS) -hda $(VERITY_IMAGE) -hdb $(VERITY_HASH_TREE) -load-config $(VM_CONFIG_FILE)

run_luks_workflow:
	./guest-vm/create-vm-config.sh $(VM_CONFIG_PARAMS) -cmdline "$(KERNEL_CMDLINE) $(LUKS_PARAMS)" -out $(VM_CONFIG_FILE)
	sudo -E $(QEMU_LAUNCH_SCRIPT) $(QEMU_DEF_PARAMS) $(QEMU_SNP_PARAMS) -hda $(LUKS_IMAGE) -load-config $(VM_CONFIG_FILE)

install_dependencies:
	./prepare-snp-dependencies.sh

unpack_kernel: init_dir
	rm -rf $(KERNEL_DIR)
	dpkg -x $(KERNEL_DEB) $(KERNEL_DIR)

build_tools: init_dir build_attestation_server

build_attestation_server:
	cargo build --manifest-path=tools/attestation_server/Cargo.toml
	cp ./tools/attestation_server/target/debug/server $(BIN_DIR)
	cp ./tools/attestation_server/target/debug/client $(BIN_DIR)
	cp ./tools/attestation_server/target/debug/get_report $(BIN_DIR)
	cp ./tools/attestation_server/target/debug/idblock-generator $(BIN_DIR)
	cp ./tools/attestation_server/target/debug/sev-feature-info $(BIN_DIR)
	cp ./tools/attestation_server/target/debug/verify_report $(BIN_DIR)

initramfs_from_existing:
	./initramfs/build-initramfs.sh -initrd $(INITRD_ORIG) -kernel-dir $(KERNEL_DIR) -init $(INIT_SCRIPT) -out $(INITRD)

initramfs:
	./initramfs/build-initramfs-docker.sh -kernel-dir $(KERNEL_DIR) -init $(INIT_SCRIPT) -out $(INITRD)

create_new_vm:
	./guest-vm/create-new-vm.sh -image-name sevsnptest.qcow2 -build-dir $(GUEST_DIR)

setup_verity:
	mkdir -p $(BUILD_DIR)/verity
	./guest-vm/setup_verity.sh -image $(IMAGE) -out-image $(VERITY_IMAGE) -out-hash-tree $(VERITY_HASH_TREE) -out-root-hash $(VERITY_ROOT_HASH)

setup_luks:
	mkdir -p $(BUILD_DIR)/luks
	./guest-vm/setup_luks.sh -in $(IMAGE) -out $(LUKS_IMAGE)

fetch_vm_config_template:
	cp $(VM_CONF_PATH) $(VM_CONF_TEMPLATE)

attest_luks_vm:
	$(BIN_DIR)/client --disk-key $(LUKS_KEY) --vm-definition $(VM_CONFIG_FILE) --dump-report $(BUILD_DIR)/luks/attestation_report.json
	rm -rf $(SSH_HOSTS_FILE)

attest_verity_vm:
	./attestation/attest-verity.sh -vm-config $(VM_CONFIG_FILE) -host $(VM_HOST) -port $(VM_PORT) -user $(VM_USER)

ssh:
	ssh -p $(VM_PORT) -o UserKnownHostsFile=$(SSH_HOSTS_FILE) $(VM_USER)@$(VM_HOST)

init_dir:
	mkdir -p $(BUILD_DIR)
	mkdir -p $(BIN_DIR)
	mkdir -p $(GUEST_DIR)

clean:
	rm -rf $(BUILD_DIR)

.PHONY: *