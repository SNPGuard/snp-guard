FROM ubuntu:22.04

# - kmod : required for insmod
# - lvm2, cryptsetup-bin : required to unlock encrypted disk
# - isc-dhcp-client : required to get ip via dhcp
# - iproute2 : installes the "ip" command. Useful for debugging network issues
# - rsync : for copying read-only directories to read-write RAM filesystems
# - openssh-client : for generating new SSH keys
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    kmod \
    lvm2 \
    cryptsetup-bin \
    isc-dhcp-client \
    iproute2 \
    rsync \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

ENV TZ=Europe/Berlin
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone