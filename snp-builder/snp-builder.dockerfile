FROM ubuntu:22.04

WORKDIR /usr/src/app

# install dependencies
COPY dependencies.txt .
RUN apt update && \
    xargs -a dependencies.txt apt install -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# Install libslirp 4.7.1 packages, needed to enable user networking in QEMU
ARG LIBSLIRP=http://se.archive.ubuntu.com/ubuntu/pool/main/libs/libslirp/libslirp0_4.7.0-1_amd64.deb
ARG LIBSLIRP_DEV=http://se.archive.ubuntu.com/ubuntu/pool/main/libs/libslirp/libslirp-dev_4.7.0-1_amd64.deb
RUN wget $LIBSLIRP -O libslirp0.deb \
    && wget $LIBSLIRP_DEV -O libslirp-dev.deb \
    && dpkg -i libslirp0.deb \
    && dpkg -i libslirp-dev.deb

# copy patches
COPY patches/ patches/

# copy stable commits
COPY snpguard-stable-commits.txt stable-commits.txt

# copy run script
COPY run.sh .

CMD ["./run.sh"]