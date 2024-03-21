#!/bin/sh

if [ -z "${DEPLOY_URI}" ]; then
    echo "Please define  DEPLOY_URI"
	exit -1
fi
printf "\n\n###\nDeploying to ${DEPLOY_URI}\n###\n\n"
scp ./build/binaries/initramfs.cpio.gz  \
./attestation_server/target/debug/idblock-generator \
./attestation_server/target/debug/sev-feature-info \
./openend2e-launch.sh \
./attestation_server/target/debug/client ${DEPLOY_URI}
