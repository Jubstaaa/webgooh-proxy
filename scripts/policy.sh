#!/usr/bin/env bash
# Edge policy for caddy adapt JSON.
#   policy.sh <adapt.json> <baseline.txt>  enforce the policy; exit 1 on violations
#   policy.sh --hosts <adapt.json>         print the public hostnames, sorted
set -Eeuo pipefail

readonly EXEMPT='["acwistanbul.com","www.acwistanbul.com","localhost"]'
readonly UPSTREAM='^(127\.0\.0\.1|localhost):[0-9]+$'

hostnames() {
    jq -r '[.apps.http.servers[].routes[]?.match[]?.host[]?] | unique | .[]' "$1" | grep -v '^localhost$' | sort
}

if [[ ${1:-} == --hosts ]]; then
    hostnames "$2"
    exit 0
fi

json=$1
baseline=$2
violations=0

if ! diff <(hostnames "$json") <(awk 'NF { print $1 }' "$baseline" | sort) >/dev/null; then
    echo "::error::hostnames in the Caddyfile differ from smoke/baseline.txt; update the baseline in the same change"
    diff <(hostnames "$json") <(awk 'NF { print $1 }' "$baseline" | sort) || true
    violations=1
fi

no_cfonly=$(jq -r --argjson exempt "$EXEMPT" '
    .apps.http.servers[].routes[]?
    | select(.match? != null)
    | [.match[].host[]?] as $hosts
    | select(any($hosts[]; . as $h | ($exempt | index($h)) == null))
    | select(
        ([.. | objects | select(.abort? == true)] | length) == 0
        or ([.. | objects | select(has("not")) | .not[]? | select(has("remote_ip"))] | length) == 0
      )
    | $hosts | join(",")' "$json")
if [[ -n $no_cfonly ]]; then
    echo "::error::sites without the cfonly origin lock: $no_cfonly"
    violations=1
fi

bad_upstreams=$(jq -r --arg re "$UPSTREAM" '
    [.. | objects | select(.handler? == "reverse_proxy") | .upstreams[]?.dial]
    | map(select(test($re) | not)) | join(" ")' "$json")
if [[ -n $bad_upstreams ]]; then
    echo "::error::reverse_proxy upstreams outside 127.0.0.1/localhost: $bad_upstreams"
    violations=1
fi

# Named accounts are decided by the email Cloudflare Access sets. Only an exact match
# on non-empty values is allowed: a regex assembled from host-only values is one
# unescaped character away from matching more than intended, and an empty value
# would turn the matcher into "header present".
loose_identity=$(jq -r '
    [.. | objects
        | (select(has("header_regexp")) | .header_regexp | objects | keys[]
            | select(ascii_downcase == "cf-access-authenticated-user-email") | "header_regexp"),
          (select(has("header")) | .header | objects | to_entries[]
            | select(.key | ascii_downcase == "cf-access-authenticated-user-email")
            | select((.value // []) | length == 0 or any(. == "" or test("[*]")))
            | "empty or wildcard header value")]
    | unique | join(", ")' "$json")
if [[ -n $loose_identity ]]; then
    echo "::error::loose match on Cf-Access-Authenticated-User-Email: $loose_identity"
    violations=1
fi

if (( violations )); then
    exit 1
fi
echo "edge policy ok: $(hostnames "$json" | wc -l | tr -d ' ') hostnames, cfonly on all but the exempt ones, loopback upstreams only"
