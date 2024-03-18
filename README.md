# Build

You need to add paths to the following files to the `ROOTFS_EXTRA_FILES` env var
- virtio_scsi.ko
- tsm.ko
- sev-guest.ko
- dm-crypt.ko
- e1000.ko

You can obtain these files by unpacking the .deb package for the kernel with `dpkg -x`
