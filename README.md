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

For building the SNP packages and preparing the guest we need to install some
basic dependencies such as Docker, Rust toolchain, and a few packages via `apt`.
The `install_dependencies` makefile target automates the whole process, at the
same time asking for user confirmation before proceeding with the installation.

```bash
make install_dependencies
```

## Build packages

The first build step consists of building customized versions of QEMU, OVMF and
Linux kernel (both for host and guest) that have SNP-enabled capabilities. This
is done by following the [AMD
manual](https://github.com/AMDESE/AMDSEV/tree/snp-latest).

In this repository, we provide pre-built binaries and convenience scripts to
automate the process. Below, we give three different options, from the most
automated (and quickest) to the most manual (and slowest) way.

### Option 1: Download pre-built packages
**TODO** @luca : Update this to the "use-stable-snapshots" version


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
**TODO** @gianluca : How do we integrate the "use-stable-snapshots" build here?

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
# You can set COMMIT_DATE to specify the date of the commits to check out
# By default, it is set to the value of "snp-builder/commit-date"
# You can set "today" to get the most recent commit
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
# Without -use-stable-snapshots, the script will use the AMD upstream repos. We found them to be quite
# unstable and thus created a stable snapshot
./snp-builder/build-packages.sh -use-stable-snapshots
tar xf AMDSEV/snp-release*.tar.gz && mv snp-release* snp-release && rm -f ./snp-release/linux-image*dbg*.deb
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

Note: if you wish to run our integrity-only workflow you should make sure to
delete *all secrets* from the guest VM (see
[below](#run-integrity-only-workflow)). SSH keys, instead, are regenerated
automatically.

TODO: check if our workflows work with lvm2 (maybe need to patch init script)

```bash
# Run VM for configuration
make run IMAGE=<your_image>

# Copy kernel and headers to guest
scp -P 2222 build/snp-release/linux/guest/*.deb <username>@localhost:/home/<username>

# from within the guest: check guest configuration below
```

**Option B: create a new image**

```bash
# create image (will be stored under build/guest/sevsnptest.qcow2)
make create_new_vm

# run image for initial setup
make run_setup

# Copy kernel and headers to guest
# note: if the guest does not have an IP address check below instructions
scp -P 2222 build/snp-release/linux/guest/*.deb <username>@localhost:

# from within the guest: check guest configuration below
```

**Guest configuration**

```bash
# Get an IP address if you do not have it already
sudo dhclient

# install kernel and headers (copied before)
# This is needed even when running direct boot, otherwise:
# - there is no sev-guest kernel module in the guest
# - somehow there is no connectivity (missing network interface, only lo is present)
sudo dpkg -i linux-*.deb

# remove kernel and headers to save space
rm -rf linux-*.deb

# disable multipath service (it causes some conflicts)
sudo systemctl disable multipathd.service

# disable EFI and swap partitions in /etc/fstab
# already done if a new VM was created using our script
sudo mv /etc/fstab /etc/fstab.bak
```

## Run integrity-only workflow

In this workflow, we create a read-only filesystem starting from an existing
image using `dm-verity`. Integrity protection is ensured by a Merkle hash tree,
passed as a separate disk, and a root hash passed as kernel command-line
argument. Only the root hash must be protected from tampering to preserve the
integrity of the root filesystem. In our workflow, since the kernel command line
is measured with SEV-SNP and Direct Linux Boot, the root hash is protected and
its value is reflected in the attestation report.

A read-only filesystem can give strong integrity guarantees but it is not very
practical, as in most cases a guest needs write permission to certain disk
locations. Moreover, as also mentioned in the [dm-verity
wiki](https://wiki.archlinux.org/title/Dm-verity), there may be boot and runtime
issues as some programs need to write to certain locations such as `/home` and
`/var`.

To solve these issues, we leverage [tmpfs](https://en.wikipedia.org/wiki/Tmpfs)
to mount certain directories in memory as read/write. Since guest memory is
encrypted and integrity-protected by AMD SEV-SNP, these directories can be read
and written safely, and can also hold secrets. The only downside is that these
directories are temporary and their content will be lost when the guest is shut
down. To store permanent state, it is possible to mount a secondary filesystem
to the guest to store permanent data, optionally encrypted/authenticated with a
guest key (e.g., a sealing key provided by the AMD SP).

The following folders will be mounted as read-write `tmpfs`:
- `/home` (max. 8GiB)
- `/var` (max. 2GiB)
- `/etc` (max. 1GiB)
- `/tmp` (max. 1GiB)

The maximum sizes are arbitrarily chosen and defined in
[init.sh](./initramfs/init.sh#L101). Make sure that your guest VM fits these
sizes. If you wish to change them, remember to also rebuild the
[initramfs](#step-1-build-custom-initramfs).

When the guest is launched using our `verity` workflow, the content of those
folders is copied to the `tmpfs` filesystems during early userspace, which will
cause some boot latency. Besides, you should also consider that the memory usage
of the guest will increase based on the actual size of those folders, and the
max memory must be configured accordingly when launching QEMU (`-mem`
parameter). Hence, make sure to keep the size of those folders as small as
possible.

Obviously, the root filesystem should not contain *any* secrets because it is
not encrypted. Make sure to delete them before performing the steps below.
Regarding SSH, our scripts will automatically delete any host keys from the
`verity` image, and new keys will be generated by initramfs. Since the `/etc`
folder is mounted as `tmpfs`, host SSH keys generated at runtime will not be
leaked to the host.

### Step 1: Prepare dm-verity

First of all, we need to prepare the root disk and the verity Merkle tree. We
use the [setup_verity.sh](./guest-vm/setup_verity.sh) script to create a new VM
image and copy the root filesystem there along with the required modifications.
Then, we compute the `dm-verity` tree and root hash.

```bash
make setup_verity
```

To use a custom image, run
```bash
make setup_verity IMAGE=<path to your qcow2 image> 
```

Both commands will create a central VM config file at `build/verity/vm-config-verity.toml`.
This file contains all settings that are relevant for the attestation process, e.g. the OVMF binary, the kernel command line or if debug mode is activated.
It is used by both, our launch scripts and our verification tools to avoid configuration missmatches between the launch configuration and the configuration option used to compute the expected launch digest.

### Step 2: Launch guest

Now it's time to launch our guest VM. If everything goes well, you should be
able to see a `Booting dm-verity filesystem..` message in the initramfs logs,
and after a short while the guest OS will start. The boot time depends on the
sizes of the folders copied to the `tmpfs` filesystems (see above).

Possible errors in this step might be memory-related, either because one of the
`tmp` filesystems is out of memory, or because the guest VM as a whole is out of
memory. In the former case, you might see a kernel panic, while in the latter
case QEMU will kill the guest.

```bash
# Create verity device, specifying the memory needed
# by default, we use the image and merkle tree generated in the previous step
make run_sev_snp_verity
```
You can pass the following, optional env var parameters:
- `VERITY_IMAGE`and `VERITY_HASH_TREE` to use a custom image and hash tree
- `MEMORY` to specify the memory size in MB

### Step 3: Verify guest integrity

Now, after the guest has booted, we can connect to it via SSH and get an
attestation report to verify its integrity.

To get the attestation report, first copy the `build/get_report` binary into the VM.
Inside the VM, execute `sudo ./get_report` to store the report in a json file.
To verify the report, copy it to the host and use `build/verify_report --input <path to obtained report file> --vm_definition <path to vm config file>`. If you are using the default setup, the VM config file is at `build/verity/vm-config-verity.toml`

## Run encrypted workflow

### Step 1: Prepare dm-crypt
We need to  encrypt and integrity protect the root disk . 
To perform both steps, use
```bash
make setup_luks
```

Besides the VM image, this also creates our central VM config file at `build/luks/vm-config-verity.toml`.
This file contains all settings that are relevant for the attestation process, e.g. the OVMF binary, the kernel command line or if debug mode is activated.
It is used by both, our launch scripts and our verification tools to avoid configuration missmatches between the launch configuration and the configuration option used to compute the expected launch digest.

### Step 2: Launch guest
To start the guest, use
```bash
make run_sev_snp_luks
```

### Step 3: Unlock encrypted filesystem
Next, we verify the attestation report. If it is valid and matches the expected values, we securely inject the disk encryption key.
To perform both steps run
```bash
LUKS_KEY=<your disk encryption key> make  
```

## ID Block and an ID Auth block
This is an optional feature of the SEV-SNP, attestation, might be useful for certain use cases. In can be used with any of the workflows

The ID block and an ID authentication information structure allow you to pass some user defined data to describe the
VM, as well as the public parts of the ID key and the author key. All of this information will be reflected
in the attestation report. In addition, the ID block will trigger a check of the launch digest and the guest policy before entering the VM.
Otherwise, both would only be checked at runtime, during the attestation handshake described later in this document.

Use the following command to generate an ID block and id auth block files for usage with QEMU:
```bash
# generate id_key.pem
openssl ecparam -name secp384r1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out priv_id_key.pem
# generate author_key.pem
openssl ecparam -name secp384r1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out priv_author_key.pem
# generate attestation data: id-block.base64 and id-block.base64
./build/idblock-generator --vm-definition <path to your vm config file> --id-key-path priv_id_key.pem --auth-key-path priv_author_key.pem
```

Both ID key and author key are user defined keys. The ID key is used to sign the ID block and the author key is used to sign the ID key.
This enables you to use a different ID key for each VM while reflecting that all VMs belong to the same VM owner/author.
Bot keys need to be in the PKCS8 PEM format.

To use them, add `id-block <path to id-block.base64> -id-auth <path to auth-block.base64>` and when calling `launch.sh`.
See e.g. the `run_sev_snp_luks` recipe in the [Makefile](Makefile) to get an idea how to manually call the launch script.



## Tips and tricks

### SSH config
If you frequently regenerate VMs with this repo you will get a lot of ssh remote host identification has changed errors, due to the different set of ssh keys used by every new VM.
For local testing, it is fine to ignore host key checking by adding the following to your `~/.ssh/config` and using `ssh <user@>localtestvm` to connect to the VM.
```
Host localtestvm
	ForwardAgent yes
	Port 2222
	HostName 127.0.0.1
	StrictHostKeyChecking no
	UserKnownHostsFile=/dev/null
```

## References
- [1] https://github.com/AMDESE/AMDSEV/tree/snp-latest
- [2] https://www.youtube.com/watch?v=4wZnl0njxm8
