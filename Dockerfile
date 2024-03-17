FROM ubuntu:22.04

ENV TZ=Europe/Berlin
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Update package lists and install kmod
RUN apt-get update && \
    apt-get install -y kmod lvm2 cryptsetup-bin && rm -rf /var/lib/apt/lists/*

# COPY ./hacky-testdata/linux-headers-6.7.0-snp-guest-98543c2aa649_6.7.0-g98543c2aa649-2_amd64.deb kernel-headers.deb
# COPY ./hacky-testdata/linux-image-6.7.0-snp-guest-98543c2aa649_6.7.0-g98543c2aa649-2_amd64.deb kernel.deb

# RUN dpkg -i ./kernel-headers.deb ./kernel.deb
# RUN rm kernel-headers.deb && rm kernel.deb && rm -rf /var/lib/apt/lists/*
