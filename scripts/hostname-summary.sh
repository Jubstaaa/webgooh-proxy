#!/usr/bin/env bash
# Markdown for the pull request's job summary: hostnames this change adds or removes.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

base_dir=$(mktemp -d)
trap 'rm -rf "$base_dir"' EXIT
git show "origin/${BASE_REF:-main}:Caddyfile" >"$base_dir/Caddyfile"
scripts/adapt.sh "$base_dir/Caddyfile" >"$base_dir/base.json"
scripts/adapt.sh Caddyfile >"$base_dir/head.json"

base_hosts="$base_dir/base.hosts"
head_hosts="$base_dir/head.hosts"
scripts/policy.sh --hosts "$base_dir/base.json" >"$base_hosts"
scripts/policy.sh --hosts "$base_dir/head.json" >"$head_hosts"

echo "## Hostnames"
echo
echo "Added:"
comm -13 "$base_hosts" "$head_hosts" | sed 's/^/- /'
echo
echo "Removed:"
comm -23 "$base_hosts" "$head_hosts" | sed 's/^/- /'
echo
echo "Total: $(wc -l <"$head_hosts" | tr -d ' ') public hostnames."
