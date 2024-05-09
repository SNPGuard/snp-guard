#!/bin/bash
#Creates the central VM config file that is used by our launch
#scripts as well as our attestation tools
#Using a central config file guards against accidential missmatches
#in i.e. kernel cmdline or OVMF binary that lead to missmatching attestation values

set -e

OVMF_PATH=
KERNEL_PATH=
INITRD_PATH=
OUT_PATH=
KERNEL_CMDLINE=
TEMPLATE_PATH=
VERITY_HASH_FILE=
DEFAULT_OUT_PATH="./build/vm-config"

usage() {
  echo "$0 [options]"
  echo ""
  echo "-ovmf   <path to DIRECT_BOOT_OVMF.fd> [Mandatory]"
  echo "-kernel <path to vmlinuz>             [Mandatory]"
  echo "-initrd <path to initramfs.cpio.gz>   [Mandatory]"
  echo "-template <path to config template    [Mandatory]"
  echo "    See tools/attestation_server/examples "
  echo "-verity-hash-file <path to file with verity root hash> [Optional]"
  echo "  Due to makefile restrictions we need to read this from the shell script :("
  echo "-cmdline kernel cmdline parameters    [Optional]"
  echo "    E.g. to configure encrypted or dm-verity mode"
  echo "-out    <path to store config at>     [Defaults to $DEFAULT_OUT_PATH-{VERITY,LUKS}.toml]"
  echo ""
  exit
}

if [ $# -eq 0 ]; then
  usage
fi



while [ -n "$1" ]; do
  case "$1" in
    -ovmf) OVMF_PATH="$2"
      shift
      ;;
    -kernel) KERNEL_PATH="$2"
      shift
      ;;
    -initrd) INITRD_PATH="$2"
      shift
      ;;
    -cmdline) KERNEL_CMDLINE="$2"
      shift
      ;;
    -template) TEMPLATE_PATH="$2"
      shift
      ;;
    -verity-hash-file) VERITY_HASH_FILE="$2"
      shift
      ;;
    -out) OUT_PATH="$2"
        shift
        ;;
    *)
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ "$OUT_PATH" == "" ]]; then
    OUT_PATH="$DEFAULT_OUT_PATH-$MODE.toml"
fi


cp "$TEMPLATE_PATH" "$OUT_PATH"
sed -i "\@ovmf_file@c ovmf_file = \"${OVMF_PATH}\"" "$OUT_PATH"
sed -i "\@kernel_file@c kernel_file = \"${KERNEL_PATH}\"" "$OUT_PATH"
sed -i "\@initrd_file@c initrd_file = \"${INITRD_PATH}\"" "$OUT_PATH"

if [[ "$VERITY_HASH_FILE" != "" ]]; then
  KERNEL_CMDLINE="verity_roothash=$(cat $VERITY_HASH_FILE) $KERNEL_CMDLINE"
fi

if [[ "$KERNEL_CMDLINE" != "" ]]; then
    sed -i "\@kernel_cmdline@c kernel_cmdline = \"${KERNEL_CMDLINE}\"" "$OUT_PATH"
fi
     
echo "Written config to $OUT_PATH"