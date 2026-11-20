#!/usr/bin/env bash
# Gate for the Caddy config: format, validate in the pinned image with throwaway
# certificates and empty /srv roots, then the edge policy on the adapted JSON.
# CI runs it on every pull request; the deploy workflow runs it again before shipping.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

readonly CADDY_IMAGE=caddy@sha256:4851e54a46b206517c574821bb5cc67f170d2156041e9fbc4c9193b45e84a75b

fixtures=$(mktemp -d)
trap 'rm -rf "$fixtures"' EXIT
mkdir -p "$fixtures/certs" "$fixtures/srv" "$fixtures/log"

echo "::group::caddy fmt"
docker run --rm -v "$PWD:/work:ro" -w /work "$CADDY_IMAGE" caddy fmt --diff Caddyfile
echo "::endgroup::"

echo "::group::throwaway certificates and /srv roots"
grep -oE '/etc/caddy/certs/[A-Za-z0-9._-]+' Caddyfile | sed -E 's#.*/##; s/\.(pem|key)$//' | sort -u |
    while read -r stem; do
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
            -subj "/CN=$stem.invalid" \
            -keyout "$fixtures/certs/$stem.key" -out "$fixtures/certs/$stem.pem" >/dev/null 2>&1
    done
grep -oE '/srv/[A-Za-z0-9._-]+' Caddyfile | sort -u | while read -r root; do
    mkdir -p "$fixtures/srv/${root#/srv/}"
done
echo "::endgroup::"

echo "::group::caddy validate"
docker run --rm \
    -e "OPS_USER_1_EMAIL=${OPS_USER_1_EMAIL:-ops1@example.invalid}" \
    -e "OPS_USER_2_EMAIL=${OPS_USER_2_EMAIL:-ops2@example.invalid}" \
    -e "OPS_USER_3_EMAIL=${OPS_USER_3_EMAIL:-ops3@example.invalid}" \
    -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v "$fixtures/certs:/etc/caddy/certs:ro" \
    -v "$fixtures/srv:/srv:ro" \
    -v "$fixtures/log:/var/log/caddy" \
    "$CADDY_IMAGE" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
echo "::endgroup::"

echo "::group::edge policy"
scripts/adapt.sh Caddyfile >"$fixtures/adapt.json"
scripts/policy.sh "$fixtures/adapt.json" smoke/baseline.txt
echo "::endgroup::"
