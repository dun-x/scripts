#!/bin/bash
user=$(whoami)
source /home/$USER/Desktop/scripts/parameter.sh

# Add Tailscale's GPG key
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list
# Install Tailscale
sudo apt-get update && sudo apt-get install tailscale -y
# Start Tailscale!
sudo tailscale up --login-server $headscale_server


