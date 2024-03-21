# openend2e-sevsnp

This repository demonstrates an e2e secured setup for a SEV-SNP VM.
To achieve this, we use the attestation
process of SEV-SNP in combination with software tools like Full Disk Encryption
to provide a secure SEV setup. While the official AMD repo [1] explains how to
setup a SEV-SNP VM, it does not cover these topics at all.

Currently, this repo is mainly intended as a technical demo and NOT intended
to be used in any kind of production scenario.


## High Level Workflow
Our solutions consists of two stages.

The first stage consists of a small, publicly known code image that does not
contain any secrets. 
The second stage is a full Linux VM that is stored on an encrypted disk image.
Thus is may contain arbitrary secret data.

We create and boot a new VM, using the small first stage code image and use the SEV-SNP attestation features to ensure the
integrity its integrity.
After booting, the first stage proves its authenticity to the VM
owner, using remote attestation. Afterwards, the VM owner can build an encrypted
channel to send secrets into the VM.
We use this to transmit the disk encryption key required to unlock the disk image
for the second stage.
After receiving the key, the first stage unlocks and mounts the encrypted disk
and uses *switch_root* to jump into the new image.

### Limitations and Caveats
The second stage still uses the same Linux as the first stage, i.e. the /boot
partition of the full VM in the second stage is ignored.

## Build

Dependencies:
- Working docker setup
- Working rust toolchain
- Linux tools: make podman pv

To setup SEV on your system, we refer to the official AMD repo [1].

For our setup, we need to build two main components: the first stage code image
and the second stage code image

### First Stage Code Image
For the first stage, we require the OVMF UEFI implementation, a Linux kernel and a
custom initramfs.

Please follow the documentation from the official AMD guide to build the OVMF image and the Linux kernel. However, for the OVMF image you need to tweak
the build file as documented in `changes-to-amd-common.diff`
This will build a different OVMF target, that allows us to bootstrap the integrity of the  Linux kernel, our initramfs and the kernel commandline flags.

Next, we will build the custom initramfs.
1) Extract the content of the guest kernel deb package from the `linux` subfolder in the AMD repo  a seprate folder using `dpkg -x <path to .deb> <path to folder>`. Let `DEB_CONTENT` be that folder.
2) Run `KERNEL_MODULES_DIR=$DEB_CONTENT` to build the initramf. This script requires
root priviliges to change the file ownership of the files in the initramfs to root.
If you want to copy any additional files to the initramfs, you may set the `ROOTFS_EXTRA_FILES` env var to a whitespaces separated list of files. The  initramfs is placed in `./build/binaries/` 

### Second Stage Code Image

The second stage code image  consits of an full Linux installation using LUKS2 disk encryption for its root partition.

If you already have an enrypted Linux VM installation, you can use it with our repo by applying the tweaks from the following section. If not, we provide a step-by-step description the section after that section.

#### Convertign an existing Linux VM
However, it is assumed that the root partition is the third partition on the disk (i.e. sda3). Furthermore, your VM should be reachable via SSH. The only other tweak that we need to apply,
is to ensure that the systemd init system does not try to unlock the root
disk, as this is already done by our first stage code image.
To achieve this boot the VM image as normal, remove the entry for the root disk in `/etc/crypttab` and run `update-grub2`. NOTE, afterwards you can no longer regularly boot the VM, as it expects the root disk to be already unlocked.

#### Creating a new Linux VM
TODO
probably provide a video

## Usage

We first describe the high level workflow, before describing each step in more detail.

On a high level, the workflow for our tool is as follows:
1) (One time) Setup a configuration file that specifies all security policies and files that are relevant for the attestation
2) Use the `openend2e-launch`.sh script to start the VM on the SEV host. You will see some output from the OVMF boot process and eventually a blank line without any prompt. At this point, the server process running inside the VM is ready to perform remote attestation with the VM owner.
3) Start the `client` binary to start the remote attestation process and to securely transfer the disk encryption key inside the disk. A few seconds after the remote attestation succeeds, you should be able to SSH into your VM.

The reasons that you need to use SSH and that there is no console output, is that the the content of the default "ttyS0" console is insecure as all data goes through an unecrypted video buffer. Thus it is disabled by default. If you want to use it
for debug purposes, you need to pass the `console=ttyS0` kernel command line option.

### Generate Config File
Copy the example configuration file from `./attestation_server/examples/vm-config.toml`
and fill in the missing values.
For the `ovmf_file` use the OVMF firmware that we build using the offical AMD repo. It is located in the `usr/local/share/qemu/DIRECT_BOOT_OVMF.fd` sub folder of the AMD repo.
For the `kernel_file` use the `vmlinuz-XXX` file that is part of the guest kernel .deb file that we extracted during the build step
For the `initrd_file` use the initramfs file that we build under `./build/binaries/`

We tried to provide sane defaults, however
certain options, like the minimum allowed version for the AMD PSP firmware might vary
by platform. Use the `sev-feature-info` binary (requries root) to discover firmware related information about your platform.

### (Optional) Generate an ID Block and an ID Auth block
The ID block and an ID authentication information structure allow you to pass some user defined data to describe/identify the
VM, as well as the public parts of the ID key and the author key. All of this information will be reflected
in the attestation report. In addition, the ID block will trigger an early check of the launch digest and the guest policy  before entering the VM
Otherwise, the LD will only be checked at runtime, during the attestation handshake described later in this document.

Use the following command generate an ID block and an auth block files for usage with QEMU:
`./idblock-generator --vm-definition vm-config.toml --id-key-path id_key.pem --auth-key-path author_key.pem`

Both ID key and author key are user defined keys. The ID key signs the ID block and the author key signs the ID key.
This enables you to use a different ID key for each VM while this reflecting that all VMs belong to the same VM owner/author.
Bot keys need to be in the PKCS8 PEM format. You can generate them with
`openssl ecparam -name secp384r1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out private_key.pem`
The second part is needed as there are two sub variants for PEM and the default one used
by OpenSSL cannot be parsed by the library that we used (apparently the PKCS8 one is also the
better variant)


### Run the VM
To use the `openend2e-launch.sh` script in the following steps, set the 
`SEV_TOOLCHAIN_PATH ` env var to point to the `usr/local` SUBFOLDER of the offical AMD repo. This is required so that our script can pickup the SEV-SNP compatible QEMU binary build by the official AMD repo.

The script will forward the ports 22 and 80 from the VM to  localhost:2222 and localhost:8080 on the host system. The server for the attestation is listenign
on port 80 inside the VM. If you want to perform the remote attestation from a different machine edit the following line in `openend2e-launch.sh` to forward port 80 to a remotely reachable IP of you choice.
`add_opts " -netdev user,id=vmnic,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8080-:80"
` 

Use the following command to start the VM
`sudo ./launch-qemu.sh -sev-snp -smp <number of vcpus> -bios <path to OMVF> -kernel <path to kernel> -initrd <path to initramfs> -hda <path to enrypted disk image> -policy <0x prefixed policy number> -append <kernel commandline args>`
If you want to use the optional ID block, also add the following parameters
`-id-block <path to id-block.base64> -id-auth <path to auth-block.base64>`

Wait until the scrolling text stops.

Next, on the same system as the VM is running, use the follwoing command to perform the attestation process
`client --disk-key <disk encryption pw> --vm-definition <VM_DEFINITION>`
If you used the ID block during launch, also add the `--id-block-path <path to id-block.base64>` and `--author-block-path <path to auth-block.base64>` params, to verify the information from these blocks that are visible in the attestation report.
See `--help` for additional optional parameters. 
If the remote attestation succeeds, you should be able to SSH into your VM
on localhost:2222 shorty afterwards.

## References
[1] https://github.com/AMDESE/AMDSEV/tree/snp-latest
