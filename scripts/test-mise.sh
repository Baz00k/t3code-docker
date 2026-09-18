#!/usr/bin/env bash
# Assert the mise toolchain contract on one image.
#
#   scripts/test-mise.sh [image]     (default: t3code:core)
#
# The unit under test is project execution, not mise's backend coverage:
#
#   - the pinned release is the committed artifact (version + checksum);
#   - the persistent user paths and shims are set for the t3 user, for a fresh
#     home and a reused one, and never for root;
#   - interactive shells activate mise;
#   - explicit `mise exec` / `mise run` install or fail, never silently use a
#     system tool;
#   - the generated idiomatic allowlist detects the pinned release's files, and
#     explicit config wins over the detector;
#   - a reused home keeps working with no network at all.
#
# Every fixture lives in tests/fixtures/mise and is copied into the container,
# so nothing in the repository is modified by a run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-t3code:core}"
NAME="t3code-mise-$$"
OFFLINE="t3code-mise-offline-$$"
HOME_VOLUME="t3code-mise-home-$$"
PORT="${MISE_PORT:-13776}"
FIXTURES_SRC="${ROOT}/tests/fixtures/mise"
FIXTURES=/tmp/t3code-mise-fixtures

MISE_VERSION="$(grep -m1 '^ARG MISE_VERSION=' "$ROOT/Dockerfile" | cut -d= -f2)"
ALLOWLIST_COUNT="$(grep -cE '^  "' "$ROOT/docker/mise/config.toml")"

pass=0
fail=0
ok()    { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()    { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }
is() { # label expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected [$2], got [$3])"; fi
}
matches() { # label regex haystack
  if printf '%s' "$3" | grep -Eq -- "$2"; then ok "$1"; else no "$1 (no match for /$2/)"; fi
}
has() { # label needle haystack
  if printf '%s' "$3" | grep -Fq -- "$2"; then ok "$1"; else no "$1 (missing [$2])"; fi
}
hasnt() { # label needle haystack
  if printf '%s' "$3" | grep -Fq -- "$2"; then no "$1 (unexpected [$2])"; else ok "$1"; fi
}
fails() { # label command...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then no "$label (unexpected success)"; else ok "$label"; fi
}

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker rm -f "$OFFLINE" >/dev/null 2>&1 || true
  docker volume rm "$HOME_VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

dex() { docker exec "$NAME" "$@"; }
# A login shell is how a T3 terminal starts: /etc/profile.d/t3-user-env.sh is
# what exports the mise paths and puts the shims on PATH.
ulogin() { local dir="$1" cmd="$2"; shift 2; docker exec -u t3 -w "$dir" "$@" "$NAME" bash -lc "$cmd"; }
# Same, but against the offline container.
ologin() { local dir="$1" cmd="$2"; shift 2; docker exec -u t3 -w "$dir" "$@" "$OFFLINE" bash -lc "$cmd"; }

copy_fixtures() {
  local target="$1"
  docker exec "$target" rm -rf "$FIXTURES"
  docker exec "$target" mkdir -p "$FIXTURES"
  docker cp "${FIXTURES_SRC}/." "${target}:${FIXTURES}/" >/dev/null
}

find_pid() { # pattern -> pid inside the main container
  docker exec -e "MISE_PID_PATTERN=$1" "$NAME" sh -c '
    for p in /proc/[0-9]*; do
      c="$(tr "\0" " " < "$p/cmdline" 2>/dev/null)"
      case "$c" in $MISE_PID_PATTERN) echo "${p#/proc/}"; exit 0;; esac
    done
    exit 1'
}

printf '\nTesting the mise toolchain contract of %s (mise %s)\n\n' "$IMAGE" "$MISE_VERSION"

docker volume create "$HOME_VOLUME" >/dev/null
docker run -d --name "$NAME" \
  -p "127.0.0.1:${PORT}:3773" \
  -e "T3_SETUP_KEY=mise-test-key" \
  -v "${HOME_VOLUME}:/home/t3" \
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

copy_fixtures "$NAME"

# --- pinned release ----------------------------------------------------------
printf '\nPinned release\n'
is "mise resolves to the image binary" \
  "/usr/local/bin/mise" "$(dex sh -c 'command -v mise')"
matches "mise reports the pinned version" "^${MISE_VERSION} " "$(dex mise --version)"
is "the mise binary is root-owned" \
  "root:root" "$(dex stat -c %U:%G /usr/local/bin/mise)"
fails "the t3 user cannot write the mise binary" \
  docker exec -u t3 "$NAME" sh -c 'touch /usr/local/bin/mise 2>/dev/null'
is "the system config is installed root-owned" \
  "root:root" "$(dex stat -c %U:%G /etc/mise/config.toml)"
is "the system config carries the generated allowlist" \
  "$ALLOWLIST_COUNT" "$(dex grep -cE '^  "' /etc/mise/config.toml)"

arch="$(dex sh -c 'case "$(dpkg --print-architecture)" in amd64) echo x64;; arm64) echo arm64;; *) echo unknown;; esac')"
installed_sum="$(dex sha256sum /usr/local/bin/mise | cut -d' ' -f1)"
pinned_sum="$(dex awk -v a="mise-v${MISE_VERSION}-linux-${arch}" '$2 == a { print $1 }' /opt/mise/SHA256SUMS)"
is "the installed binary matches the committed checksum" "$pinned_sum" "$installed_sum"

# --- root isolation ----------------------------------------------------------
printf '\nRoot isolation\n'
is "root gets no user MISE_DATA_DIR" "" "$(dex printenv MISE_DATA_DIR || true)"
is "root gets no user MISE_CONFIG_DIR" "" "$(dex printenv MISE_CONFIG_DIR || true)"
check "root PATH has no user mise shims" \
  "dex sh -c 'case \":\$PATH:\" in *\":/home/t3/.local/share/mise/shims:\"*) exit 1;; *) exit 0;; esac'"
dex mise settings get pin >/dev/null 2>&1 || true
is "root running mise writes no state into the user home" \
  "" "$(dex find /home/t3/.config/mise /home/t3/.local /home/t3/.cache /home/t3/.local/state/mise -user root 2>/dev/null || true)"

# --- the t3 user environment -------------------------------------------------
printf '\nUser environment\n'
is "the login shell exports MISE_CONFIG_DIR" \
  "/home/t3/.config/mise" "$(ulogin "$FIXTURES" 'printf %s "$MISE_CONFIG_DIR"')"
is "the login shell exports MISE_DATA_DIR" \
  "/home/t3/.local/share/mise" "$(ulogin "$FIXTURES" 'printf %s "$MISE_DATA_DIR"')"
is "the login shell exports MISE_STATE_DIR" \
  "/home/t3/.local/state/mise" "$(ulogin "$FIXTURES" 'printf %s "$MISE_STATE_DIR"')"
is "the login shell exports MISE_CACHE_DIR" \
  "/home/t3/.cache/mise" "$(ulogin "$FIXTURES" 'printf %s "$MISE_CACHE_DIR"')"
check "the login shell puts mise shims on PATH" \
  "docker exec -u t3 $NAME bash -lc 'case \":\$PATH:\" in *\":/home/t3/.local/share/mise/shims:\"*) exit 0;; *) exit 1;; esac'"
is "an interactive shell activates mise" \
  "function" "$(docker exec -u t3 "$NAME" bash -ilc 'type -t mise' 2>/dev/null || true)"
check "bare docker exec reaches mise without the profile hook" \
  "docker exec -u t3 $NAME mise --version"
is "bare docker exec still reads the system allowlist" \
  "$ALLOWLIST_COUNT" \
  "$(docker exec -u t3 "$NAME" mise settings get idiomatic_version_file_enable_tools | jq length)"

# The server itself must carry the user environment, because the terminals T3
# opens are its children.
pid="$(find_pid '*t3/dist/bin.mjs*serve*' || true)"
if [ -n "$pid" ]; then
  # gosu marks the dropped server non-dumpable, so only its own uid can read
  # the environment that the entrypoint handed down.
  server_env="$(docker exec -u t3 "$NAME" sh -c "tr '\0' '\n' < /proc/$pid/environ" 2>/dev/null || true)"
  has "the server inherits MISE_DATA_DIR" \
    "MISE_DATA_DIR=/home/t3/.local/share/mise" "$server_env"
  has "the server inherits the mise shims on PATH" \
    "/home/t3/.local/share/mise/shims" "$server_env"
else
  no "could not find the running T3 server process"
fi

# --- idiomatic detection -----------------------------------------------------
printf '\nIdiomatic detection\n'
idiomatic="$(ulogin "$FIXTURES/idiomatic" 'mise config ls')"
matches "detects .nvmrc as node"      '\.nvmrc[[:space:]]+node' "$idiomatic"
matches "detects .python-version"     '\.python-version[[:space:]]+python' "$idiomatic"
matches "detects rust-toolchain.toml" 'rust-toolchain.toml[[:space:]]+rust' "$idiomatic"
matches "detects go.mod as go"        'go\.mod[[:space:]]+go' "$idiomatic"
matches "detects global.json as dotnet" 'global\.json[[:space:]]+dotnet' "$idiomatic"
matches "detects Taskfile.yml as task"  'Taskfile.yml[[:space:]]+task' "$idiomatic"
matches "detects .bun-version"        '\.bun-version[[:space:]]+bun' "$idiomatic"
matches "detects .terraform-version"  '\.terraform-version[[:space:]]+terraform' "$idiomatic"
matches "detects .zig-version"        '\.zig-version[[:space:]]+zig' "$idiomatic"

package_json="$(ulogin "$FIXTURES/package-json" 'mise config ls')"
matches "package.json selects node and npm" 'package\.json[[:space:]]+node, npm' "$package_json"

ulogin "$FIXTURES/disabled" 'mise trust' >/dev/null 2>&1 || true
disabled="$(ulogin "$FIXTURES/disabled" 'mise config ls')"
has "a project mise.toml still loads" "mise.toml" "$disabled"
hasnt "a project can disable one detector file" ".nvmrc" "$disabled"

# --- precedence --------------------------------------------------------------
printf '\nPrecedence\n'
precedence="$(ulogin "$FIXTURES/precedence" 'mise ls --json')"
is "explicit mise.toml wins over .tool-versions and .nvmrc" \
  "20" "$(printf '%s' "$precedence" | jq -r '.node[0].requested_version // empty')"
matches "the winning source is the project mise.toml" \
  'mise\.toml$' "$(printf '%s' "$precedence" | jq -r '.node[0].source.path // empty')"
tool_versions="$(ulogin "$FIXTURES/tool-versions" 'mise ls --json')"
is ".tool-versions is honored when present" \
  "20.11.0" "$(printf '%s' "$tool_versions" | jq -r '.node[0].requested_version // empty')"

# --- explicit execution ------------------------------------------------------
printf '\nExplicit execution\n'
check "mise install --locked installs the locked fixture" \
  "docker exec -u t3 -w $FIXTURES/locked $NAME bash -lc 'mise install --locked'"
is "mise exec runs a locked tool" \
  "jq-1.8.2" "$(ulogin "$FIXTURES/locked" 'mise exec -- jq --version')"
matches "mise run resolves project tools" \
  'jq-1\.8\.2' "$(ulogin "$FIXTURES/locked" 'mise run versions')"
check "mise exec auto-installs a declared missing tool" \
  "docker exec -u t3 -w $FIXTURES/exec-install $NAME bash -lc 'mise exec -- shfmt --version'"
is "the auto-installed tool runs" \
  "v3.14.1" "$(ulogin "$FIXTURES/exec-install" 'mise exec -- shfmt --version')"

# --- failure modes -----------------------------------------------------------
printf '\nFailure modes\n'
sys_node="$(dex node --version)"
unsupported="$(docker exec -u t3 -w "$FIXTURES/unsupported" "$NAME" bash -lc 'mise exec -- node --version' 2>&1 || true)"
fails "an impossible version fails explicit execution" \
  docker exec -u t3 -w "$FIXTURES/unsupported" "$NAME" bash -lc 'mise exec -- node --version'
hasnt "an impossible version does not run the system node" "$sys_node" "$unsupported"

malformed="$(docker exec -u t3 -w "$FIXTURES/malformed" "$NAME" bash -lc 'mise ls' 2>&1 || true)"
matches "a malformed manifest fails loudly" 'TOML parse error' "$malformed"

# A shim for a tool that is not installed is where not_found_system_fallback
# applies. jq exists at /usr/bin/jq, so the difference is visible.
sys_jq="$(dex /usr/bin/jq --version)"
fallback="$(docker exec -u t3 -e MISE_AUTO_INSTALL=false -w "$FIXTURES/fallback" "$NAME" bash -lc 'jq --version' 2>&1 || true)"
fails "a missing shim tool fails instead of using the system one" \
  docker exec -u t3 -e MISE_AUTO_INSTALL=false -w "$FIXTURES/fallback" "$NAME" bash -lc 'jq --version'
hasnt "the system jq did not run" "$sys_jq" "$fallback"
fallback_on="$(docker exec -u t3 -e MISE_AUTO_INSTALL=false -e MISE_NOT_FOUND_SYSTEM_FALLBACK=true \
  -w "$FIXTURES/fallback" "$NAME" bash -lc 'jq --version' 2>&1 || true)"
has "the fallback setting is what suppresses the system jq" "$sys_jq" "$fallback_on"

# --- ownership of installed state --------------------------------------------
printf '\nOwnership\n'
is "installed tool state is owned by t3" \
  "t3:t3" "$(dex stat -c %U:%G /home/t3/.local/share/mise)"
is "no root-owned files appeared under the user mise tree" \
  "" "$(dex find /home/t3/.config/mise /home/t3/.local/share/mise /home/t3/.cache/mise /home/t3/.local/state/mise -user root 2>/dev/null || true)"

# --- offline reuse -----------------------------------------------------------
printf '\nOffline reuse of the same home\n'
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$OFFLINE" --network none \
  -v "${HOME_VOLUME}:/home/t3" "$IMAGE" sleep infinity >/dev/null
for i in $(seq 1 30); do
  docker exec "$OFFLINE" true >/dev/null 2>&1 && break
  [ "$i" = 30 ] && { no "offline container never started"; exit 1; }
  sleep 1
done
copy_fixtures "$OFFLINE"

check "no network is reachable in the offline container" \
  "docker exec $OFFLINE sh -c '! curl -fsS --max-time 3 https://example.com'"
is "a locked tool still runs offline" \
  "jq-1.8.2" "$(ologin "$FIXTURES/locked" 'mise exec -- jq --version')"
check "mise install --locked succeeds offline from the cache" \
  "docker exec -u t3 -w $FIXTURES/locked $OFFLINE bash -lc 'mise install --locked'"
matches "mise run still resolves project tools offline" \
  'jq-1\.8\.2' "$(ologin "$FIXTURES/locked" 'mise run versions')"

printf '\n%d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
