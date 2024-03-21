FROM ubuntu:22.04

# - kmod : required for insmod
# - lvm2, cryptsetup-bin : required to unlock encrypted disk
# - isc-dhcp-client : required to get ip via dhcp
# - iproute2 : installes the "ip" command. Useful for debugging network issues
RUN apt-get update && \
    apt-get install -y kmod lvm2 cryptsetup-bin isc-dhcp-client iproute2 && rm -rf /var/lib/apt/lists/*

ENV TZ=Europe/Berlin
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone


# COPY ./hacky-testdata/linux-headers-6.7.0-snp-guest-98543c2aa649_6.7.0-g98543c2aa649-2_amd64.deb kernel-headers.deb
# COPY ./hacky-testdata/linux-image-6.7.0-snp-guest-98543c2aa649_6.7.0-g98543c2aa649-2_amd64.deb kernel.deb

# RUN dpkg -i ./kernel-headers.deb ./kernel.deb
# RUN rm kernel-headers.deb && rm kernel.deb && rm -rf /var/lib/apt/lists/*
