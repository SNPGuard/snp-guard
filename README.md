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

The workflow consists of five different stages:

1. [Install dependencies](#install-dependencies)
2. [Build packages](#build-packages)
3. [Prepare host](#prepare-host)
4. [Prepare guest](#prepare-guest)
5. Run: [integrity](#run-integrity-only-workflow) and
   [encrypted](#run-encrypted-workflow) workflows

The first three steps are supposed to be done only once, unless you wish to
install updated versions of the SNP tools and packages. Except for preparing the
host and running VMs, the other steps do not need to be executed on a SNP
machine.

Note: the guide below is intended for users running a Debian-based Linux
distribution such as Ubuntu or Debian. If you are using a different distribution
most of our scripts likely will not work out of the box but will require some
adaptation.

## Install dependencies

TODO: write separate script? Move stuff from prepare-snp-dependencies.sh, skip packages if already installed

```bash
# Install dependencies from APT
sudo apt update && sudo apt install make whois pv

# Install Docker using convenience script
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh ./get-docker.sh --dry-run

# Install Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
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
# create and move to build directory
mkdir -p build && cd build

# Download archive from our Github repository
# TODO: update link
wget <link> 

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

# go to the build dir
cd ../build

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
./snp-builder/build-packages.sh
```

## Prepare host

### Step 0: SEV firmware

SEV-SNP requires firmware version >= 1.51:1. To check which version of the
firmware is installed, you can use the
[snphost](https://github.com/virtee/snphost) utility, as shown below:

```bash
# check current fw version (note: you may need to run as root)
snphost show version
```

To update your firmware, [check
this
guide](https://github.com/AMDESE/AMDSEV/tree/snp-latest#upgrade-sev-firmware).

### Step 1: BIOS settings

Some BIOS settings are required in order to use SEV-SNP. The settings slightly
differ, but make sure to check the following:
- `Secure Nested Paging`: to enable SNP
- `Secure Memory Encryption`: to enable SME (not required for running SNP guests)
- `SNP Memory Coverage`: needs to be enabled to reserve space for the Reverse
  Map Page Table (RMP). [Source](https://github.com/AMDESE/AMDSEV/issues/68)
- `Minimum SEV non-ES ASID`: this option configures the minimum address space ID
  used for non-ES SEV guests. By setting this value to 1 you are allocating all
  ASIDs for normal SEV guests and it would not be possible to enable SEV-ES and
  SEV-SNP. So, this value should be greater than 1.


### Step 2: Install host kernel

Note: if you followed the [build](#build-packages) guide above, the `install.sh`
script to install the host kernel is available under `./build/snp-release/`:

```bash
cd build/snp-release
sudo ./install.sh

# Reboot machine and choose the SNP host kernel from the GRUB menu
```

### Step 3: Ensure that kernel options are correct

- Make sure that IOMMU is enabled and **not** in passthrough mode, otherwise
  SEV-SNP will not work. Ensure that the iommu flag is set to `iommu=nopt` under
  `GRUB_CMDLINE_LINUX_DEFAULT`.
  [Source](https://github.com/AMDESE/AMDSEV/issues/88)
    - Check both `/etc/default/grub` and `/etc/default/grub.d/rbu-kernel.cfg`
    - If needed (i.e., if SEV-SNP doesn't work) set also `iommu.passthrough=0`

- With recent SNP-enabled kernels, KVM flags should be already set correctly.
  For earlier versions, you may need to set the following flags in
  `/etc/default/grub`:
    - `kvm_amd.sev=1`
    - `kvm_amd.sev-es=1` 
    - `kvm_amd.sev-snp=1`

- SME should not be required to run SEV-SNP guests. In any case, to enable it
  you should set the following flag: `mem_encrypt=on`.

- The changes above should be applied with `sudo update grub` and then a reboot.

### Step 4: Check if everything is set up correctly on the host

Note: outputs may slightly differ.

```bash
# Check kernel version
uname -r
# 6.5.0-rc2-snp-host-ad9c0bf475ec

# Check if SEV is among the CPU flags
grep -w sev /proc/cpuinfo
# flags           : ...
# flush_l1d sme sev sev_es sev_snp

# Check if SEV, SEV-ES and SEV-SNP are available in KVM
cat /sys/module/kvm_amd/parameters/sev
# Y
cat /sys/module/kvm_amd/parameters/sev_es 
# Y
cat /sys/module/kvm_amd/parameters/sev_snp 
# Y

# Check if SEV is enabled in the kernel
sudo dmesg | grep -i -e rmp -e sev
# SEV-SNP: RMP table physical address 0x0000000035600000 - 0x0000000075bfffff
# ccp 0000:23:00.1: sev enabled
# ccp 0000:23:00.1: SEV-SNP API:1.51 build:1
# SEV supported: 410 ASIDs
# SEV-ES and SEV-SNP supported: 99 ASIDs
```

## Prepare guest 

TODO: Steps 1-2 should be generic enough to be used by either Step 3A or 3B. Do
not force the user to inject secrets at steps 1-2, so that they can be free to
use the integrity-only workflow if they wish to do so.

### Step 0: Unpack kernel

We first need to unpack the kernel obtained from the built packages. By default
the kernel package can be found under
`build/snp-release/linux/guest/linux-image-*.deb`. We unpack it to
`build/kernel`.

```bash
make unpack_kernel
```

### Step 1: Build custom initramfs

We need to build a customized initramfs (i.e., initial RAM disk) to configure
boot options at early userspace and enable our workflows.

We do this by leveraging Docker. In short, we run a `ubuntu` container and then
we export its filesystem on `build/initramfs/`. Afterwards, we make the
necessary adjustments to the filesystem, such as adding a `init` script,
removing unnecessary folders, and changing file permissions. Finally, we build
the initramfs archive using CPIO.

First, however, we build custom tools that are needed in initramfs, such as
`attestation_server`. All tools will be copied to the `build/bin` directory.

```bash
# Build custom tools
make build_tools

# Create initramfs
make initramfs
```

### Step 2: Prepare guest image

**Option A: use an existing image**

TODO: check if our workflows work with lvm2 (maybe need to patch init script)

**Option B: create a new image**

```bash
# create image
make create_new_vm

# run image for initial setup
make run_setup

# Copy kernel and headers to guest
scp -P 2222 build/snp-release/linux/guest/*.deb <username>@localhost:/home/<username>
```

**Guest configuration**

```bash
# install kernel and headers (copied before)
# This is needed, otherwise:
# - there is no sev-guest kernel module in the guest
# - somehow there is no connectivity (missing network interface, only lo is present)
sudo dpkg -i linux-*.deb

# disable multipath service (it causes some conflicts)
sudo systemctl disable multipathd.service

# disable EFI and swap partitions in /etc/fstab
# already done if a new VM was created using our script
```

## Run integrity-only workflow

### Step 1: Prepare dm-verity

```bash
# Create verity device
make setup_verity
```

### Step 2: Launch guest

```bash
# Create verity device
make run_sev_snp_verity
```

### Step 3: Verify guest integrity

## Run encrypted workflow

### Step 1: Prepare dm-crypt

### Step 2: Launch guest

### Step 3: Unlock encrypted filesystem

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
