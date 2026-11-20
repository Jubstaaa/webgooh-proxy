#!/usr/bin/env bash
# Prints the caddy adapt JSON for a Caddyfile, using the image the droplet runs.
# Usage: scripts/adapt.sh <path/to/Caddyfile>
set -Eeuo pipefail

readonly CADDY_IMAGE=caddy@sha256:4851e54a46b206517c574821bb5cc67f170d2156041e9fbc4c9193b45e84a75b

file=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
docker run --rm -e "BESZEL_ALLOWED_EMAILS=${BESZEL_ALLOWED_EMAILS:-ci@example.invalid}" \
    -v "$file:/etc/caddy/Caddyfile:ro" "$CADDY_IMAGE" \
    caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile
