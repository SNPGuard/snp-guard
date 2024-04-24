IMAGE             ?= vm-data/sevsnptest.qcow2
RUN_FOLDER        ?= snp-release

BUILD_DIR         ?= $(shell realpath build)

KERNEL_DIR        ?= $(BUILD_DIR)/kernel
KERNEL            ?= $(KERNEL_DIR)/vmlinuz-*
INITRD            ?= $(KERNEL_DIR)/initrd.img-*
KERNEL_CMDLINE    ?= "console=ttyS0 earlyprintk=serial root=/dev/sda1"

IMAGE_PATH         = $(shell realpath $(IMAGE))
KERNEL_PATH        = $(shell realpath $(KERNEL))
INITRD_PATH        = $(shell realpath $(INITRD))

CUSTOM_INITRD     ?= $(BUILD_DIR)/initramfs.cpio.gz
INIT_SCRIPT       ?= init.sh

run:
	cd $(RUN_FOLDER) && sudo ./launch-qemu.sh -hda $(IMAGE_PATH) -default-network

run_sev_snp:
	cd $(RUN_FOLDER) && sudo ./launch-qemu.sh -hda $(IMAGE_PATH) -sev-snp -default-network

run_sev_snp_direct_boot:
	cd $(RUN_FOLDER) && sudo ./launch-qemu.sh -hda $(IMAGE_PATH) -sev-snp -default-network -kernel $(KERNEL_PATH) -initrd $(INITRD_PATH) -append $(KERNEL_CMDLINE)

initramfs:
	./scripts/build-initramfs.sh -initrd $(INITRD_PATH) -kernel-dir $(KERNEL_DIR) -init $(INIT_SCRIPT)

initramfs_docker:
	./scripts/build-initramfs-docker.sh -kernel-dir $(KERNEL_DIR) -init $(INIT_SCRIPT)