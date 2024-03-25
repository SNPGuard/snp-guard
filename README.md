# openend2e-sevsnp

This repository demonstrates an end-to-end secured setup for a SEV-SNP VM.
To achieve this, we build on the ideas from [2] and use the attestation
process of SEV-SNP in combination with software tools like full disk encryption
to provide a secure SEV setup. While the official AMD repo [1] explains how to
set up a SEV-SNP VM, it does not cover these topics at all.


Currently, this repo is mainly intended as a technical demo and NOT intended
to be used in any kind of production scenario.

We explicitly decided to boot into a feature rich initramfs to enable easy tweaking of the boot
process to explore novel ideas.

## High Level Workflow
Our solution consists of two stages.

The first stage consists of a small, publicly known code image that does not
contain any secrets. 
The second stage is a full Linux VM that is stored on an encrypted disk image.
Thus is may contain arbitrary secret data like an OpenSSH server key.

We create and boot a new VM, using the small first stage code image and use the SEV-SNP isolation and attestation features to ensure its integrity.
After booting, the first stage proves its authenticity to the VM
owner, using remote attestation. Afterwards, the VM owner can build an encrypted
channel to send secrets into the VM.
We use this to transmit the disk encryption key required to unlock the disk image
for the second stage.
After receiving the key, the first stage unlocks and mounts the encrypted disk
and uses *switch_root* command to jump into the new image. Using this process, we
can start the regular `/sbin/init` binary of the second stage to ensure proper startup
of all configured services

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

## TLDR
Assuming you are using Ubuntu

### Build
TODO: integrate rust toolchain installation
1) Build and instal all depdendencies with `./prepare-snp-dependencies.sh`
2) Follow the [AMD manual](https://github.com/AMDESE/AMDSEV/tree/snp-latest) to configure your sytem for SEV-SNP. Skip the "Build" step as we already performed this in step 1
3) Compile our tool with `make`
4) (Optional) If you don't have an existing VM image, create one with XXX
5) Convert your VM to use an encrypted disk with the XXX conversion script

### Run
1) `source build.env`
2) `sudo -E bash -x ./openend2e-launch.sh -sev-snp -load-config ./build/binaries/default-vm-config.toml -hda <your disk .qcow2>`
3) Wait a few seconds, then `client --disk-key <disk encryption pw> --vm-definition ./build/binaries/default-vm-config.toml`
4) SSH into your VM on via  `localhost:2222`


## Build
Dependencies:
- Working docker setup
- Working rust toolchain
- Linux tools: `make`, `podman`, `pv`

### Prepare for SEV-SNP
1) Build and instal all depdendencies with `./prepare-snp-dependencies.sh`
2) Follow the [AMD manual](https://github.com/AMDESE/AMDSEV/tree/snp-latest) to configure your sytem for SEV-SNP. Skip the "Build" step as we already performed this in step 1


### First Stage Code Image
For the first stage, we require the OVMF UEFI implementation, a Linux kernel and a
custom initramfs.

1) Extract the content of the guest kernel *deb* package from the `linux` subfolder in the AMD repo into a separate folder using `dpkg -x <path to .deb> <path to folder>`. Let `GUEST_DEB_CONTENT` be that folder.
2) Run `KERNEL_MODULES_DIR=$GUEST_DEB_CONTENT make` to build the initramfs and the binaries used in the attestation process. This script requires
root privileges to change the file ownership of the files in the initramfs to root.
If you want to copy any additional files to the initramfs, you may set the `ROOTFS_EXTRA_FILES` env var to a whitespace separated list of files. The initramfs is placed in `./build/binaries/`. The binaries for the attestation process are in
`./attestation_server/target/debug/`


## References
[1] https://github.com/AMDESE/AMDSEV/tree/snp-latest
