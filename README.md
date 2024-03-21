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

## Build

Dependencies:
- Working docker setup
- Working rust toolchain
- Linux tools: `make`, `podman`, `pv`

To set up SEV on your system, follow the instructions of the official AMD repo [1].

For our setup, we need to build two main components:
- the first stage code image
- the second stage code image

### First Stage Code Image
For the first stage, we require the OVMF UEFI implementation, a Linux kernel and a
custom initramfs.

Please follow the documentation from the official AMD guide to build the OVMF image and the Linux kernel. However, for the OVMF image you need to tweak
the `common.sh` build script as documented in `changes-to-amd-common.diff`.
This will build a different OVMF target, that allows us to bootstrap the integrity of the Linux kernel, our initramfs and the kernel command line flags.

Next, we will build the custom initramfs.
1) Extract the content of the guest kernel *deb* package from the `linux` subfolder in the AMD repo into a separate folder using `dpkg -x <path to .deb> <path to folder>`. Let `GUEST_DEB_CONTENT` be that folder.
2) Run `KERNEL_MODULES_DIR=$GUEST_DEB_CONTENT make` to build the initramfs and the binaries used in the attestation process. This script requires
root privileges to change the file ownership of the files in the initramfs to root.
If you want to copy any additional files to the initramfs, you may set the `ROOTFS_EXTRA_FILES` env var to a whitespace separated list of files. The initramfs is placed in `./build/binaries/`. The binaries for the attestation process are in
`./attestation_server/target/debug/`

### Second Stage Code Image

The second stage code image consists of a full Linux installation using LUKS2 disk encryption for its root partition.

If you already have an encrypted Linux VM installation, you can use it with our setup by applying the tweaks from the following section. If not, we provide a step-by-step description for setting up the Linux VM in the section after that section.

#### Converting an existing Linux VM
We assume that the root partition is the third partition on the disk (i.e. sda3). You could change this by tweaking the `cryptsetup` line in `init.sh`. Furthermore, your VM should be reachable via SSH. The only other tweak that we need to apply,
is to ensure that the systemd init system does not try to unlock the root
disk, as this is already done by our first stage code image.
To achieve this boot the VM image as normal, remove the entry for the root disk in `/etc/crypttab` and run `sudo update-initramfs -k all -u`. NOTE, afterwards you can no longer regularly boot the VM, as it expects the root disk to be already unlocked.

#### Creating a new Linux VM

##### Create a default encrypted VM
1) Create Disk image: `<AMD REPO>/usr/local/bin/qemu-img create -f qcow2 openend2e-enc-vm.qcow2 20G`
2) `sudo -E ./openend2e-launch.sh -hda ./openend2e-enc-vm.qcow2 -cdrom <path to ubuntu server installer iso image>`
3) On the grub boot screen, press `e` and change `linux     /casper/vmlinuz  ---` to
`linux     /casper/vmlinuz  console=ttyS0---`. Afterwards, press Ctrl-x or F10 to continue. This will allow you to perform the installation from the terminal, without having to set up a remote VNC display.
4) Follow the installation process until you get to the "Guided Storage configuration" wizard. Make sure to select "Encrypt the LVM group with LUKS" option. Continue with the installation process
5) On the "SSH Setup" wizard, select "Install OpenSSH server" and follow the remaining wizards until the installation is finished
6) Terminate the VM with Ctrl+A, Ctrl+]

##### Tweaks for usage with our system
To use the encrypted VM with our system, you need
to re-configure the systemd init process to not unlock
the root disk. This is required since the root disk has already been unlocked by the first stage code image
when we use the VM with our system.

1) Start the VM with `sudo -E ./openend2e-launch.sh -hda ./openend2e-enc-vm.qcow2 -append console=ttyS0`
and login.
2) Execute `sudo mv /etc/crypttab /etc/crypttab.bak && sudo update-initramfs -k all -u` to stop systemd from trying to unlock the root disk on boot                                     

Now your VM is ready for usage with our system. 

## Usage

We first describe the high level workflow, before describing each step in more detail.

1) Create a configuration file that specifies all security policies and files that are relevant for the attestation
2) Use the `openend2e-launch.sh` script to start the VM on the SEV host. You will see some output from the OVMF boot process and eventually a blank line without any prompt. At this point, the server process running inside the VM is ready to perform the remote attestation with the VM owner.
3) Start the `client` binary to start the remote attestation process and to securely transfer the disk encryption key to the VM. A few seconds after the remote attestation succeeds, you should be able to SSH into your VM. However, there won't be any progress indicator on the screen.

The reasons that you need to use SSH and that there is no console output, is that the content of the default "ttyS0" console is insecure as all data goes through the unencrypted buffer of the video device. Thus, we have disabled by default. If you want to use it
for debug purposes, you need to pass the `console=ttyS0` kernel command line option.

### Generate Config File
Copy the example configuration file from `./attestation_server/examples/vm-config.toml`
and fill in the missing values.
- For the `ovmf_file` use the OVMF firmware that we built using the official AMD repo. It is located in the `usr/local/share/qemu/DIRECT_BOOT_OVMF.fd` sub folder of the AMD repo.
- For the `kernel_file` use the `vmlinuz-XXX` file that is part of the guest kernel *deb* file that we extracted to `GUEST_DEB_CONTENT` during the build step.
- For the `initrd_file` use the initramfs file that we built under `./build/binaries/`

We tried to provide sane defaults, however
certain options, like the minimum allowed version for the AMD PSP firmware might vary
by platform. Use the `sev-feature-info` binary (requires root privileges) to discover firmware related information about your platform.

### (Optional) Generate an ID Block and an ID Auth block
The ID block and an ID authentication information structure allow you to pass some user defined data to describe/identify the
VM, as well as the public parts of the ID key and the author key. All of this information will be reflected
in the attestation report. In addition, the ID block will trigger a check of the launch digest and the guest policy before entering the VM.
Otherwise, both would only be checked at runtime, during the attestation handshake described later in this document.

Use the following command to generate an ID block and id auth block files for usage with QEMU:
`idblock-generator --vm-definition vm-config.toml --id-key-path id_key.pem --auth-key-path author_key.pem`

Both ID key and author key are user defined keys. The ID key is used to sign the ID block and the author key is used to sign the ID key.
This enables you to use a different ID key for each VM while reflecting that all VMs belong to the same VM owner/author.
Bot keys need to be in the PKCS8 PEM format. You can generate them with
`openssl ecparam -name secp384r1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out private_key.pem`
The second part is needed as there are two sub variants for PEM and the default one used
by OpenSSL cannot be parsed by the library that we used (apparently the PKCS8 one is also the
better variant).

### Run the VM
To use the `openend2e-launch.sh` script in the following steps, set the 
`SEV_TOOLCHAIN_PATH ` env var to point to the `usr/local` sub folder of the official AMD repo. This is required so that our script can pick up the SEV-SNP compatible QEMU binary built by the official AMD repo.

The script will forward the ports 22 and 80 from the VM to localhost:2222 and localhost:8080 on the host system. The server for the attestation is listening
on port 80 inside the VM. If you want to perform the remote attestation from a different machine edit the following line in `openend2e-launch.sh` to forward port 80 to a remotely reachable IP of you choice.
`add_opts " -netdev user,id=vmnic,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8080-:80"` 

Use the following command to start the VM
`sudo ./launch-qemu.sh -sev-snp -smp <number of vcpus> -bios <path to OMVF> -kernel <path to kernel> -initrd <path to initramfs> -hda <path to enrypted disk image> -policy <0x prefixed policy number> [-append <kernel command line args>]`
If you want to use the optional ID block, also add the following parameters
`-id-block <path to id-block.base64> -id-auth <path to auth-block.base64>`

Wait until the scrolling text stops.

Next, on the same system as the VM is running, use the following command to perform the attestation process
`client --disk-key <disk encryption pw> --vm-definition <vm config file>`
If you used the ID block during launch, you might also add the `--id-block-path <path to id-block.base64>` and `--author-block-path <path to auth-block.base64>` parameters, to verify the information from these blocks that are visible in the attestation report.
See `--help` for additional optional parameters. 
If the remote attestation succeeds, you should be able to SSH into your VM
on localhost:2222 shorty afterwards.

## References
[1] https://github.com/AMDESE/AMDSEV/tree/snp-latest
[2] https://www.youtube.com/watch?v=4wZnl0njxm8
