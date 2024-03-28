#!/bin/bash
# Create a new VM disk based on ubuntu cloud image as well as an
# cloud init "config blob". The VM has to be started once, with the 
# config blob as VM disk as drive -hda and the config blow as drive -hdb
# This will apply the config
set -e 


BASE_DISK="/tmp/jammy-server-base.qcow2"
NEW_VM=
#size of the qcow2 disk image in GB
SIZE=20
OWNER_PUBKEY_PATH=""
#Path to private key. public key is expected to be in the same directory, using the .pub extension
SERVER_PRIVKEY_PATH=""
SERVER_PUBKEY_PATH=""

usage() {
  echo "Usage:"
  echo "$0 [options]"
  echo "-out-vm-image PATH.qcow2    [Mandatory] Output path for the VM image. Must end in .qcow2"
  echo "-size INTEGER               [Optional]  Size for the qcow2 disk image in GB. Defaults to 20"
  echo "-owner-pubkey PATH          [Optional]  Path to SSH public key that gets added to authorized keys. If not specified, we generate a new keypair"
  echo "-server-privkey PATH       [Optional]  Path to SSH private key that is used for the OpenSSH server. If not specified, we generate a new keypair"
}


while [ -n "$1" ]; do
  case "$1" in
    -out-vm-image) NEW_VM="$2"
      shift
      ;;
    -owner-pubkey) OWNER_PUBKEY_PATH="$2"
      shift
      ;;
    -server-privkey)
      SERVER_PRIVKEY_PATH="$2"
      SERVER_PRIVKEY_PATH="${2}.pub"
      shift
      ;;
    -size)
      SIZE="$2"
      shift
      ;;
    *)
      usage
      exit
      ;;
  esac
  shift
done

if [ -z "$NEW_VM" ]; then
  echo "-out-vm-image is a mandatory parameter"
  usage
  exit 1
fi


#Download base image
if [ ! -f "$BASE_DISK" ]; then
  wget -O "$BASE_DISK" https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
fi


#Create a copy with a larger disk. Note that qcow2 is lazy allocated, i.e. this
#does not produce a 20G file
qemu-img create -f qcow2 -F qcow2 -b "$BASE_DISK" "$NEW_VM" "${SIZE}G"

#If no pubkeys where specified, generate them
if [ -z "$OWNER_PUBKEY_PATH" ]; then
  DEFAULT_PATH="$(dirname $NEW_VM)/ssh-key-vm-owner"
  echo "No owner public ssh key provided. Generating a new keypair at $DEFAULT_PATH"
  ssh-keygen -t ed25519 -N "" -f "$DEFAULT_PATH"
  OWNER_PUBKEY_PATH="${DEFAULT_PATH}.pub"
fi

if [ -z "$SERVER_PRIVKEY_PATH" ]; then
  DEFAULT_PATH="$(dirname $NEW_VM)/ssh-server-key-vm"
  echo "No server ssh key provided. Generating a new keypair at $DEFAULT_PATH"
  ssh-keygen -t ecdsa -N "" -f "$DEFAULT_PATH"
  SERVER_PRIVKEY_PATH="$DEFAULT_PATH"
  SERVER_PUBKEY_PATH="${DEFAULT_PATH}.pub"
fi

#Query Username and password
echo "Enter usename"
read -r USERNAME

echo "Enter Password"
PWHASH=$(mkpasswd --method=SHA-512 --rounds=4096)


#Create cloud-init "user-data" config based on template
echo "Creating config file"
#$0 gives path to script itself
cp "$(dirname $0)/template-user-data" user-data
sed -i "s#<USER>#$USERNAME#g" user-data
sed -i "s#<PWDHASH>#$PWHASH#g" user-data
USER_PUBKEY=$(cat "$OWNER_PUBKEY_PATH")
sed -i "s#<USER_PUBKEY>#$USER_PUBKEY#g" user-data
# SERVER_PRIVKEY=$(cat "$SERVER_PRIVKEY_PATH")
# sed -i "s#<SERVER_PRIVKEY>#$SERVER_PRIVKEY#g" user-data
#Dirty hack to get all lines of our private key to be indented by 4 whitespaces
#1) copy to file
#2) replace each linestart with 4 whitespaces
#3) append key after the "ecda_private: |" line in the config template
TMP=$(mktemp)
cp $SERVER_PRIVKEY_PATH $TMP
sed -i 's#^#    #' $TMP
sed -i "/^ *ecdsa_private: |/r $TMP" user-data
rm $TMP
# awk -v r="$SERVER_PRIVKEY" '{gsub(/<SERVER_PRIVKEY>/,r)}1' 
SERVER_PUBKEY=$(cat "$SERVER_PUBKEY_PATH")
sed -i "s#<SERVER_PUBKEY>#$SERVER_PUBKEY#g" user-data

OUT_CFG_BLOB="$(dirname $NEW_VM)/config-blob.img"
echo "Writing config blow to $OUT_CFG_BLOB"
touch meta-data
touch network-config
genisoimage \
    -output "$OUT_CFG_BLOB" \
    -volid cidata -rational-rock -joliet \
    user-data meta-data network-config
