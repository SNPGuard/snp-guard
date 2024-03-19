# OPEN-E2E-SEVSNP-WORKFLOW

# Build

You need to add paths to the following files to the `ROOTFS_EXTRA_FILES` env var
- virtio_scsi.ko
- tsm.ko
- sev-guest.ko
- dm-crypt.ko
- virtio_net.ko
- net_failover.ko
- failover.ko

You can obtain these files by unpacking the .deb package for the kernel with `dpkg -x`

## Usage

TODO: general setup
TODO: setup VM image

### Generate Config File
You have to create a config file that describes your VM.
Use the `config-generator` tool to generate a sane default config and tweak it

### (Optional) Generate an ID Block and an Auth block
The ID block and an ID authentication information structure allow you to pass some user defined data to describe/identify the
VM, as well as the public parts of the ID key and the author key. All of this information will be reflected
in the attestation report. In addition, the ID block will trigger an early check of the launch digest before entering the VM
Otherwise, the LD will only be checked at runtime, during the attestation handshake described later in this document.

Use the following command generate an ID block and an auth block files for usage with QEMU:
`./idblock-generator --vm-definition vm-config.json --id-key-path id_key.pem --auth-key-path author_key.pem`

Both ID key and author key are user defined keys. The ID key signs the ID block and the author key signs the ID key.
This enables you to use a different ID key for each VM while this reflecting that all VMs belong to the same VM owner/author.
Bot keys need to be in the PKCS8 PEM format. You can generate them with
`openssl ecparam -name secp384r1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out private_key.pem`
The second part is needed as there are two sub variants for PEM and the default one used
by OpenSSL cannot be parsed by the library that we used (apparently the PKCS8 one is also the
better variant)


### Start the VM
Use the following command to start the VM
`sudo ./launch-qemu.sh -kernel bzImage -initrd initramfs.cpio.gz -sev-snp -hda ./encrypted-snp-guest.qcow2 -append <kernel commandline args>`
If you want to use the optional ID block, also add the following parameters
`-id-block id-block.base64 -id-auth auth-block.base64`
