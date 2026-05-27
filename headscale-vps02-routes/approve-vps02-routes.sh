#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${CONTAINER:-headscale}"
NODE_IDENTIFIER="${NODE_IDENTIFIER:-vps02}"
CONFIG="${1:-/etc/tailscale-routes/via-vps02.conf}"

if [ ! -r "$CONFIG" ]; then
  echo "Missing or unreadable config: $CONFIG" >&2
  exit 1
fi

mapfile -t domains < <(awk -F= '/^DOMAIN=/{print $2}' "$CONFIG" | sed '/^$/d')
mapfile -t manual_routes < <(awk -F= '/^ROUTE=/{print $2}' "$CONFIG" | sed '/^$/d')

routes="$(
  {
    for domain in "${domains[@]}"; do
      getent ahostsv4 "$domain" | awk '{print $1}' | sed 's#$#/32#'
    done
    printf '%s\n' "${manual_routes[@]}"
  } | awk 'NF' | sort -u | paste -sd, -
)"

if [ -z "$routes" ]; then
  echo "No routes to approve" >&2
  exit 1
fi

echo "Approving routes for $NODE_IDENTIFIER: $routes"
docker exec "$CONTAINER" headscale nodes approve-routes \
  --identifier "$NODE_IDENTIFIER" \
  --routes "$routes"
