#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
CONFIG="${1:-$SCRIPT_DIR/via-vps02.conf}"

if [ ! -r "$CONFIG" ]; then
  echo "Missing or unreadable config: $CONFIG" >&2
  exit 1
fi

mapfile -t domains < <(awk -F= '/^DOMAIN=/{print $2}' "$CONFIG" | sed '/^$/d')
mapfile -t manual_routes < <(awk -F= '/^(ROUTE|EXTRA_ROUTE)=/{print $2}' "$CONFIG" | sed '/^$/d')

resolved_routes="$(
  {
    for domain in "${domains[@]}"; do
      getent ahostsv4 "$domain" | awk '{print $1}' | sed 's#$#/32#'
    done
  } | sort -u
)"

routes="$(
  {
    printf '%s\n' "$resolved_routes"
    printf '%s\n' "${manual_routes[@]}"
  } | awk 'NF' | sort -u | paste -sd, -
)"

if [ -z "$routes" ]; then
  echo "No routes to advertise" >&2
  exit 1
fi

echo "Advertising routes: $routes"
sudo tailscale set --advertise-routes="$routes"
