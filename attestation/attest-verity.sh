#!/bin/bash

set -e

TMP_FILE=$(mktemp)
HOSTS_FILE=/dev/null

SCRIPT_DIR=$(dirname $0)
VERIFY_REPORT_BIN=$(realpath $SCRIPT_DIR/../build/bin/verify_report)

VM_CONFIG=""
HOST=localhost
PORT=2222
USER=ubuntu

IN_REPORT=/etc/report.json
OUT_REPORT=/tmp/report.json

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

echo "Scanning $HOST:$PORT for SSH keys.."
ssh-keyscan -p $PORT $HOST > $TMP_FILE 2> /dev/null || {
    echo "Host is unreachable or no SSH server running at port $PORT"
    exit 1
}

echo "Fetching SSH key fingerprint.."
KEYS="$(ssh-keygen -lf $TMP_FILE)"
NUM_KEYS=$(echo "$KEYS" | wc -l)

if [ $NUM_KEYS = "0" ]; then
	echo "Could not find SSH host keys"
	exit 1
elif [ ! $NUM_KEYS = "1" ]; then
	echo "$KEYS"
	read -p "Choose SSH key (indicate algorithm): " KEY
	KEYS=$(echo "$KEYS" | grep -i "($KEY)") || {
		echo "Invalid key"
		exit 1
	}
fi

FINGERPRINT=$(echo $KEYS | grep ECDSA | awk '{ print $2 }' | cut -d ":" -f 2)

echo "Fetching attestation report via SCP.."
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=$HOSTS_FILE -P $PORT $USER@$HOST:$IN_REPORT $OUT_REPORT 2> /dev/null || {
    echo "Failed to connect to VM"
    exit 1
}

echo "Verifying attestation report.."
$VERIFY_REPORT_BIN --input /tmp/report.json --vm-definition $VM_CONFIG --report-data $FINGERPRINT

echo "Done! You can safely connect to the CVM as long as its SSH fingerprint is:"
echo "$KEYS"