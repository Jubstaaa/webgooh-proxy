#!/usr/bin/env bash
# Prints the caddy adapt JSON for a Caddyfile, using the image the droplet runs.
# Usage: scripts/adapt.sh <path/to/Caddyfile>
set -Eeuo pipefail

readonly CADDY_IMAGE=caddy@sha256:4851e54a46b206517c574821bb5cc67f170d2156041e9fbc4c9193b45e84a75b

file=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
docker run --rm -e "OPS_USER_1_EMAIL=${OPS_USER_1_EMAIL:-ops1@example.invalid}" \
    -e "OPS_USER_2_EMAIL=${OPS_USER_2_EMAIL:-ops2@example.invalid}" \
    -e "OPS_USER_3_EMAIL=${OPS_USER_3_EMAIL:-ops3@example.invalid}" \
    -v "$file:/etc/caddy/Caddyfile:ro" "$CADDY_IMAGE" \
    caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile
