#!/bin/bash

while true; do
    if [ "$(docker info -f "{{.OSType}}" 2> /dev/null)" ]; then
        echo "Docker running"
        break
    fi
    sleep 10
done

echo "Restarting"
for service in $(docker compose ls --format=json | jq -rc ".[] .ConfigFiles"); do
    docker compose --file "$service" restart &
done
