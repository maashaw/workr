#!/bin/bash

# This is basically a hacky sort of pseudo cloud-init lookalike for customising template VMs to create new instances
# It makes lots of assumptions about how your machine has been set up, and there is no guarantee that it will be useful for your use cases
# The assumptions are essentially
# 1. Ubuntu 22.04 minimised server install
# 2. Default disk layout with LUKS2 encryption enabled
# 3. You intend to use Clevis for automated decryption, and have a clevis policy in mind
# NB this script intends for you to supply two public keys - a URL to a key, and a literal.
# If you don't want to supply a literal, define the string as empty
# But the intention is that you want to be able to access the worker from your dev machine as well as your RServer instance.
#
# This script assumes that you have created files with the names below in the current directory
# old.pw        - The current (template) LUKS2 password
# new.pw        - The new LUKS2 password (should be unique for each instance)
# login.pw      - The new account password (should be unique for each instance)
# hostname.txt  - The intended hostname of this instance (should be unique for each instance)
# ip.txt        - The intended IP and subnet for this instance (e.g. 192.168.64.1/16 - should be unique for each instance)
# dns.txt       - The intended DNS server for this instance (e.g. 192.168.1.1)
# interface.txt - The interface name. Try using "ip route show default | awk '{print $5}' > interface.txt" to guess automatically
# key.pub       - A public key for a machine you want to use to access the R Worker
# key.url       - The URL of a public key (try using "https://github.com/[username].keys" to use your github ssh key)
# R.pkgs        - A list of R packages to install on the RServer at setup (with escaped quotes - e.g. c(\"future\", \"furrr\"))

# Set variables
LOGIN_PW=$(cat login.pw)
HOSTNAME=$(cat hostname.txt)
IP=$(cat ip.txt)
DNS=$(cat dns.txt)
INTERFACE=$(cat interface.txt)
KEY_PUB=$(cat key.pub)
KEY_URL=$(cat key.url)
CLEVIS_POLICY=$(cat clevis.policy)
R_PKGS=$(cat R.pkgs)

# Create folders for docker
mkdir -p ~/rstudio
mkdir -p ~/data

# Write out docker compose file
cat > ~/rstudio/docker-compose.yml << EOF
services:
  rstudio:
    image: rocker/geospatial:4.4.2
    ports:
      - 80:8787
      - 2222:22
    environment:
      ROOT: 'true'
      PASSWORD: rstudio-docker
    restart: unless-stopped
    command: >
      /bin/sh -c "apt-get update &&
      apt-get install -y openssh-server curl gpg &&
      mkdir -p var/run/sshd &&
      echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config &&
      echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config &&
      echo 'pubkeyAuthentication yes' >> /etc/ssh/sshd_config &&
      curl -L "$KEY_URL" -o /home/rstudio/.ssh/authorized_keys &&
      echo "$KEY_PUB" | sudo tee -a /home/rstudio/.ssh/authorized_keys &&
      chmod 600 /home/rstudio/.ssh/authorized_keys &&
      chown rstudio:rstudio /home/rstudio/.ssh/authorized_keys &&
      service ssh start &&
      R -q -e 'install.packages($R_PKGS)' &&
      exec /init"
    volumes:
      - /home/$(whoami)/data/rstudio/ssh:/home/rstudio/.ssh
      - /home/$(whoami)/data/rstudio/gpg:/home/rstudio/.gnupg
EOF

# Add docker repo and key to sources
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Add tailscale repo and key to sources
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | \
    sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list | \
    sudo tee /etc/apt/sources.list.d/tailscale.list

# Install neccessary packages
sudo apt update
sudo apt upgrade -y
sudo apt install -y \
    qemu-guest-agent \
    nano \
    tailscale \
    avahi-daemon avahi-discover avahi-utils \
    clevis clevis-luks clevis-initramfs \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Reset LUKS keys
sudo cryptsetup luksChangeKey /dev/sda3 -d ./old.pw ./new.pw

# Regenerate the volume encryption key
sudo cryptsetup reencrypt /dev/sda3 -d ./new.pw --key-slot 0

# Set up clevis for automatic policy-based decryption
sudo clevis luks bind -y -d /dev/sda3 -k ./new.pw sss "$CLEVIS_POLICY"

# Set up serial port
sudo sed -i.bak '/^GRUB_CMDLINE_LINUX/ s/^/#/' /etc/default/grub
cat <<EOF | sudo tee -a /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8"
GRUB_CMDLINE_LINUX="console serial"
GRUB_SERIAL_COMMAND="serial --unit=0 speed=115200 word=8 --parity=no --stop=1"
EOF
sudo update-grub

# Update initramfs to load up clevis components
sudo update-initramfs -u -k 'all'

# Set a new hostname so it's be updated on next boot
sudo hostnamectl set-hostname $HOSTNAME

# Update the login password
sudo echo "$(whoami):$LOGIN_PW" | sudo chpasswd

# Set the static IP and DNS details
sudo netplan set ethernets.$INTERFACE.addresses=[$IP]
sudo netplan set ethernets.$INTERFACE.nameservers.addresses=[$DNS]
sudo netplan apply

# Remove existing SSH keys and generate new ones
rm /etc/ssh/ssh_host_*
sudo ssh-keygen -f /etc/ssh/ssh_host_ed25519_key -N '' -t ed25519
sudo ssh-keygen -f /etc/ssh/ssh_host_rsa_key -N '' -t rsa -b 4096
sudo ssh-keygen -f /etc/ssh/ssh_host_ecdsa_key -N '' -t ecdsa

# Clear the machine ID so it's regenerated on next boot
sudo truncate -s0 /etc/machine-id 
sudo rm /var/lib/dbus/machine-id
sudo ln -s /etc/machine-id /var/lib/dbus/machine-id

# Delete the params
sudo shred -u old.pw new.pw login.pw hostname.txt ip.txt dns.txt interface.txt key.pub key.url clevis.policy R.pkgs

# clear the bash history so it's nice and clean
history -c
history -w

# start the docker container
sudo docker compose up -d

# reboot
sudo reboot -n
