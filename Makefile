
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



all: setup-dirs $(BIN_DIR)/init rootfs $(BIN_DIR)/initramfs.cpio.gz attestation-tools
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

#Build the init binary
$(BIN_DIR)/init: $(OBJ_DIR)/init.o
	gcc $(INCLUDES) $(LIBS) $(CFLAGS) -static -o $(BIN_DIR)/init $^

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

$(BIN_DIR)/initramfs.cpio.gz: rootfs $(BIN_DIR)/init attestation-tools
	#Copy additional elements into rootfs dir
	# cp $(BIN_DIR)/init $(ROOTFS_DIR)/init
	# cp ./switch_to_new_root.sh $(ROOTFS_DIR)/switch_to_new_root.sh
	cp ./init.sh $(ROOTFS_DIR)/init
	cp ./attestation_server/target/debug/server $(ROOTFS_DIR)/server
	./copy-additional-deps.sh $(ROOTFS_DIR) "$(ROOTFS_EXTRA_FILES)"
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
