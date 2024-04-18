# Patches to AMDSEV repository

These patches are applied to the AMDSEV repository, making necessary changes and
adjustments to scripts and configuration files in order to support our
workflows.

Note: some of these patches may not work in future versions of the AMDSEV repo.
Last commit checked: `111ad2cc8dfdbbcc687284ad0d24b7ed637fff2c`.

## `common.sh`

### `0001-build-direct-boot-ovmf.patch`

This patch changes the OVMF build process by building the
`OvmfPkg/AmdSev/AmdSevX64.dsc` image instead of `OvmfPkg/OvmfPkgX64.dsc`. The
resulting OVMF image is capable of performing measured boot by measuring kernel
hashes.

## `launch-qemu.sh`

### `0001-update-launch-qemu.sh-to-enable-OVMF-kernel-hashes.patch`

This patch is a consequence of ``0001-build-direct-boot-ovmf.patch`, and is
needed to select the correct OVMF image and enable kernel measurements.

By default, if the kernel is passed as parameter to `launch-qemu.sh`, then
measured boot will be enabled.

### `0001-mapping-ports-22-2222-and-80-8080.patch`

This patch exposes ports 22 and 80 of the guest VM to 2222 and 8080,
respectively. This allows for SSH connections and also allows the guest to run a
HTTP server which will be reachable via the host.

Note: Alternatively, it is also possible to setup a bridge network, as done
[here](https://github.com/AMDESE/linux-svsm/blob/main/scripts/launch-qemu.sh#L87)

### `0001-mount-secondary-hard-disk.patch`

This patch mounts a secondary hard disk to the guest VM, if specified. This is
needed, for example, to mount the `dm-verity` data disk containing the Merkle
tree.