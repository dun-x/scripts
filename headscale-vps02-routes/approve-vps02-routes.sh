#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${CONTAINER:-headscale}"
NODE_IDENTIFIER="${NODE_IDENTIFIER:-vps02}"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
CONFIG="${1:-$SCRIPT_DIR/via-vps02.conf}"

if [ ! -r "$CONFIG" ]; then
  echo "Missing or unreadable config: $CONFIG" >&2
  exit 1
fi

resolve_node_id() {
  node_identifier="$1"

  if printf '%s\n' "$node_identifier" | grep -Eq '^[0-9]+$'; then
    printf '%s\n' "$node_identifier"
    return
  fi

  json="$(
    docker exec "$CONTAINER" headscale nodes list -o json 2>/dev/null || true
  )"
  if [ -n "$json" ]; then
    node_id=""

    if command -v jq >/dev/null 2>&1; then
      node_id="$(
        printf '%s\n' "$json" |
          jq -r --arg wanted "$node_identifier" '
            (if type == "array" then . else (.nodes // .machines // []) end)
            | .[]
            | select(
                (.name // "") == $wanted
                or (.given_name // "") == $wanted
                or (.hostname // "") == $wanted
              )
            | (.id // .ID)
          ' 2>/dev/null |
          awk 'NF { print; exit }'
      )"
    fi

    if [ -z "$node_id" ]; then
      node_id="$(
        printf '%s\n' "$json" |
          tr '\n' ' ' |
          sed 's/}[[:space:]]*,[[:space:]]*{/}\
{/g' |
          awk -v wanted="$node_identifier" 'index($0, "\"" wanted "\"") { print; exit }' |
          sed -n 's/^[^{]*{[[:space:]]*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p'
      )"
    fi

    if [ -n "$node_id" ]; then
      printf '%s\n' "$node_id"
      return
    fi
  fi

  node_id="$(
    docker exec "$CONTAINER" headscale nodes list |
      awk -v wanted="$node_identifier" '
        $0 ~ wanted {
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+$/) {
              print $i
              exit
            }
          }
        }
      '
  )"

  if [ -z "$node_id" ]; then
    echo "Could not resolve node identifier '$node_identifier' to a numeric Headscale node ID" >&2
    echo "Run: docker exec $CONTAINER headscale nodes list" >&2
    echo "Then retry with: NODE_IDENTIFIER=<ID_CUA_VPS02> $0" >&2
    exit 1
  fi

  printf '%s\n' "$node_id"
}

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

NODE_ID="$(resolve_node_id "$NODE_IDENTIFIER")"

echo "Approving routes for $NODE_IDENTIFIER (ID: $NODE_ID): $routes"
docker exec "$CONTAINER" headscale nodes approve-routes \
  --identifier "$NODE_ID" \
  --routes "$routes"
