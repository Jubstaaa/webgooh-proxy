#!/usr/bin/env bash
# Forced command behind the webgooh-proxy deploy key. Lives on the host as
# /usr/local/bin/deploy-proxy and is bound to that key in authorized_keys:
#   restrict,command="/usr/local/bin/deploy-proxy" ssh-ed25519 <key> ...
# The caller sends "deploy-proxy <40-hex commit>" and streams a tarball of the
# release files on stdin.
#
# Order: validate the tarball, refuse on drift from the current release, install
# releases/<sha>, validate it inside the running container, switch config/current,
# then either recreate the container (compose changed) or reload, sync the static
# helpers, and smoke every hostname against smoke/baseline.txt. A failure after the
# switch restores the previous release (config, compose, helpers) and exits 1.
set -Eeuo pipefail
umask 077

PROXY=${DEPLOY_PROXY_ROOT:-/opt/proxy}
CONFIG=$PROXY/config
RELEASES=$CONFIG/releases
CONTAINER=${DEPLOY_PROXY_CONTAINER:-proxy-caddy}
DOCKER=${DEPLOY_PROXY_DOCKER:-docker}
LOG=$PROXY/deploy.log
LOCK=${DEPLOY_PROXY_LOCK:-/run/deploy-proxy.lock}
KEEP=10
MAX_TARBALL=$((4 * 1024 * 1024))
ALLOWED_FILE='^(Caddyfile|docker-compose\.yml|smoke/baseline\.txt|sites/(beszel-shell|cronicle-identity)/[A-Za-z0-9._-]+)$'
ALLOWED_DIR='^(smoke|sites|sites/(beszel-shell|cronicle-identity))$'
HELPERS=(beszel-shell cronicle-identity)
SMOKE_DELAY=${DEPLOY_PROXY_SMOKE_DELAY:-2}

sha=""
prev=""
prevdir=""
target=""
stage=""
incoming=""
created=0
switched=0
finished=0
compose_changed=0

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }
die() { log "FAILED $*"; exit 1; }

normalise() { jq -S .; }

write_manifest() {
    local list
    list=$(cd "$1" && find . -type f ! -name MANIFEST.sha256 -printf '%P\0' | sort -z | xargs -0 -r sha256sum)
    printf '%s\n' "$list" >"$1/MANIFEST.sha256"
}

manifest_ok() {
    local dir=$1
    [[ -f $dir/MANIFEST.sha256 ]] || return 1
    (cd "$dir" && sha256sum --strict --quiet -c MANIFEST.sha256 >/dev/null 2>&1) || return 1
    diff -q <(awk '{ $1 = ""; sub(/^ /, ""); print }' "$dir/MANIFEST.sha256" | sort) \
        <(cd "$dir" && find . -type f ! -name MANIFEST.sha256 -printf '%P\n' | sort) >/dev/null
}

check_tarball() {
    local line kind name
    while IFS= read -r line; do
        kind=${line:0:1}
        name=${line##* }
        name=${name%/}
        case $kind in
            -) [[ $name =~ $ALLOWED_FILE ]] || return 1 ;;
            d) [[ $name =~ $ALLOWED_DIR ]] || return 1 ;;
            g) [[ $name == pax_global_header ]] || return 1 ;;
            *) return 1 ;;
        esac
    done < <(tar -tvf "$1")
    return 0
}

current_is_live() {
    local want got
    want=$("$DOCKER" exec "$CONTAINER" caddy adapt --config /etc/caddy/current/Caddyfile --adapter caddyfile 2>/dev/null | normalise) || return 1
    got=$("$DOCKER" exec "$CONTAINER" wget -qO- http://127.0.0.1:2019/config/ | normalise) || return 1
    [[ -n $want && $want == "$got" ]]
}

point_current_at() {
    ln -sfn "releases/$1" "$CONFIG/.current.next" && mv -T "$CONFIG/.current.next" "$CONFIG/current"
}

sync_helpers() {
    local name
    for name in "${HELPERS[@]}"; do
        install -m 0644 -t "$PROXY/sites/$name" "$1/sites/$name/"* || return 1
    done
}

install_compose() {
    install -m 0644 "$1/docker-compose.yml" "$PROXY/docker-compose.yml" || return 1
    "$DOCKER" compose --project-directory "$PROXY" -f "$PROXY/docker-compose.yml" up -d --wait caddy >&2
}

reload() {
    "$DOCKER" exec "$CONTAINER" caddy reload --config /etc/caddy/current/Caddyfile --adapter caddyfile >&2
}

smoke() {
    local host want code bad=0 _
    while read -r host want; do
        [[ -z $host || $host == \#* ]] && continue
        for _ in 1 2 3; do
            code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$host:443:127.0.0.1" "https://$host/" || true)
            [[ $code == "$want" ]] && break
            sleep "$SMOKE_DELAY"
        done
        if [[ $code == "$want" ]]; then
            log "smoke ok $host $code"
        else
            log "smoke MISMATCH $host got $code want $want"
            bad=1
        fi
    done <"$1/smoke/baseline.txt"
    return $bad
}

apply_release() {
    sync_helpers "$1" || return 1
    if (( compose_changed )); then
        install_compose "$1" || return 1
    else
        reload || return 1
    fi
}

rollback() {
    trap - ERR
    set +e
    log "ROLLBACK $sha: $1"
    point_current_at "$prev" || log "could not point current back at $prev"
    sync_helpers "$prevdir" || log "could not restore static helpers from $prev"
    if (( compose_changed )); then
        install_compose "$prevdir" || log "could not restore compose from $prev"
    else
        reload || log "caddy reload of $prev failed"
    fi
    if smoke "$prevdir"; then
        log "rolled back to $prev; smoke clean"
    else
        log "rolled back to $prev but smoke still fails: investigate now"
    fi
    exit 1
}

on_error() {
    if (( switched && !finished )); then
        rollback "unexpected error at line $1"
    fi
    die "$sha: unexpected error at line $1"
}

cleanup() {
    [[ -n $stage ]] && rm -rf -- "$stage"
    [[ -n $incoming ]] && rm -f -- "$incoming"
    if (( created && !switched )) && [[ -d $target ]]; then
        rm -rf -- "$target"
    fi
}

prune() {
    local i=0 d
    while read -r _ d; do
        i=$((i + 1))
        (( i <= KEEP )) && continue
        [[ $d == "$sha" || $d == "$prev" ]] && continue
        rm -rf -- "${RELEASES:?}/$d"
    done < <(find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9a-f]{40}' -printf '%T@ %f\n' | sort -rn)
}

main() {
    local cmd=${SSH_ORIGINAL_COMMAND:-} f

    sha=${cmd#deploy-proxy }
    [[ $cmd == "deploy-proxy $sha" ]] || die "refusing '${cmd:-<none>}': expected 'deploy-proxy <commit sha>'"
    [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "refusing malformed commit '$sha'"

    exec 9>"$LOCK"
    flock -n 9 || die "$sha: another deploy holds $LOCK"

    [[ -L $CONFIG/current ]] || die "$sha: no config/current symlink; bootstrap the first release by hand"
    prev=$(basename "$(readlink "$CONFIG/current")")
    [[ $prev =~ ^[0-9a-f]{40}$ ]] || die "$sha: config/current points at '$prev', not a release"
    prevdir=$RELEASES/$prev

    incoming=$(mktemp "$RELEASES/.incoming.XXXXXX")
    head -c $((MAX_TARBALL + 1)) >"$incoming"
    (( $(stat -c %s "$incoming") <= MAX_TARBALL )) || die "$sha: tarball exceeds $MAX_TARBALL bytes"
    check_tarball "$incoming" || die "$sha: tarball has an entry outside the allowlist"

    stage=$(mktemp -d "$RELEASES/.stage.XXXXXX")
    tar -xf "$incoming" --no-same-owner --no-same-permissions -C "$stage"
    rm -f -- "$incoming"
    incoming=""
    for f in Caddyfile docker-compose.yml smoke/baseline.txt; do
        [[ -f $stage/$f ]] || die "$sha: tarball lacks $f"
    done

    target=$RELEASES/$sha
    if [[ -e $target ]]; then
        manifest_ok "$target" || die "$sha: existing release fails its manifest"
        diff -r -x MANIFEST.sha256 "$stage" "$target" >/dev/null || die "$sha: existing release differs from the tarball"
        rm -rf -- "$stage"
        stage=""
    else
        write_manifest "$stage"
        mv "$stage" "$target"
        stage=""
        created=1
    fi

    manifest_ok "$prevdir" || die "drift: releases/$prev no longer matches its manifest (edited in place?)"
    cmp -s "$PROXY/docker-compose.yml" "$prevdir/docker-compose.yml" || die "drift: host docker-compose.yml differs from release $prev"
    for f in "${HELPERS[@]}"; do
        diff -rq "$PROXY/sites/$f" "$prevdir/sites/$f" >/dev/null || die "drift: host sites/$f differs from release $prev"
    done
    current_is_live || die "drift: running Caddy config differs from release $prev"

    "$DOCKER" exec "$CONTAINER" caddy validate --config "/etc/caddy/releases/$sha/Caddyfile" --adapter caddyfile >&2 \
        || die "$sha: caddy validate rejected the release (nothing changed)"

    if ! cmp -s "$PROXY/docker-compose.yml" "$target/docker-compose.yml"; then
        compose_changed=1
        "$DOCKER" compose --project-directory "$PROXY" -f "$target/docker-compose.yml" config -q >&2 \
            || die "$sha: docker-compose.yml is invalid (nothing changed)"
    fi

    switched=1
    point_current_at "$sha" || rollback "could not switch config/current to $sha"
    log "switched current $prev -> $sha (compose_changed=$compose_changed)"
    apply_release "$target" || rollback "release $sha did not apply"
    smoke "$target" || rollback "smoke test failed for $sha"

    finished=1
    prune
    log "DEPLOYED $sha (previous $prev)"
}

trap 'on_error $LINENO' ERR
trap cleanup EXIT
main "$@"
