FROM ubuntu:22.04

WORKDIR /usr/src/app

# install dependencies
RUN apt update && \
    apt install -y --no-install-recommends \
    # general dependencies
    build-essential \
    git \
    # additional dependencies for QEMU
    python3 \
    python3-venv \
    ninja-build \
    libglib2.0-dev \
    # additional dependencies for OVMF
    uuid-dev \
    iasl \
    nasm \
    python-is-python3 \
    # additional dependencies for linux kernel
    flex \
    bison \
    openssl \
    libssl-dev \
    libelf-dev \
    bc \
    libncurses-dev \
    gawk \
    dkms \
    libudev-dev \
    libpci-dev \
    libiberty-dev \
    autoconf \
    llvm \
    cpio \
    zstd \
    && rm -rf /var/lib/apt/lists/*

# clone repository
RUN git clone https://github.com/AMDESE/AMDSEV.git --branch snp-latest --depth 1

# patch repository to build custom OVMF
COPY 0001-build-direct-boot-ovmf.patch ovmf.patch
RUN cd AMDSEV && git apply ../ovmf.patch

# run build command
WORKDIR /usr/src/app/AMDSEV
CMD ["./build.sh"]