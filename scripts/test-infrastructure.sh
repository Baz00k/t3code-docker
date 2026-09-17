#!/usr/bin/env bash
# Assert that T3 Code runs on immutable image infrastructure.
#
#   scripts/test-infrastructure.sh [image]     (default: t3code:slim)
#
# The unit under test is isolation, not features:
#
#   - `t3`, the setup service and every administrative helper launch the image
#     Node against the root-owned T3 bundle, even with decoys shadowing
#     `node`/`t3` on PATH;
#   - the running processes provably are that Node and that bundle;
#   - the unprivileged user cannot write the image Node or the T3 tree;
#   - user npm globals still install, into the mutable prefix, without touching
#     the T3 tree;
#   - root gets neither the user npm prefix nor any user tool directory.
set -euo pipefail

IMAGE="${1:-t3code:slim}"
NAME="t3code-infra-$$"
PORT="${INFRA_PORT:-13775}"
PUBLIC_URL="https://infra.example.test"
SETUP_KEY="infra-setup-key"

pass=0
fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }

TMP_DIRS=()
temp_dir() { local d; d="$(mktemp -d)"; TMP_DIRS+=("$d"); printf '%s' "$d"; }
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  local d
  for d in "${TMP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null || true; done
}
trap cleanup EXIT

# Process introspection has to happen inside the container; the host's /proc is
# a different machine's. The server drops privileges with gosu, which marks it
# non-dumpable, so `exe` is only readable as the user it runs as.
proc_exe()     { docker exec -u t3 "$NAME" readlink -f "/proc/$1/exe"; }
proc_cmdline() { docker exec "$NAME" sh -c "tr '\0' ' ' < /proc/$1/cmdline"; }
find_pid()     { docker exec -e "T3_PID_PATTERN=$1" "$NAME" sh -c '
  for p in /proc/[0-9]*; do
    c="$(tr "\0" " " < "$p/cmdline" 2>/dev/null)"
    case "$c" in $T3_PID_PATTERN) echo "${p#/proc/}"; exit 0;; esac
  done
  exit 1'; }

printf '\nTesting infrastructure isolation of %s\n\n' "$IMAGE"

docker run -d --name "$NAME" \
  -p "127.0.0.1:${PORT}:3773" \
  -e "T3_PUBLIC_URL=${PUBLIC_URL}" \
  -e "T3_SETUP_KEY=${SETUP_KEY}" \
  "$IMAGE" >/dev/null

printf 'Waiting for the server to answer...\n'
health_url="http://127.0.0.1:${PORT}/.well-known/t3/environment"
for i in $(seq 1 60); do
  if curl -fsS --noproxy '*' --max-time 5 "$health_url" >/dev/null 2>&1; then break; fi
  if [ "$i" = 60 ]; then
    no "server never became healthy"
    docker logs "$NAME" 2>&1 | tail -30
    exit 1
  fi
  sleep 2
done

printf '\nImmutable launcher\n'
T3_PREFIX="$(docker exec "$NAME" printenv T3_INFRA_PREFIX 2>/dev/null || true)"
[ -n "$T3_PREFIX" ] || T3_PREFIX=/opt/t3
T3_BUNDLE="${T3_PREFIX}/lib/node_modules/t3/dist/bin.mjs"

check "the image declares its immutable T3 prefix" \
  "docker exec $NAME printenv T3_INFRA_PREFIX"
check "t3 resolves to the immutable launcher" \
  "[ \"\$(docker exec $NAME sh -c 'command -v t3')\" = /usr/local/bin/t3 ]"
check "the t3 command is the launcher, not a symlink into npm" \
  "[ \"\$(docker exec $NAME readlink -f /usr/local/bin/t3)\" = /usr/local/bin/t3-admin ]"
check "the immutable bundle exists at \${T3_INFRA_PREFIX}" \
  "docker exec $NAME test -f $T3_BUNDLE"
check "T3 is absent from the mutable npm prefix" \
  "docker exec $NAME test ! -e /opt/npm-global/lib/node_modules/t3"
check "the T3 tree is root-owned" \
  "[ \"\$(docker exec $NAME stat -c %U:%G $T3_PREFIX)\" = root:root ]"
check "t3 --version and t3-admin --version agree" \
  "[ \"\$(docker exec $NAME t3 --version 2>/dev/null)\" = \"\$(docker exec $NAME t3-admin --version 2>/dev/null)\" ]"

# Decoys earlier on PATH than every image directory. If any helper resolved
# `node` or `t3` through PATH it would run these and fail loudly.
SHADOW_DIR="$(temp_dir)"
for name in node t3 t3-admin; do
  cat > "$SHADOW_DIR/$name" <<'EOF'
#!/bin/sh
printf 'decoy %s\n' "$(basename "$0")" >> /tmp/shadow-invocations
exit 3
EOF
  chmod 0755 "$SHADOW_DIR/$name"
done
docker exec "$NAME" mkdir -p /tmp/shadow
docker cp "$SHADOW_DIR/." "$NAME:/tmp/shadow/" >/dev/null
docker exec "$NAME" sh -c ': > /tmp/shadow-invocations && chmod 0666 /tmp/shadow-invocations'

SHADOW_PATH="/tmp/shadow:/usr/bin:/bin"
shadow_log()       { docker exec "$NAME" cat /tmp/shadow-invocations; }
clear_shadow_log() { docker exec "$NAME" sh -c ': > /tmp/shadow-invocations'; }

printf '\nPATH shadowing\n'
# Prove the decoys are actually first: a bare `node` must now hit the decoy.
docker exec -e "PATH=${SHADOW_PATH}" -u t3 "$NAME" sh -c 'node --version' >/dev/null 2>&1 || true
check "the shadow actually takes over a bare command name" \
  "shadow_log | grep -q '^decoy node\$'"
clear_shadow_log

# The launcher is addressed absolutely, exactly as the helpers address it, so
# the shadowed names never come into it.
check "t3-admin ignores a shadowed node" \
  "docker exec -e PATH=$SHADOW_PATH -u t3 $NAME /usr/local/bin/t3-admin --version"
check "the t3 command ignores a shadowed node" \
  "docker exec -e PATH=$SHADOW_PATH -u t3 $NAME /usr/local/bin/t3 --version"
# t3-pair is a real administrative call: it spawns T3 to mint a token. Under the
# shadow it must still succeed, and it must not have asked PATH for anything.
check "t3-pair mints a token under a shadowed PATH" \
  "docker exec -e PATH=$SHADOW_PATH -u t3 $NAME /usr/local/bin/t3-pair --no-qr | grep -q 'Pairing URL:'"
check "no decoy was executed by the launcher or t3-pair" \
  "[ -z \"\$(shadow_log)\" ]"

printf '\nRunning processes\n'
pid="$(find_pid '*t3/dist/bin.mjs*serve*' || true)"
if [ -n "$pid" ]; then
  ok "the server runs the image T3 bundle (pid $pid)"
  check "the server process is the image Node" \
    "[ \"\$(proc_exe $pid)\" = /usr/local/bin/node ]"
  check "the server command line names the immutable bundle" \
    "proc_cmdline $pid | grep -q '$T3_BUNDLE'"
else
  no "could not find the running T3 server process"
fi

spid="$(find_pid '*/opt/t3-setup/server.mjs*' || true)"
if [ -n "$spid" ]; then
  check "the setup service process is the image Node" \
    "[ \"\$(proc_exe $spid)\" = /usr/local/bin/node ]"
else
  no "could not find the running setup service process"
fi

# The strongest form of the shadow test: start a second server with the decoys
# first on PATH and inspect what actually got executed.
docker exec -e "PATH=${SHADOW_PATH}" -u t3 -d "$NAME" \
  /usr/local/bin/t3-admin serve --base-dir /tmp/t3-shadow --host 127.0.0.1 \
  --port 3999 /tmp >/dev/null 2>&1 || true
shadow_pid=""
for _ in $(seq 1 40); do
  shadow_pid="$(find_pid '*--port 3999*' || true)"
  [ -n "$shadow_pid" ] && break
  sleep 1
done
if [ -n "$shadow_pid" ]; then
  check "a server started under a shadowed PATH is the image Node" \
    "[ \"\$(proc_exe $shadow_pid)\" = /usr/local/bin/node ]"
  check "its command line names the immutable bundle" \
    "proc_cmdline $shadow_pid | grep -q '$T3_BUNDLE'"
  docker exec "$NAME" kill "$shadow_pid" >/dev/null 2>&1 || true
else
  no "a server could not be started under a shadowed PATH"
fi

printf '\nForbidden writes\n'
check "the t3 user cannot write the T3 prefix" \
  "docker exec -u t3 $NAME sh -c '! touch $T3_PREFIX/forbidden 2>/dev/null'"
check "the t3 user cannot write the T3 entry module" \
  "docker exec -u t3 $NAME sh -c '! touch $T3_BUNDLE 2>/dev/null'"
check "the t3 user cannot write the image Node" \
  "docker exec -u t3 $NAME sh -c '! touch /usr/local/bin/node 2>/dev/null'"
check "the t3 user cannot write the image Node modules" \
  "docker exec -u t3 $NAME sh -c '! touch /usr/local/lib/node_modules/forbidden 2>/dev/null'"
# Symlinks are always mode 0777, so only real files and directories count.
check "nothing under the T3 prefix is group- or other-writable" \
  "[ -z \"\$(docker exec $NAME find $T3_PREFIX \\( -type f -o -type d \\) -perm /022 -print -quit)\" ]"
check "the launchers are root-owned" \
  "[ \"\$(docker exec $NAME stat -c %U /usr/local/bin/t3-admin /usr/local/bin/t3 | sort -u)\" = root ]"

t3_tree_hash() {
  docker exec "$NAME" sh -c "
    { find $T3_PREFIX -printf '%p %y %m %u:%g\n' | sort;
      find $T3_PREFIX -type f -exec sha256sum {} + | sort; } | sha256sum"
}

printf '\nUser npm globals\n'
T3_STATE_BEFORE="$(t3_tree_hash)"

check "the user npm prefix is the mutable one" \
  "[ \"\$(docker exec -u t3 $NAME npm config get prefix)\" = /opt/npm-global ]"
check "the user npm prefix is owned by t3" \
  "[ \"\$(docker exec $NAME stat -c %U /opt/npm-global)\" = t3 ]"

# A local tarball, so this needs no network and cannot be flaky about it.
PKG_DIR="$(temp_dir)"
mkdir -p "$PKG_DIR/bin"
cat > "$PKG_DIR/package.json" <<'JSON'
{ "name": "t3-infra-probe", "version": "1.0.0", "bin": { "t3-infra-probe": "bin/probe.js" } }
JSON
cat > "$PKG_DIR/bin/probe.js" <<'JS'
#!/usr/bin/env node
console.log("t3-infra-probe-ok");
JS
chmod 0755 "$PKG_DIR/bin/probe.js"
docker exec "$NAME" rm -rf /tmp/t3-infra-pkg
docker exec "$NAME" mkdir -p /tmp/t3-infra-pkg
docker cp "$PKG_DIR/." "$NAME:/tmp/t3-infra-pkg/" >/dev/null
TGZ="$(docker exec "$NAME" sh -c 'cd /tmp/t3-infra-pkg && npm pack --silent' | tail -1)"

check "a user npm global install succeeds" \
  "docker exec -u t3 $NAME npm install -g --no-audit --no-fund /tmp/t3-infra-pkg/$TGZ"
check "the installed command runs" \
  "docker exec -u t3 $NAME sh -c 't3-infra-probe | grep -q t3-infra-probe-ok'"
check "it landed in the mutable prefix, not the T3 tree" \
  "docker exec $NAME test -e /opt/npm-global/lib/node_modules/t3-infra-probe"
check "the T3 tree is byte-identical after the install" \
  "[ \"\$(t3_tree_hash)\" = \"$T3_STATE_BEFORE\" ]"

printf '\nRoot isolation\n'
check "NPM_CONFIG_PREFIX is not set process-wide" \
  "! docker exec $NAME printenv NPM_CONFIG_PREFIX"
check "root npm keeps its own root-owned prefix" \
  "[ \"\$(docker exec $NAME npm config get prefix)\" = /usr/local ]"
check "root HOME is not the user home" \
  "[ \"\$(docker exec $NAME sh -c 'echo \$HOME')\" = /root ]"
check "root PATH contains no user-controlled directory" \
  "docker exec $NAME sh -c 'case \":\$PATH:\" in *\":/home/t3\"*) exit 1;; *) exit 0;; esac'"
check "the user npm prefix is configured in the user's own npmrc" \
  "docker exec $NAME sh -c 'grep -qx prefix=/opt/npm-global /home/t3/.npmrc'"

printf '\n%d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
