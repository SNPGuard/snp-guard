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