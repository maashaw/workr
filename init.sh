#!/bin/bash

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
sudo cryptsetup reencrypt /dev/sda3 -d ./new.pw

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
