#!/bin/bash
/mnt/c/Windows/System32/wsl.exe --mount --vhd "E:\WSL\wsl_ubuntu.vhdx" --partition 2 --type ext4 --name hdd
sudo mount --bind /mnt/wsl/hdd /home/dunx/Desktop/hdd
