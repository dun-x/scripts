#!/bin/bash

docker images --format '{{.Repository}}:{{.Tag}}' | xargs -L 1 docker pull
docker images -q -f dangling=true | xargs docker rmi