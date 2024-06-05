#!/bin/bash

set -e

TMP_FILE=$(mktemp)
echo $HOSTS_FILE

SCRIPT_DIR=$(dirname $0)
VERIFY_REPORT_BIN=$(realpath $SCRIPT_DIR/../build/bin/verify_report)
SSH_HOSTS_FILE=$(realpath $SCRIPT_DIR/../build/known_hosts)

VM_CONFIG=""
HOST=localhost
PORT=2222
USER=ubuntu

IN_REPORT=/etc/report.json
OUT_REPORT=build/verity/attestation_report.json

usage() {
  echo "$0 [options]"
  echo " -vm-config <path>                      path to VM config file [Mandatory]"
  echo " -host <string>                         hostname or IP address of the VM (default: $HOST)"
  echo " -port <int>                            SSH port of the VM (default: $PORT)"
  echo " -user <string>                         VM user to login to (default: $USER)"
  echo " -out <path>                            Path to output attestation report (default: $OUT_REPORT)"
  exit
}

while [ -n "$1" ]; do
	case "$1" in
		-vm-config) VM_CONFIG="$2"
			shift
			;;
		-host) HOST="$2"
			shift
			;;
		-port) PORT="$2"
			shift
			;;
		-user) USER="$2"
			shift
			;;
		-out) OUT_REPORT="$2"
			shift
			;;
		*) 		usage
				;;
	esac

	shift
done

if [ ! -f "$VM_CONFIG" ]; then
    echo "Invalid VM config file: $VM_CONFIG"
    usage
fi

# clean up known_hosts file before running the script
rm -rf $SSH_HOSTS_FILE

echo "Fetching attestation report via SCP.."
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=$SSH_HOSTS_FILE -P $PORT $USER@$HOST:$IN_REPORT $OUT_REPORT || {
    echo "Failed to connect to VM"
	rm -rf $SSH_HOSTS_FILE
    exit 1
}

echo "Verifying attestation report.."
FINGERPRINT=$(ssh-keygen -lf $SSH_HOSTS_FILE | awk '{ print $2 }' | cut -d ":" -f 2)
$VERIFY_REPORT_BIN --input $OUT_REPORT --vm-definition $VM_CONFIG --report-data $FINGERPRINT || {
	echo "Failed to attest the VM"
	rm -rf $SSH_HOSTS_FILE
	exit 1
}

echo "Done! You can safely connect to the CVM using the following command:"
echo "ssh -p $PORT -o UserKnownHostsFile=$SSH_HOSTS_FILE $USER@$HOST"
echo "Guest SSH fingerprint: $(ssh-keygen -lf $SSH_HOSTS_FILE | awk '{ printf ("%s %s", $2, $4) }' )"