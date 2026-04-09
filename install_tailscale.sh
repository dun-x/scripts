#!/bin/bash
user=$(whoami)
source /home/$USER/Desktop/scripts/.env

# Detect OS and Version Codename
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    CODENAME=$VERSION_CODENAME
else
    echo "Cannot detect OS. /etc/os-release not found."
    exit 1
fi

if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
    echo "Unsupported OS: $OS. Only Ubuntu and Debian are supported."
    exit 1
fi

if [[ "$CODENAME" != "jammy" && "$CODENAME" != "noble" && "$CODENAME" != "bookworm" && "$CODENAME" != "trixie" ]]; then
    echo "Unsupported version: $CODENAME. Supported versions: jammy, noble, bookworm, trixie."
    exit 1
fi

# Add Tailscale's GPG key
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL "https://pkgs.tailscale.com/stable/${OS}/${CODENAME}.noarmor.gpg" | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null

# Add the tailscale repository
curl -fsSL "https://pkgs.tailscale.com/stable/${OS}/${CODENAME}.tailscale-keyring.list" | sudo tee /etc/apt/sources.list.d/tailscale.list

# Install Tailscale
sudo apt-get update && sudo apt-get install tailscale -y

# Start Tailscale!
sudo tailscale up --login-server $headscale_server
