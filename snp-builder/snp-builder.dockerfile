FROM ubuntu:22.04

WORKDIR /usr/src/app

# install dependencies
COPY dependencies.txt .
RUN apt update && \
    xargs -a dependencies.txt apt install -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# copy OVMF patch
COPY 0001-build-direct-boot-ovmf.patch ovmf.patch

# copy run script
COPY snp-builder/run.sh .

CMD ["./run.sh"]