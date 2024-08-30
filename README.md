# SNPGuard

This repository demonstrates an end-to-end secured setup for a SEV-SNP VM. To
achieve this, we build on the [ideas from the open source
community](https://www.youtube.com/watch?v=4wZnl0njxm8) and use the attestation
process of SEV-SNP in combination with software tools like full authenticated
disk encryption to provide a secure confidential VM (CVM) setup. While the
official [AMD repo](https://github.com/AMDESE/AMDSEV/tree/snp-latest) explains
how to set up a SEV-SNP VM, it does not cover these topics.

Currently, this repo is mainly intended as a technical demo and NOT intended to
be used in any kind of production scenario.

This repo is part of the SysTEX24 Tool Paper [_"SNPGuard: Remote Attestation of
SEV-SNP VMs Using Open Source Tools"_](https://arxiv.org/abs/2406.01186). Please cite as follows:

```bibtex
@INPROCEEDINGS {wilke2024snpguard,
author = {L. Wilke and G. Scopelliti},
booktitle = {2024 IEEE European Symposium on Security and Privacy Workshops (EuroS&amp;PW)},
title = {SNPGuard: Remote Attestation of SEV-SNP VMs Using Open Source Tools},
year = {2024},
volume = {},
issn = {},
pages = {193-198},
doi = {10.1109/EuroSPW61312.2024.00026},
url = {https://doi.ieeecomputersociety.org/10.1109/EuroSPW61312.2024.00026},
publisher = {IEEE Computer Society},
address = {Los Alamitos, CA, USA},
month = {jul}
}
```

The workflow consists of five different stages:

1. [Install dependencies](#install-dependencies)
2. [Build packages](#build-packages)
3. [Prepare host](#prepare-host)
4. [Prepare guest](#prepare-guest)
5. Run: [integrity](#run-integrity-only-workflow) and
   [encrypted](#run-encrypted-workflow) workflows

Stages 1 to 3 are supposed to be done only once, unless you wish to install
updated versions of the SNP tools and packages.

In order to run our workflows, a machine with AMD EPYC 7xx3 (Milan) or 9xx4
(Genoa) is required. The guide below assumes that all steps are performed
directly on the SNP host, although stages 1, 2, 4, and step 1 of stage 5 can
(and _should_) be executed on a trusted machine (SEV-SNP is not required for
those steps).

Note: the guide below is intended for users running a recent Debian-based Linux
distribution such as Ubuntu or Debian, and it has been tested successfully on
Ubuntu 22.04 LTS. If you are using a different distribution, some scripts might
not work out of the box and might require some adaptation.

## Directory Overview
- `attestation` : Helper scripts to fetch the attestation report for the [integrity-only](#run-integrity-only-workflow) use case
- `guest-vm` : Scripts to create new VMs and to convert the VM disks for usage with the [integrity-only](#run-integrity-only-workflow) or [encrypted](#run-encrypted-workflow) workflows
- `initramfs` : Custom initramfs that is used by SNPGuard to transition to the rich Linux environment
- `snp-builder` : Scripts for building SEV-SNP dependencies from scratch
- `tools` : Server and client binaries to fetch the attestation report inside the VM and to verify it on the host

## Install dependencies

For building the SNP packages and preparing the guest we need to install some
basic dependencies such as Docker, Rust toolchain, and a few packages via `apt`.
The `install_dependencies.sh` script automates the whole process, at the same
time asking for user confirmation before proceeding with the installation.

From the top-level directory, execute:
```bash
# Install all dependencies. 
# Note: the script will skip installation of any dependencies that you have already installed
#        if you want install up-to-date packages, pass the flag "-f" to the script
./install-dependencies.sh

# Note: if this is the first installation of Docker or Rust,
#       you may need to reload your shell
```

## Build packages

The first build step consists of building customized versions of QEMU, OVMF and
Linux kernel (both for host and guest) that have SNP-enabled capabilities. This
is done by following the [AMD
manual](https://github.com/AMDESE/AMDSEV/tree/snp-latest).

In this repository, we provide pre-built binaries and convenience scripts to
automate the process. Below, we give three different options, from the most
automated (and quickest) to the most manual (and slowest) way.

**Note:** The AMD forks of QEMU, OVMF and Linux are subject to frequent changes
and rebases, thus commits are not stable. We also noticed that some versions
include changes in the SEV-SNP VMSA, which might break attestation due to
mismatched launch measurements. For this reason, we provide a stable snapshot of
these repositories in [our
organization](https://github.com/orgs/SNPGuard/repositories) that can be used to
build the SEV-SNP toolchain. Each of the options below can be configured to use
our snapshots, and we recommend using them for the time being. This is only a
temporary workaround, as Linux kernel 6.10 is supposed to contain SEV-SNP
hypervisor support.

### Option 1: Download pre-built packages

We provide pre-built packages as releases in our repository. Such packages have
been built using our Option 2 below.

From the top-level directory, execute:
```bash
# create and move to build directory
mkdir -p build && cd build

# Download archive from our Github repository
wget https://github.com/SNPGuard/snp-guard/releases/download/v0.1.2/snp-release.tar.gz

# unpack archive
tar -xf snp-release.tar.gz

# go back to the top-level directory
cd ..
```

### Option 2: Build with Docker

Here, we create a Docker image that contains all the required dependencies, and
then we run a container in detached mode that builds the actual QEMU, OVMF, and
kernel packages. The container will run in the background, allowing you to close
the current shell and wait until the packages have been built. When the
container has finished, we fetch the packages and extract the TAR archive.

From the top-level directory, execute:
```bash
# go to the `snp-builder` folder
cd snp-builder

# Build docker image containing all dependencies
make image

# Run container in the background (it can take several hours to complete)
# Without USE_STABLE_SNAPSHOTS=1, the script will use the AMD upstream repos
make build USE_STABLE_SNAPSHOTS=1

# Fetch archive from the container
# note: you should wait until the container has exited successfully. Otherwise, this command will fail
make get_files

# (optional) remove container
make clean

# go to the build dir
cd ../build

# unpack archive
tar -xf snp-release.tar.gz

# go back to the top-level directory
cd ..
```

### Option 3: Build locally

We wrote a convenience script that installs all build dependencies and builds
the required packages. Note that building the Linux kernel may take several
hours.

From the top-level directory, execute:
```bash
# Run build script
# Without -use-stable-snapshots, the script will use the AMD upstream repos
./snp-builder/build-packages.sh -use-stable-snapshots
```

## Prepare host

### Step 0: SEV firmware

SEV-SNP requires firmware version >= 1.51:1. To check which version of the
firmware is installed, you can install and use the
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
differ from machine to machine, but make sure to check the following options:

- `Secure Nested Paging`: to enable SNP
- `Secure Memory Encryption`: to enable SME (not strictly required for running
  SNP guests)
- `SNP Memory Coverage`: needs to be enabled to reserve space for the Reverse
  Map Page Table (RMP). [Source](https://github.com/AMDESE/AMDSEV/issues/68)
- `Minimum SEV non-ES ASID`: this option configures the minimum address space ID
  used for non-ES SEV guests. By setting this value to 1 you are allocating all
  ASIDs for normal SEV guests, and it would not be possible to enable SEV-ES and
  SEV-SNP. So, this value should be greater than 1.

### Step 2: Install host kernel

Note: if you followed the [build](#build-packages) guide above, the `install.sh`
script to install the host kernel is available under `./build/snp-release/`:

From the top-level directory, execute:
```bash
cd build/snp-release
sudo ./install.sh

# Reboot machine and choose the SNP host kernel from the GRUB menu
```

### Step 3: Ensure that kernel options are correct

- Make sure that IOMMU is enabled and **not** in passthrough mode, otherwise
  SEV-SNP will not work. Ensure that the IOMMU flag is set to `iommu=nopt` under
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
# 6.9.0-rc7-snp-host-05b10142ac6a

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
# SEV-SNP: RMP table physical range [0x000000bf7e800000 - 0x000000c03f0fffff]
# SEV-SNP: Reserving start/end of RMP table on a 2MB boundary [0x000000c03f000000]
# ccp 0000:01:00.5: sev enabled
# ccp 0000:01:00.5: SEV firmware update successful
# ccp 0000:01:00.5: SEV API:1.55 build:21
# ccp 0000:01:00.5: SEV-SNP API:1.55 build:21
# kvm_amd: SEV enabled (ASIDs 510 - 1006)
# kvm_amd: SEV-ES enabled (ASIDs 1 - 509)
# kvm_amd: SEV-SNP enabled (ASIDs 1 - 509)
```

## Prepare guest

### Step 0: Unpack kernel

We first need to unpack the kernel obtained from the built packages. By default,
the kernel package can be found under
`build/snp-release/linux/guest/linux-image-*.deb`. We unpack it to
`build/kernel`.

From the top-level directory, execute:
```bash
make unpack_kernel
```

### Step 1: Build custom initramfs

We need to build a customized initramfs (i.e., initial RAM disk) to configure
boot options at early userspace and enable our workflows. This allows easy
tweaking of the boot process to explore novel ideas.

We do this by leveraging Docker. In short, we run an Ubuntu container, and then
we export its filesystem on `build/initramfs/`. Afterwards, we make the
necessary adjustments to the filesystem, such as adding a `init` script,
removing unnecessary folders, and changing file permissions. Finally, we build
the initramfs archive using CPIO.

First, however, we build some self-written tools that we use to facilitate the attestation process. All tools will be copied to the `build/bin` directory.

From the top-level directory, execute:
```bash
# Build tools for attestation process
make build_tools

# Create initramfs
make initramfs
```

### Step 2: Prepare guest image

To run our workflows, we recommend creating a new guest image from scratch, but
we also support running from an existing image.

#### Option A: create a new image

From the top-level directory, execute:
```bash
# create image (will be stored under build/guest/sevsnptest.qcow2)
make create_new_vm

# run image for initial setup
# Note: if you don't see a prompt after cloud-init logs, press ENTER
make run_setup

# (From another shell) Copy kernel and headers to the guest VM via SCP
# note: if the guest does not have an IP address check below instructions
scp -P 2222 build/snp-release/linux/guest/*.deb <username>@localhost:
```

Continue with [checking the guest configuration](#guest-configuration) from within in the guest.

#### Option B: use an existing image

Note: if you wish to run our integrity-only workflow you should make sure to
delete *all secrets* from the guest VM (see
[below](#run-integrity-only-workflow)). SSH keys, instead, are regenerated
automatically.

Caution: if your VM image uses a [LVM2
filesystem](https://en.wikipedia.org/wiki/Logical_Volume_Manager_(Linux)), make
sure that on the host there are no other LVM2 filesystems mounted with the same
name (you can check with `sudo lvdisplay`). Otherwise, we will not be able to
extract the guest filesystem when preparing the integrity-protected or encrypted
volume. Alternatively, you can use the Option A to avoid any potential issues.

From the top-level directory, execute:
```bash
# Run VM for configuration
make run IMAGE=<your_image>

# (From another shell) Copy kernel and headers to guest
scp -P 2222 build/snp-release/linux/guest/*.deb <username>@localhost:
```

Continue with [checking the guest configuration](#guest-configuration) from within in the guest.

#### Guest configuration

From inside the guest:
```bash
# install kernel and headers (copied before)
# This is needed even when running direct boot, as we still need access to the kernel module files
sudo dpkg -i linux-*.deb

# remove kernel and headers to save space
rm -rf linux-*.deb

# disable multipath service (causes some conflicts)
sudo systemctl disable multipathd.service

# If you have not created the VM using our script, you need to 
# disable EFI and swap partitions in /etc/fstab
sudo mv /etc/fstab /etc/fstab.bak

# Shut down VM
sudo shutdown now
```

### Step 3: Prepare template for attestation

Before launching the VM, a VM configuration file will be created at
`build/vm-config.toml`. This file contains all settings that are
relevant for the attestation process, e.g. the OVMF binary, the kernel command
line or if debug mode is activated. The same configuration is then applied to
both the launch script and attestation command.

The configuration file is created from a template that can be retrieved with the
command below:

From the top-level directory, execute
```bash
make fetch_vm_config_template
```

The template will then be stored in `./build/guest/vm-config-template.toml`. It
is important to properly configure the template according to the host and guest
configuration.

**NOTE**: Most of the options will be automatically configured by our scripts,
but the user should manually check the following options to ensure they are
correct (the template contains useful information to understand them):

- `host_cpu_family`
- `platform_info`
- `min_commited_tcb`

## Run integrity-only workflow

In this workflow, we create a read-only filesystem starting from an existing
image using `dm-verity`. Integrity protection is ensured by a Merkle hash tree,
passed as a separate disk, and a root hash passed as kernel command-line
argument. Only the root hash must be protected from tampering to preserve the
integrity of the root filesystem. In our workflow, since the kernel command line
is measured with SEV-SNP and Direct Linux Boot, the root hash is protected, and
its value is reflected in the attestation report.

A read-only filesystem can give strong integrity guarantees, but it is not very
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

From the top-level directory, execute
```bash
# create verity image. Pass IMAGE=<path> to change source image to use.
# By default, the image created with `make create_new_vm` is used
make setup_verity
```

### Step 2: Launch guest

Now it's time to launch our guest VM. If everything goes well, you should be
able to see a `Booting dm-verity filesystem..` message in the initramfs logs,
and after a short while the guest OS will start. The boot time depends on the
sizes of the folders copied to the `tmpfs` filesystems (see above).

Possible errors in this step might be memory-related, either because one of the
`tmp` filesystems is out of memory, or because the guest VM as a whole is out of
memory. In the former case, you might see a kernel panic, while in the latter
case QEMU will kill the guest.

From the top-level directory, execute
```bash
# Run guest VM with `dm-verity` enabled
# by default, we use the image and merkle tree generated in the previous step
make run_verity_workflow
```

You can pass the following, optional parameters:

- `VERITY_IMAGE` and `VERITY_HASH_TREE` to use a custom image and hash tree
- `MEMORY` to specify the memory size in MB
- `CPUS`: Number of CPUs that the guest CVM will have. It is important to
  specify the correct value because it will be reflected in the launch
  measurement. Default: `1`.
- `POLICY`: The SEV-SNP launch policy. Default: `0x30000`.

**Caution**: The make command above adds the `console=ttyS0` option to the
kernel command line of the VM. This enables console output from the VM on the
terminal, making it much easier to follow the steps in this manual and to debug
potential errors. However, this is not a secure production setup, as all console
data passes through unencrypted host memory. In addition, it increases the
attack surface of the hypervisor. If you are running the VM locally this does
not matter, but for a remote production setup, you should remove this option
from the Makefile (overriding the `KERNEL_CMDLINE` parameter) and only log in
via SSH.

### Step 3: Verify guest integrity

Now, after the guest has booted, we can connect to it via SSH and get an
attestation report to verify its integrity. Our tool automates this process, as
explained below.

In the initramfs, after generating new host SSH keys (see above), the guest CVM
requests an attestation report from the AMD SP and puts the fingerprint of the
public SSH key in the `REPORT_DATA` field. The attestation report is then stored
in `/etc/report.json` in the root filesystem, and can be retrieved on demand by
the guest owner.

We provide a script that fetches the report via `scp` and verifies it using the
`verify_report` tool. Attestation will also check that the `REPORT_DATA` field
in the report matches the SSH key fingerprint of the guest, obtained when
connecting via `scp`. If attestation succeeds, the guest can then safely connect
to its VM via SSH using the `known_hosts` file that will be stored in `./build`:

From the top-level directory, execute
```bash
# Note: the commands below have to be performed on a new shell in the host

# Fetch attestation report via `scp` and attest the guest VM
# The report will be stored in `build/verity/attestation_report.json`
make attest_verity_vm VM_USER=<your_user>

# if attestation succeeds, safely connect via SSH
make ssh VM_USER=<your_user>
```

Both commands above accept the following parameters:

- `VM_HOST`: hostname of the guest VM (default: `localhost`)
- `VM_PORT`: port of the guest VM (default: `2222`)
- `VM_USER`: user of the guest VM used for login (default: `ubuntu`)

**Note**: attestation may fail if the host CPU family, minimum TCB and platform
info are not the expected ones, as explained
[above](#step-3-prepare-template-for-attestation).

## Run encrypted workflow

### Step 1: Prepare dm-crypt

First, We need to encrypt and integrity protect the root disk. We use the
[setup_luks.sh](./guest-vm/setup_luks.sh) script to create a new encrypted VM
image and copy the root filesystem there along with the required modifications.
The script will ask the user to enter a passphrase that will be used as the disk
encryption key. The script will prompt for confirmation a few times, before it proceeds.
Some of the prompts are case sensitive!

From the top-level directory, execute
```bash
# create encrypted image. Pass IMAGE=<path> to change source image to use.
# By default, the image created with `make create_new_vm` is used
make setup_luks
```

### Step 2: Launch guest

Now it's time to launch our guest VM. If everything goes well, you should be
able to see a `Starting attestation server on 0.0.0.0:80` message in the
initramfs logs, indicating that the guest is waiting to perform attestation and
get the decryption key of the root filesystem (see Step 3 below).

From the top-level directory, execute
```bash
# Run guest VM with `dm-verity` enabled
# by default, we use the image generated in the previous step
make run_luks_workflow
```

You can pass the following, optional parameters:

- `MEMORY` to specify the memory size in MB
- `CPUS`: Number of CPUs that the guest CVM will have. It is important to
  specify the correct value because it will be reflected in the launch
  measurement. Default: `1`.
- `POLICY`: The SEV-SNP launch policy. Default: `0x30000`.

**Caution**: The make command above adds the `console=ttyS0` option to the
kernel command line of the VM. This enables console output from the VM on the
terminal, making it much easier to follow the steps in this manual and to debug
potential errors. However, this is not a secure production setup, as all console
data passes through unencrypted host memory. In addition, it increases the
attack surface of the hypervisor. If you are running the VM locally this does
not matter, but for a remote production setup, you should remove this option
from the Makefile (overriding the `KERNEL_CMDLINE` parameter) and only log in
via SSH.

### Step 3: Unlock encrypted filesystem

Next, we verify the attestation report. If it is valid and matches the expected
values, we securely inject the disk encryption key. To perform both steps, run
the command below:

From the top-level directory, execute
```bash
# Note: the command below has to be performed on a new shell in the host

# Fetch report from the VM and, if attestation succeeds, deploy encryption key
# The report will be stored in `build/luks/attestation_report.json`
LUKS_KEY=<your disk encryption key> make attest_luks_vm
```

Unlike the integrity workflow, where we regenerate SSH keys, here the guest will
still use its original keys. Therefore, it is up to the guest owner to verify
the authenticity of future SSH connections by checking that the fingerprints
match the expected values.

**Note**: attestation may fail if the host CPU family, minimum TCB and platform
info are not the expected ones, as explained
[above](#step-3-prepare-template-for-attestation).

## Optional features

### ID Block and an ID Author block

This is an optional feature of the SEV-SNP, attestation, might be useful for
certain use cases. In can be used with any of the workflows.

The ID block and an ID authentication information structure allow you to pass
some user defined data to describe the VM, as well as the public parts of the ID
key and the author key. All of this information will be reflected in the
attestation report. In addition, the ID block will trigger a check of the launch
digest and the guest policy before entering the VM. Otherwise, both would only
be checked at runtime, during the attestation handshake described later in this
document.

Use the following command to generate an ID block and id author block files for
usage with QEMU:

From the top-level directory, execute
```bash
# generate id_key.pem
openssl ecparam -name secp384r1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out priv_id_key.pem
# generate author_key.pem
openssl ecparam -name secp384r1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out priv_author_key.pem
# generate attestation data: id-block.base64 and id-block.base64
./build/bin/idblock-generator --vm-definition <path to your vm config file> --id-key-path priv_id_key.pem --auth-key-path priv_author_key.pem
```

Both ID key and author key are user defined keys. The ID key is used to sign the
ID block and the author key is used to sign the ID key. This enables you to use
a different ID key for each VM while reflecting that all VMs belong to the same
VM owner/author. Bot keys need to be in the PKCS8 PEM format.

To use them, add `id-block <path to id-block.base64> -id-auth <path to
auth-block.base64>` and when calling `launch.sh`. See e.g. the
`run_luks_workflow` recipe in the [Makefile](Makefile) to get an idea how to
manually call the launch script.
To include the ID block and the ID author block in the verification process, you need to pass the base64 files to the verification binary via the `id-block-path` and `author-block-path` options.

## Customization options

Our workflows can be easily customized to fit the user's needs and try out new
things.

### Customizing launch parameters

Check out the [Makefile](./Makefile) for a full list of parameters that are used
in our commands, in particular QEMU launch arguments and guest kernel
command-line parameters. Additionally, as described
[above](#step-3-prepare-template-for-attestation), the VM configuration file can
be adapted to the host configuration.

### Enhancing initramfs

in the [initramfs](./initramfs/) folder you can find the
[Dockerfile](./initramfs/Dockerfile) used to create the container image from
which we build our custom initramfs. The Dockerfile can be easily extended to
add new packages and files. Besides, the [init](./initramfs/init.sh) script can
be modified to execute custom logic when the kernel boots in early userspace,
e.g., to support new workflows.

## Tips and tricks

### SSH config

If you frequently regenerate VMs with this repo you will get a lot of ssh remote
host identification has changed errors, due to the different set of ssh keys
used by every new VM. For local testing, it is fine to ignore host key checking
by adding the following to your `~/.ssh/config` and using `ssh
<user@>localtestvm` to connect to the VM.

```
Host localtestvm
	ForwardAgent yes
	Port 2222
	HostName 127.0.0.1
	StrictHostKeyChecking no
	UserKnownHostsFile=/dev/null
```
