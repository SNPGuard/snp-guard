
CFLAGS= -O3 -std=gnu11 -Wall -Wextra  -Werror

OBJ_DIR = ./build/obj
BIN_DIR = ./build/binaries
LIB_DIR = ./build/libs
TMP_DIR = ./build/tmp

INCS = $(wildcard *.h $(foreach fd, $(SUBDIR), $(fd)/*.h))
SRCS = $(wildcard *.c $(foreach fd, $(SUBDIR), $(fd)/*.c))

INCLUDES = 


#folder containing the files for the rootfs
#declared here because we need it in several make targets
ROOTFS_DIR= $(BIN_DIR)/nano-vm-rootfs

#we need to copy some kernel modules to our initramfs. This gives us the path to the folder
#containing the modules. We could also copy all of them but this makes initramfs quite large
ifndef KERNEL_MODULES_DIR
$(error Please specify KERNEL_MODULES_DIR env var to point to the directly with the kernel modules for the kernel that you want to run)
endif

#Used to build the initramfs for different use cases
# - enc_disk_full_vm : unlock encrypted disk and switch root into the unlocked disk calling init
USE_CASE ?= enc_disk_full_vm
ifeq ($(USE_CASE),enc_disk_full_vm)
USE_CASE_VALID = 1
endif

ifndef USE_CASE_VALID
$(error Invalid value for USE_CASE)
endif

all: setup-dirs rootfs $(BIN_DIR)/initramfs.cpio.gz attestation-tools
.PHONY: clean setup-dirs rootfs deploy attestation-tools

#create output directores for build stuff
setup-dirs:
	mkdir -p $(OBJ_DIR)
	mkdir -p $(BIN_DIR)
	mkdir -p $(LIB_DIR)
	mkdir -p $(TMP_DIR)

#build all objects files
$(OBJ_DIR)/%.o: %.c $(INCS)
	gcc $(CFLAGS) $(INCLUDES) -o $@ -c $<

#Build the server for the VM image as well as the guest owner tools
attestation-tools:
	(cd attestation_server && cargo build)

#Build main content for the root filesystem that we use in the initramfs
rootfs:
	sudo rm -rf $(ROOTFS_DIR)
	mkdir -p $(ROOTFS_DIR)
	#Build image specified by dockerfile
	podman build . --tag nano-vm-rootfs --squash
	#Create container from image. Rm first to ensure that container does not exist yet
	#which might be the case if the previous make run failed
	podman rm -i tmp-nano-vm-rootfs
	podman create --name tmp-nano-vm-rootfs nano-vm-rootfs:latest
	#Export container to folder
	podman export tmp-nano-vm-rootfs | tar xpf - -C $(ROOTFS_DIR)
	#Remove the container
	podman rm tmp-nano-vm-rootfs

$(BIN_DIR)/initramfs.cpio.gz: rootfs  attestation-tools
	#Copy additional elements into rootfs dir
	cp ./init.sh $(ROOTFS_DIR)/init
	#Copy program that does the attestation with the guest owner
	cp ./attestation_server/target/debug/server $(ROOTFS_DIR)/server
	#copy kernel modules to initramfs. 
	cp -r ./vm-kernel/lib/modules $(ROOTFS_DIR)/usr/lib/
ifdef ROOTFS_EXTRA_FILES
	#copy additional user defined files
	./copy-additional-deps.sh $(ROOTFS_DIR) "$(ROOTFS_EXTRA_FILES)"
endif
	#to run properly after startup, the files must be owned by root
	sudo chown -R root:root $(ROOTFS_DIR)
	sudo chmod -R 777  $(ROOTFS_DIR)
	#Compress content of rootfs dir with initramdisk format
	(cd $(ROOTFS_DIR) ; find . -print0   | cpio --null -ov --format=newc 2>/dev/null |  pv | gzip -1 > ../$(@F))

deploy:
	./deploy.sh	

clean:
	rm -rf ./build
	(cd attestation_server && cargo clean)
