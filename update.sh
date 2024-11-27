#!/bin/bash
DOCKER=/usr/bin/docker
DOCKERCOMPOSE=/usr/local/bin/docker-compose
APT=/usr/bin/apt

sudo $APT update && sudo $APT upgrade -y && sudo $APT autoremove -y

sudo killall snap-store
sudo snap refresh snap-store

#$DOCKERCOMPOSE pull && $DOCKERCOMPOSE down && $DOCKERCOMPOSE up -d && $DOCKER system prune -a -f

