#!/usr/bin/env bash
# Exercises scripts/deploy-proxy.sh against a throwaway /opt/proxy tree, with fake
# docker and curl on PATH. Covers accept, reject, rollback, drift, compose changes
# pruning, and the apply-env entry point. Runs in CI on every pull request; touches nothing outside its temp dir.
set -Eeuo pipefail

here=$(cd "$(dirname "$0")" && pwd)
deploy=$here/../deploy-proxy.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

proxy=$work/opt/proxy
state=$work/state
bin=$work/bin
mkdir -p "$proxy/config/releases" "$proxy/sites/beszel-shell" "$proxy/sites/cronicle-identity" "$state" "$bin"
failures=0

sha_of() { printf '%040x' "$1"; }

fake_docker=$bin/docker
cat >"$fake_docker" <<'FAKE'
#!/usr/bin/env bash
# Fake docker: `exec` answers as the caddy container would; `compose` is recorded.
set -Eeuo pipefail
to_host_path() { printf '%s' "${1/#\/etc\/caddy/$FAKE_CONFIG_ROOT}"; }
if [[ $1 == compose ]]; then
    echo "compose $*" >>"$FAKE_STATE/compose.log"
    [[ -z ${FAKE_COMPOSE_FAIL:-} ]] || exit 1
    # `compose run ... caddy validate`: the throwaway container sees proxy.env
    if [[ $* == *" run "* ]] && grep -q INVALID_ENV "$FAKE_PROXY/proxy.env"; then
        exit 1
    fi
    if [[ $* == *" up "* ]]; then
        # a recreated container starts on config/current, so its admin config is that file
        jq -n --arg sha "$(sha256sum "$FAKE_CONFIG_ROOT/current/Caddyfile" | cut -d' ' -f1)" '{apps: {file: $sha}}' >"$FAKE_STATE/admin.json"
    fi
    exit 0
fi
[[ $1 == exec ]] || exit 2
shift 2
case $1 in
    wget) cat "$FAKE_STATE/admin.json" ;;
    caddy)
        cmd=$2
        cfg=""
        for ((i = 3; i <= $#; i++)); do [[ ${!i} == --config ]] && { j=$((i + 1)); cfg=$(to_host_path "${!j}"); }; done
        if grep -q INVALID_DIRECTIVE "$cfg"; then
            echo "Error: unrecognized directive" >&2
            exit 1
        fi
        case $cmd in
            adapt) jq -n --arg sha "$(sha256sum "$cfg" | cut -d' ' -f1)" '{apps: {file: $sha}}' ;;
            reload) jq -n --arg sha "$(sha256sum "$cfg" | cut -d' ' -f1)" '{apps: {file: $sha}}' >"$FAKE_STATE/admin.json" ;;
            validate) ;;
        esac
        ;;
esac
FAKE
cat >"$bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Fake curl: every host answers 200 unless FAKE_BAD_HOST names it.
url=""
for a in "$@"; do [[ $a == https://* ]] && url=$a; done
host=${url#https://}; host=${host%%/*}
if [[ ${FAKE_BAD_HOST:-} == "$host" ]]; then printf 503
elif [[ $host == b.test ]] && grep -qs BREAKS_B "$FAKE_PROXY/proxy.env"; then printf 503
else printf 200; fi
FAKE
chmod +x "$fake_docker" "$bin/curl"

export DEPLOY_PROXY_ROOT=$proxy
export DEPLOY_PROXY_DOCKER=$fake_docker
export DEPLOY_PROXY_LOCK=$work/deploy.lock
export DEPLOY_PROXY_SMOKE_DELAY=0
export DEPLOY_PROXY_ENV_STATE=$work/env-state DEPLOY_PROXY_ENV_WAIT=2
export FAKE_CONFIG_ROOT=$proxy/config FAKE_STATE=$state FAKE_PROXY=$proxy
export PATH=$bin:$PATH

# make_release <name> <caddy marker> <compose marker> <helper marker>
make_release() {
    local dir=$work/src/$1
    mkdir -p "$dir/smoke" "$dir/sites/beszel-shell" "$dir/sites/cronicle-identity"
    printf '# %s\na.test {\n\trespond "ok"\n}\n' "$2" >"$dir/Caddyfile"
    printf 'services:\n    caddy:\n        image: test # %s\n' "$3" >"$dir/docker-compose.yml"
    printf 'a.test 200\nb.test 200\n' >"$dir/smoke/baseline.txt"
    printf '<html>%s</html>\n' "$4" >"$dir/sites/beszel-shell/shell.html"
    printf '<html>identity</html>\n' >"$dir/sites/cronicle-identity/identity.html"
    echo "$dir"
}

# tarball <name> : what the workflow streams (git archive of the release paths)
tarball() {
    tar -C "$work/src/$1" -cf "$work/src/$1.tar" Caddyfile docker-compose.yml smoke sites
    echo "$work/src/$1.tar"
}

# bootstrap sha0 as the cut-over would leave the host
boot_dir=$(make_release boot "boot" "boot" "boot")
cp -r "$boot_dir" "$proxy/config/releases/$(sha_of 0)"
manifest=$(cd "$proxy/config/releases/$(sha_of 0)" && find . -type f ! -name MANIFEST.sha256 -printf '%P\0' | sort -z | xargs -0 -r sha256sum)
printf '%s\n' "$manifest" >"$proxy/config/releases/$(sha_of 0)/MANIFEST.sha256"
ln -s "releases/$(sha_of 0)" "$proxy/config/current"
cp "$boot_dir/docker-compose.yml" "$proxy/docker-compose.yml"
cp "$boot_dir/sites/beszel-shell/shell.html" "$proxy/sites/beszel-shell/"
cp "$boot_dir/sites/cronicle-identity/identity.html" "$proxy/sites/cronicle-identity/"
jq -n --arg sha "$(sha256sum "$proxy/config/current/Caddyfile" | cut -d' ' -f1)" '{apps: {file: $sha}}' >"$state/admin.json"

current() { basename "$(readlink "$proxy/config/current")"; }

run_deploy() { # <sha> <tarball>
    "$deploy" <"$2" 2>"$work/last.err" >/dev/null && return 0
    return 1
}

check() { # <description> <command...>
    local desc=$1
    shift
    if "$@"; then
        echo "ok   $desc"
    else
        echo "FAIL $desc"
        tail -n 4 "$proxy/deploy.log" 2>/dev/null | sed 's/^/       log: /' || true
        failures=$((failures + 1))
    fi
}

deploy_as() { # <sha> <tarball>: runs the forced command the way sshd would
    SSH_ORIGINAL_COMMAND="deploy-proxy $1" run_deploy "$1" "$2"
}

is_current() { [[ $(current) == "$1" ]]; }
rejected_with() { grep -q "$1" "$work/last.err"; }

# 1. a clean release is installed, switched and smoked
r1=$(make_release r1 "release one" "compose one" "helper one")
check "accepts a clean release" deploy_as "$(sha_of 1)" "$(tarball r1)"
check "current points at the new release" is_current "$(sha_of 1)"
check "helper synced to host" cmp -s "$r1/sites/beszel-shell/shell.html" "$proxy/sites/beszel-shell/shell.html"
check "deploy logged" grep -q "DEPLOYED $(sha_of 1)" "$proxy/deploy.log"

# 2. refusals before anything changes
check "refuses a missing commit" bash -c "SSH_ORIGINAL_COMMAND='deploy-proxy' '$deploy' </dev/null >/dev/null 2>&1; [[ \$? -ne 0 ]]"
check "refuses a non-hex commit" bash -c "SSH_ORIGINAL_COMMAND='deploy-proxy ../../etc' '$deploy' </dev/null >/dev/null 2>&1; [[ \$? -ne 0 ]]"
bad_tar=$work/src/extra.tar
mkdir -p "$work/src/extra" && cp -r "$r1"/. "$work/src/extra/" && echo '#!/bin/sh' >"$work/src/extra/evil.sh"
tar -C "$work/src/extra" -cf "$bad_tar" Caddyfile docker-compose.yml smoke sites evil.sh
check "refuses a tarball with an extra file" bash -c "! SSH_ORIGINAL_COMMAND='deploy-proxy $(sha_of 2)' '$deploy' <'$bad_tar' >/dev/null 2>&1"
check "current unchanged after refusal" is_current "$(sha_of 1)"

# 3. an invalid Caddyfile is rejected by validate and leaves nothing behind
make_release r3 "INVALID_DIRECTIVE" "compose one" "helper one" >/dev/null
check "rejects an invalid Caddyfile" bash -c "! SSH_ORIGINAL_COMMAND='deploy-proxy $(sha_of 3)' '$deploy' <'$(tarball r3)' >/dev/null 2>&1"
check "current unchanged after validate failure" is_current "$(sha_of 1)"
check "rejected release directory removed" test ! -e "$proxy/config/releases/$(sha_of 3)"

# 4. a smoke failure rolls back and exits non-zero
make_release r4 "release four" "compose one" "helper four" >/dev/null
check "rolls back on smoke failure" bash -c "! FAKE_BAD_HOST=b.test SSH_ORIGINAL_COMMAND='deploy-proxy $(sha_of 4)' '$deploy' <'$(tarball r4)' >/dev/null 2>&1"
check "current back on the previous release" is_current "$(sha_of 1)"
check "helper restored after rollback" cmp -s "$r1/sites/beszel-shell/shell.html" "$proxy/sites/beszel-shell/shell.html"
check "rollback logged" grep -q "ROLLBACK $(sha_of 4)" "$proxy/deploy.log"

# 5. drift: a release edited in place blocks the next deploy
printf '# hand edit\n' >>"$proxy/config/releases/$(sha_of 1)/Caddyfile"
check "refuses to deploy over drift" bash -c "! SSH_ORIGINAL_COMMAND='deploy-proxy $(sha_of 5)' '$deploy' <'$(tarball r4)' >/dev/null 2>&1"
check "drift is named in the log" grep -q "drift: releases/$(sha_of 1)" "$proxy/deploy.log"
cp "$r1/Caddyfile" "$proxy/config/releases/$(sha_of 1)/Caddyfile"

# 6. a compose change recreates the container; a failed recreate restores the old file
r6=$(make_release r6 "release six" "compose six" "helper six")
check "deploys a compose change" deploy_as "$(sha_of 6)" "$(tarball r6)"
check "compose recreate was requested" grep -q "up -d --wait caddy" "$state/compose.log"
make_release r7 "release seven" "compose seven" "helper seven" >/dev/null
check "rolls back a failed compose recreate" bash -c "! FAKE_COMPOSE_FAIL=1 SSH_ORIGINAL_COMMAND='deploy-proxy $(sha_of 7)' '$deploy' <'$(tarball r7)' >/dev/null 2>&1"
check "compose file restored to the previous release" cmp -s "$r6/docker-compose.yml" "$proxy/docker-compose.yml"
check "current back on release six" is_current "$(sha_of 6)"

# 7. re-deploying an existing release reuses it; pruning keeps the newest ten
for n in $(seq 10 21); do
    make_release "r$n" "release $n" "compose six" "helper $n" >/dev/null
    deploy_as "$(sha_of "$n")" "$(tarball "r$n")" || { echo "FAIL deploy $n"; tail -n 3 "$proxy/deploy.log" | sed 's/^/       log: /'; failures=$((failures + 1)); }
done
check "current is the last release" is_current "$(sha_of 21)"
check "older releases pruned to ten" bash -c "[[ \$(ls -1 '$proxy/config/releases' | grep -c '^[0-9a-f]\{40\}\$') -le 10 ]]"
check "rollback target kept after pruning" test -d "$proxy/config/releases/$(sha_of 20)"
check "re-deploy of an existing release succeeds" deploy_as "$(sha_of 20)" "$(tarball r20)"

# 8. apply-env: proxy.env rendered by the agent is validated, applied, or rolled back
envs=$work/env-state
apply_env() { "$deploy" apply-env >/dev/null 2>"$work/last.err"; }
ups() { grep -c "up -d --force-recreate --wait caddy" "$state/compose.log" || true; }
runs() { grep -c " run --rm " "$state/compose.log" || true; }
printf "A='one'\n" >"$proxy/proxy.env"
check "refuses without an applied baseline" bash -c "! '$deploy' apply-env >/dev/null 2>&1"
mkdir -p "$envs"
cp "$proxy/proxy.env" "$envs/proxy.env.applied"
sha256sum "$proxy/proxy.env" | cut -d' ' -f1 >"$envs/proxy.sha"
u0=$(ups)
check "unchanged env is a no-op" apply_env
check "no recreate for an unchanged env" test "$(ups)" = "$u0"

printf "A='two'\n" >"$proxy/proxy.env"
check "the deploy key cannot reach apply-env" bash -c "! SSH_ORIGINAL_COMMAND='deploy-proxy apply-env' '$deploy' apply-env </dev/null >/dev/null 2>&1"
check "no recreate from the forced command" test "$(ups)" = "$u0"

check "applies a changed env" apply_env
check "validated in a throwaway container" test "$(runs)" -ge 1
check "recreated once" test "$(ups)" = $((u0 + 1))
check "applied copy updated" cmp -s "$proxy/proxy.env" "$envs/proxy.env.applied"
check "hash recorded" test "$(cat "$envs/proxy.sha")" = "$(sha256sum "$proxy/proxy.env" | cut -d' ' -f1)"
check "apply logged" grep -q "apply-env: APPLIED" "$proxy/deploy.log"
good=$(cat "$proxy/proxy.env")

u1=$(ups)
printf "A='INVALID_ENV'\n" >"$proxy/proxy.env"
check "rejects an env that fails validate" bash -c "! '$deploy' apply-env >/dev/null 2>&1"
check "no recreate after a validate failure" test "$(ups)" = "$u1"
check "previous env restored after validate failure" test "$(cat "$proxy/proxy.env")" = "$good"
r1=$(runs)
printf "A='INVALID_ENV'\n" >"$proxy/proxy.env"
check "a rejected env is refused again" bash -c "! '$deploy' apply-env >/dev/null 2>&1"
check "without re-validating it" test "$(runs)" = "$r1"
check "and restored again" test "$(cat "$proxy/proxy.env")" = "$good"

: >"$proxy/proxy.env"
check "rejects an empty render" bash -c "! '$deploy' apply-env >/dev/null 2>&1"
check "previous env restored after empty render" test "$(cat "$proxy/proxy.env")" = "$good"

printf "A='BREAKS_B'\n" >"$proxy/proxy.env"
check "rolls back an env that fails smoke" bash -c "! '$deploy' apply-env >/dev/null 2>&1"
check "recreated twice (apply and rollback)" test "$(ups)" = $((u1 + 2))
check "previous env restored after smoke failure" test "$(cat "$proxy/proxy.env")" = "$good"
check "hash still the applied one" test "$(cat "$envs/proxy.sha")" = "$(sha256sum "$proxy/proxy.env" | cut -d' ' -f1)"
check "env rollback logged" grep -q "apply-env: ROLLBACK" "$proxy/deploy.log"

exec 8>"$work/deploy.lock"
flock 8
printf "A='three'\n" >"$proxy/proxy.env"
check "waits for a running deploy, then gives up" bash -c "! '$deploy' apply-env >/dev/null 2>&1"
flock -u 8
check "applies once the lock is free" apply_env

echo
if (( failures )); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all deploy-proxy checks passed"
