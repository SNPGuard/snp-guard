# openend2e-sevsnp

This repository demonstrates an end-to-end secured setup for a SEV-SNP VM. To
achieve this, we build on the ideas from [2] and use the attestation process of
SEV-SNP in combination with software tools like full authenticated disk
encryption to provide a secure SEV setup. While the official AMD repo [1]
explains how to set up a SEV-SNP VM, it does not cover these topics at all.

Currently, this repo is mainly intended as a technical demo and NOT intended to
be used in any kind of production scenario.

We explicitly decided to boot into a feature rich initramfs to enable easy
tweaking of the boot process to explore novel ideas.

The workflow consists of four different steps:

1. [Install dependencies](#install-dependencies)
2. [Build packages](#build-packages)
3. [Prepare host](#prepare-host)
4. [Prepare guest](#prepare-guest)
5. [Run](#run)

Note: the guide below is intended for users running a Debian-based Linux
distribution such as Ubuntu or Debian. If you are using a different distribution
most of our scripts likely will not work out of the box but will require some
adaptation.

## Install dependencies

TODO: write separate script? Move stuff from prepare-snp-dependencies.sh, skip packages if already installed

```bash
# Install dependencies from APT
# TODO: others
sudo apt update && sudo apt install make

# Install Docker using convenience script
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh ./get-docker.sh --dry-run
```

## Build packages

The first step consists of building customized versions of QEMU, OVMF and Linux
kernel (both for host and guest) that have SNP-enabled capabilities. This is
done by following the [AMD
manual](https://github.com/AMDESE/AMDSEV/tree/snp-latest).

In this repository, we provide pre-built binaries and convenience scripts to
automate the process. Below, we give three different options, from the most
automated (and quickest) to the most manual (and slowest) way.

### Option 1: Download pre-built packages

We provide pre-built packages as releases in our repository. Such packages have
been built using our Option 2 below.

```bash
# Download archive from our Github repository
wget https://github.com/its-luca/open-e2e-sevsnp-workflow/releases/download/untagged-efba89178443f35b50f9/snp-release.tar.gz

# unpack archive
tar -xf snp-release.tar.gz
```

### Option 2: Build with Docker

Here, we create a Docker image that contains all the required dependencies, and
then we run a container in detached mode that builds the actual QEMU, OVMF, and
kernel packages. The container will run in the background, allowing you to close
the current shell and wait until the packages have been built. When the
container has finished, we fetch the packages and extract the TAR archive.

```bash
# go to the `snp-builder` folder
cd snp-builder

# Build docker image containing all dependencies
make image

# Run container in the background (it can take several hours to complete)
make build

# Fetch archive from the container
# note: you should wait until the container has exited successfully. Otherwise, this command will fail
make get_files

# (optional) remove container
make clean

# go back to the root dir
cd ..

# unpack archive
tar -xf snp-release.tar.gz
```

### Option 3: Build locally

We wrote a convenience script that installs all build dependencies and builds
the required packages. Note that building the linux kernel may take several
hours. 

```bash
# Run build script
# TODO: use screen session to run in background
./scripts/local-build.sh
```

## Prepare host

Make sure that your host is fully configured to run SNP-enabled guests. Follow
the [official
guide](https://github.com/AMDESE/AMDSEV/tree/snp-latest?tab=readme-ov-file#prepare-host) to prepare the host correctly.

Note: if you followed the [build](#build-packages) guide above, the `install.sh`
script to install the host kernel is available under `./snp-release/`:

```bash
cd snp-release
./install.sh
```

## Prepare guest

TODO: automated script/makefile with option for integrity vs encryption

## Run

TODO: automated script/makefile with option for integrity vs encryption

## TLDR
Assuming you are using Ubuntu

### Build

1) Build and install all depdendencies with `./prepare-snp-dependencies.sh`
2) Follow the [AMD manual](https://github.com/AMDESE/AMDSEV/tree/snp-latest) to configure your system for SEV-SNP. Skip the "Build" step as we already performed this in step 1
3) Compile our tool with `source build.env && make`
4) (Optional) If you don't have an existing VM image, follow [Create new VM image](#optional-create-new-vm-image) to create one
5) Convert your VM to use an encrypted disk with the `./convert-vm/setup_luks.sh -in <your disk .qcow2>`  conversion script. Check [the long version](#run-1) for the other workflows.

### Run
1) `source build.env`
2) `sudo -E ./openend2e-launch.sh -sev-snp -load-config .default-vm-config.toml -hda <your disk .qcow2>`
3) Wait a few seconds, then `./attestation_server/target/debug/client --disk-key <disk encryption pw> --vm-definition default-vm-config.toml`
4) Wait a few seconds, then SSH into your VM on port 2222 on localhost

To terminate QEMU, use Ctrl+A, Ctrl+]
Per default, the VM will not generate any output after the UEFI stage.
This is because interacting via the serial console transfers data unenrypted and opens an attack angle for the hypervisor.
If you want output for debug purposes, edit `default-vm-config.toml` and change `kernel_cmdline = ""` to `kernel_cmdline = "console=ttyS0"` 

## High Level Workflow
Our solution consists of two stages.

The first stage consists of a small, publicly known code image that does not
contain any secrets. 
The second stage contains the workload that the user wants to execute.
Depending on the use case the second stage is either only integrity protected using dm-verity or uses
full authenticated disk encryption using dm-crypt.
The latter enables you to easily use a regular Linux VM, for the second stage.

We create and boot a new VM, using the small first stage code image and use the SEV-SNP isolation and attestation features to ensure its integrity.
If the second stage is only integrity protected, the boot process can resume uninterrupted and the VM owner perform the remote attestation at any time after boot up.
We use *switch_root* to hand over control from the first to the second stage, calling the `/sbin/init` in the second stage as the entry point.
If the second stage is encrypted, the first stage proves its authenticity to the VM
owner, using remote attestation. Afterwards, the VM owner can build an encrypted
channel to send secrets into the VM.
We use this to transmit the disk encryption key required to unlock the disk image
for the second stage.
After receiving the key, the first stage unlocks and mounts the encrypted disk before using the *switch_root* approach to hand over control.

### Limitations and Caveats
Any changes of the second stage Linux VM to its /boot partition are not reflected upon
reboot since we directly specify boot the kernel image and int initramfs via QEMU flags.
In fact, we don't even bother to mount the original /boot partition.

This could be resolved by using something like Grub for the first stage. This would allow
us to boot into the second stage using the initramfs and the kernel specified
on the /boot partition. (In this scenario we would also need to encrypt /boot to prevent the hypervisor
from manipulating it). In addition, this would also completely decouple the content of the encrypted VM image
from the launch digest, making it easier to verify the launch digest.
Implementing this is on our roadmap for a future release. The main disadvantage of this approach is that 
the limited Grub programming environment from Grub makes it much harder to add experimental tweaks to the
boot process.


## Build
This is the "long version" of the build process

### Prepare for SEV-SNP
1) Build and instal all depdendencies with `./prepare-snp-dependencies.sh`
2) Follow the [AMD manual](https://github.com/AMDESE/AMDSEV/tree/snp-latest) to configure your sytem for SEV-SNP. Skip the "Build" step as we already performed this in step 1


### First Stage Code Image
For the first stage, we require the OVMF UEFI implementation, a Linux kernel and a custom initramfs.

1) Extract the content of the guest kernel *deb* package from the `linux` subfolder in the AMD repo into a separate folder using `dpkg -x <path to .deb> <path to folder>`. You can of course also use any other kernel that can run a SEV-SNP guest. Let `GUEST_DEB_CONTENT` be that folder.
2) Run `KERNEL_MODULES_DIR=$GUEST_DEB_CONTENT make` to build the initramfs and the binaries used in the attestation process. This script requires
root privileges to change the file ownership of the files in the initramfs to root.
If you want to copy any additional files to the initramfs, you may set the `ROOTFS_EXTRA_FILES` env var to a whitespace separated list of files. The initramfs is placed in `./build/binaries/`. The binaries for the attestation process are in
`./attestation_server/target/debug/`

### Second Stage Code Image

#### Optional: Create new VM image
In this section we create a new ubuntu VM image, using the cloud image provided by ubuntu as well the cloud-init tool to automate the deployment

1) `mkdir -p vm-data &&  ./create-vm-scripts/create-new-vm.sh -out-vm-image ./vm-data/sevsnptest.qcow2`  to create a new disk with an uncofigured ubuntu as well as a cloud-init config blob. See "-help" for optional paramters
3) To apply the configuration, you need to boot the VM once using `sudo -E ./openend2e-launch.sh -hda ./vm-data/sevsnptest.qcow2 -hdb ./vm-data/config-blob.img -append console=ttyS0`. Check that you can login with the user and password that you configured. The config is applied permanently to the image, i.e. you can use the image standalone afterwards.

#### Optional Generate an ID Block and an ID Auth block
The ID block and an ID authentication information structure allow you to pass some user defined data to describe/identify the
VM, as well as the public parts of the ID key and the author key. All of this information will be reflected
in the attestation report. In addition, the ID block will trigger a check of the launch digest and the guest policy before entering the VM.
Otherwise, both would only be checked at runtime, during the attestation handshake described later in this document.

Use the following command to generate an ID block and id auth block files for usage with QEMU:
`./attestation_server/target/debug/idblock-generator --vm-definition vm-config.toml --id-key-path id_key.pem --auth-key-path author_key.pem`

Both ID key and author key are user defined keys. The ID key is used to sign the ID block and the author key is used to sign the ID key.
This enables you to use a different ID key for each VM while reflecting that all VMs belong to the same VM owner/author.
Bot keys need to be in the PKCS8 PEM format. You can generate them with
`openssl ecparam -name secp384r1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out private_key.pem`
The second part is needed as there are two sub variants for PEM and the default one used
by OpenSSL cannot be parsed by the library that we used (apparently the PKCS8 one is also the
better variant).


#### Integrity+Encryption Workflow
Use `./convert-vm/setup_luks.sh -in ./vm-data/sevsnptest.qcow2` to convert the disk image
to an encrypted disk image

#### Integrity-only Workflow
TODO

## Run
To use the `openend2e-launch.sh` script in the following steps, set the 
`SEV_TOOLCHAIN_PATH ` env var to point to the `usr/local` sub folder of the official AMD repo.
If you used the `./prepare-snp-dependencies.sh` script, use `source build.env` to use the autogenerated env file.

The script will forward the ports 22 and 80 from the VM to localhost:2222 and localhost:8080 on the host system. The server for the attestation is listening
on port 80 inside the VM. If you want to perform the remote attestation from a different machine edit the following line in `openend2e-launch.sh` to forward port 80 to a remotely reachable IP of you choice.
`add_opts " -netdev user,id=vmnic,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8080-:80"` 

Use the following command to start the VM
`sudo -E ./openend2e-launch.sh -sev-snp -load-config default-vm-config.toml -hda <your disk .qcow2>`
If you want to use the optional ID block, also add the following parameters
`-id-block <path to id-block.base64> -id-auth <path to auth-block.base64>`

Wait until the scrolling text stops.

Next, on the same system as the VM is running, use the following command to perform the attestation process
`./attestation_server/target/debug/client --disk-key <disk encryption pw> --vm-definition <vm config file>`
If you used the ID block during launch, you might also add the `--id-block-path <path to id-block.base64>` and `--author-block-path <path to auth-block.base64>` parameters, to verify the information from these blocks that are visible in the attestation report.
See `--help` for additional optional parameters. 
If the remote attestation succeeds, you should be able to SSH into your VM
on localhost port 2222 shorty afterwards.

## References
- [1] https://github.com/AMDESE/AMDSEV/tree/snp-latest
- [2] https://www.youtube.com/watch?v=4wZnl0njxm8
