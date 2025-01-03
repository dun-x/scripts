#!/bin/bash
DOCKER=/usr/bin/docker
DOCKERCOMPOSE=/usr/local/bin/docker-compose
APT=/usr/bin/apt

echo "---> Updating system"
sudo $APT update && sudo $APT upgrade -y && sudo $APT autoremove -y
echo -e "\n"

echo "---> Updating Container"
for service in $(docker compose ls --format=json | jq -rc ".[] .ConfigFiles"); do
    $DOCKER compose --file "$service" pull
    $DOCKER compose --file "$service" up -d
done
$DOCKER image prune -f
echo -e "\n"

echo "---> Updating Snap Store"
sudo killall snap-store
sudo snap refresh snap-store