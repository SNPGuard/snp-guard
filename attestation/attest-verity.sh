TMP_FILE=$(mktemp)
HOSTS_FILE=$(mktemp)
echo $HOSTS_FILE

# TODO get parameters here via CLI
VERIFY_REPORT_BIN=./build/bin/verify_report
VM_CONFIG=build/verity/vm-config-verity.toml
HOST=localhost
PORT=2222
USER=ubuntu

echo "Scanning $HOST:$PORT for SSH keys.."
ssh-keyscan -p $PORT $HOST > $TMP_FILE 2> /dev/null

echo "Fetching SSH key fingerprint.."
FINGERPRINT=$(ssh-keygen -lf $TMP_FILE | awk '{ print $2 }' | cut -d ":" -f 2)

# TODO ensure that only one key is present

echo "Fetching attestation report via SCP.."
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=$HOSTS_FILE -P $PORT $USER@$HOST:/etc/report.json /tmp/report.json

echo "Verifying attestation report.."
$VERIFY_REPORT_BIN --input /tmp/report.json --vm-definition $VM_CONFIG --report-data $FINGERPRINT

echo "Done! You can safely connect to the CVM as long as its fingerprint is $FINGERPRINT"