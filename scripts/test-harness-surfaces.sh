#!/usr/bin/env bash
# Assert the harness lifecycle surfaces share one manager.
#
#   scripts/test-harness-surfaces.sh [image]     (default: t3code:slim)
#
# The unit under test is TM-08 on one real amd64 image: the Agents card's
# lifecycle endpoints and the noninteractive `t3-harness` CLI over the shared
# harness manager, with the transitional baked harnesses as fallback.
#
#   - unauthenticated lifecycle reads and mutations are rejected (401);
#   - GET /harnesses and /status expose the same five managed facts the CLI
#     reports: exact versions, runnable state, failures, and baked fallback;
#   - read-only polling changes no mise selection, config, or manager state;
#   - explicit-version install/update via UI and CLI agree, and uninstall
#     preserves credentials while reporting the baked fallback;
#   - a concurrent operation is refused with busy/409 on both surfaces;
#   - prefixed routes (/__setup/...) answer the same JSON;
#   - the CLI works as root (dropping to t3) and leaves t3-owned state.
#
# The setup server and the harness modules are copied into the container so a
# run tests the checkout, not a stale build. Only three npm harnesses are
# installed; cursor/grok exercise fallback and validation paths without their
# large downloads.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-t3code:slim}"
NAME="t3code-surfaces-$$"
VOLUME="t3code-surfaces-home-$$"
SETUP_PORT="${SURFACES_PORT:-13778}"
SETUP_KEY="surfaces-test-key"
HARNESS_SRC="${ROOT}/docker/harness"
PROVIDER_SRC="${ROOT}/docker/provider-integration"
SETUP_SRC="${ROOT}/docker/setup"
BIN_SRC="${ROOT}/docker/bin/t3-harness"
HARNESS_DEST=/opt/t3-harness
PROVIDER_DEST=/opt/t3-provider
SETUP_DEST=/opt/t3-setup
BIN_DEST=/usr/local/bin/t3-harness

CLAUDE_VERSION=2.1.270
CODEX_VERSION=0.154.0
OPENCODE_VERSION=1.18.30
OPENCODE_UPDATE=1.18.31

pass=0
fail=0
ok()    { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()    { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
is() { # label expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected [$2], got [$3])"; fi
}
has() { # label needle haystack
  if printf '%s' "$3" | grep -Fq -- "$2"; then ok "$1"; else no "$1 (missing [$2] in [$3])"; fi
}
hasnt() { # label needle haystack
  if printf '%s' "$3" | grep -Fq -- "$2"; then no "$1 (unexpected [$2])"; else ok "$1"; fi
}
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

dex()   { docker exec -u t3 -e HOME=/home/t3 -w /home/t3 "$NAME" "$@"; }
droot() { docker exec "$NAME" "$@"; }
field() { printf '%s' "$2" | jq -r "$1"; }
mise_ls() { dex mise ls --json 2>/dev/null || printf '{}'; }
mise_config() { dex sh -c 'cat /home/t3/.config/mise/config.toml 2>/dev/null || printf "__absent__"'; }
recorded() { dex sh -c 'cat /home/t3/.local/state/mise/harness-state.json 2>/dev/null || printf "__absent__"'; }

api() { # method path [body] — authenticated
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    docker exec "$NAME" curl -fsS --noproxy '*' --max-time 60 -X "$method" \
      -H "x-t3-setup-key: ${SETUP_KEY}" -H 'content-type: application/json' \
      -d "$body" "http://127.0.0.1:${SETUP_PORT}${path}" 2>/dev/null
  else
    docker exec "$NAME" curl -fsS --noproxy '*' --max-time 30 -X "$method" \
      -H "x-t3-setup-key: ${SETUP_KEY}" "http://127.0.0.1:${SETUP_PORT}${path}" 2>/dev/null
  fi
}
api_code() { # method path [body] — authenticated, prints HTTP code
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    docker exec "$NAME" curl -s --noproxy '*' --max-time 60 -o /tmp/surf-body-$$ -w '%{http_code}' \
      -X "$method" -H "x-t3-setup-key: ${SETUP_KEY}" -H 'content-type: application/json' \
      -d "$body" "http://127.0.0.1:${SETUP_PORT}${path}" 2>/dev/null
  else
    docker exec "$NAME" curl -s --noproxy '*' --max-time 30 -o /tmp/surf-body-$$ -w '%{http_code}' \
      -X "$method" -H "x-t3-setup-key: ${SETUP_KEY}" "http://127.0.0.1:${SETUP_PORT}${path}" 2>/dev/null
  fi
}
anon_code() { # method path [body] — no key, prints HTTP code
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    docker exec "$NAME" curl -s --noproxy '*' --max-time 30 -o /dev/null -w '%{http_code}' \
      -X "$method" -H 'content-type: application/json' \
      -d "$body" "http://127.0.0.1:${SETUP_PORT}${path}" 2>/dev/null
  else
    docker exec "$NAME" curl -s --noproxy '*' --max-time 30 -o /dev/null -w '%{http_code}' \
      -X "$method" "http://127.0.0.1:${SETUP_PORT}${path}" 2>/dev/null
  fi
}
cli() { dex t3-harness "$@"; }
cli_json() { dex t3-harness "$@" --json; }

printf '\nTesting harness lifecycle surfaces on %s\n' "$IMAGE"

section "Start the container and the checkout setup server"
docker volume create "$VOLUME" >/dev/null
docker run -d --name "$NAME" -e "T3_SETUP_KEY=${SETUP_KEY}" \
  -v "${VOLUME}:/home/t3" "$IMAGE" sleep infinity >/dev/null
for i in $(seq 1 60); do
  docker exec -u t3 "$NAME" test -w /home/t3 >/dev/null 2>&1 && break
  [ "$i" = 60 ] && { no "container never became usable"; exit 1; }
  sleep 1
done
docker exec "$NAME" mkdir -p "$HARNESS_DEST" "$PROVIDER_DEST" "$SETUP_DEST"
docker cp "${HARNESS_SRC}/." "${NAME}:${HARNESS_DEST}/" >/dev/null
docker cp "${PROVIDER_SRC}/." "${NAME}:${PROVIDER_DEST}/" >/dev/null
docker cp "${SETUP_SRC}/." "${NAME}:${SETUP_DEST}/" >/dev/null
docker cp "${BIN_SRC}" "${NAME}:${BIN_DEST}" >/dev/null
docker exec "$NAME" chmod -R a+rX "$HARNESS_DEST" "$PROVIDER_DEST" "$SETUP_DEST"
docker exec "$NAME" chmod 0755 "$BIN_DEST"
# The server under test is the checkout copy, run as t3 with the test key.
docker exec -d -u t3 -e HOME=/home/t3 -e "T3_SETUP_KEY=${SETUP_KEY}" \
  -e "T3_SETUP_PORT=${SETUP_PORT}" -e "T3_HARNESS_MODULE=${HARNESS_DEST}/index.mjs" \
  -e "T3_PROVIDER_MODULE=${PROVIDER_DEST}/index.mjs" \
  "$NAME" node "${SETUP_DEST}/server.mjs" >/dev/null
ready=0
for i in $(seq 1 60); do
  if docker exec "$NAME" curl -fsS --noproxy '*' --max-time 3 \
      "http://127.0.0.1:${SETUP_PORT}/status" -H "x-t3-setup-key: ${SETUP_KEY}" \
      >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
is "the checkout setup server answers" "1" "$ready"

section "Unauthenticated rejection"
is "GET /status without a key is rejected" "401" "$(anon_code GET /status)"
is "GET /harnesses without a key is rejected" "401" "$(anon_code GET /harnesses)"
is "POST install without a key is rejected" "401" \
  "$(anon_code POST /harnesses/install '{"id":"claude"}')"
is "POST uninstall without a key is rejected" "401" \
  "$(anon_code POST /harnesses/uninstall '{"id":"claude"}')"

section "Lifecycle status schema"
harnesses="$(api GET /harnesses)"
is "five harnesses are listed" "5" "$(field '.harnesses | length' "$harnesses")"
for id in claude codex opencode grok cursor; do
  one="$(field ".harnesses[] | select(.id == \"$id\")" "$harnesses")"
  has "$id exposes runnable state" '"runnable":' "$one"
  has "$id exposes exact versions" '"installedVersion":' "$one"
  has "$id exposes failure state" '"failed":' "$one"
  has "$id exposes the baked fallback" '"bakedFallback":' "$one"
  has "$id exposes sign-in actions" '"canSignIn":' "$one"
done
status_body="$(api GET /status)"
is "status carries five harnesses" "5" "$(field '.harnesses | length' "$status_body")"
has "status harnesses carry runnable state" '"runnable":' "$status_body"
has "status harnesses carry fallback state" '"bakedFallback":' "$status_body"
for id in claude codex opencode grok cursor; do
  is "$id reports a baked fallback in transition" "true" \
    "$(field ".harnesses[] | select(.id == \"$id\") | .bakedFallback.present" "$harnesses")"
  is "$id starts unmanaged" "false" \
    "$(field ".harnesses[] | select(.id == \"$id\") | .installed" "$harnesses")"
done

section "Read-only polling changes nothing"
before_ls="$(mise_ls)"
before_cfg="$(mise_config)"
before_state="$(recorded)"
api GET /harnesses >/dev/null
api GET "/harnesses?id=claude" >/dev/null
api GET /status >/dev/null
cli status >/dev/null
is "polling changed no mise selection" "$before_ls" "$(mise_ls)"
is "polling changed no mise config" "$before_cfg" "$(mise_config)"
is "polling wrote no manager state" "$before_state" "$(recorded)"

section "CLI and UI install the same exact versions"
cli_out="$(cli_json install claude --version "$CLAUDE_VERSION")"
is "CLI install reports ok" "true" "$(field '.ok' "$cli_out")"
is "CLI install records the exact version" "$CLAUDE_VERSION" \
  "$(field '.harness.installedVersion' "$cli_out")"
has "CLI install resolves a concrete executable" "mise/installs/claude/$CLAUDE_VERSION/" \
  "$(field '.harness.executable' "$cli_out")"
ui_body="$(api POST /harnesses/install "{\"id\":\"codex\",\"version\":\"$CODEX_VERSION\"}")"
is "UI install reports ok" "true" "$(field '.ok' "$ui_body")"
is "UI install records the exact version" "$CODEX_VERSION" \
  "$(field '.harness.installedVersion' "$ui_body")"
cli_codex="$(cli_json status codex)"
is "CLI sees the UI-installed version" "$CODEX_VERSION" \
  "$(field '.harness.installedVersion' "$cli_codex")"
ui_claude="$(api GET /harnesses | jq -c '.harnesses[] | select(.id=="claude")')"
is "UI sees the CLI-installed version" "$CLAUDE_VERSION" \
  "$(field '.installedVersion' "$ui_claude")"
has "provider sync ran after install" '"sync":' "$ui_body"

section "Explicit update keeps history"
op_install="$(api POST /harnesses/install "{\"id\":\"opencode\",\"version\":\"$OPENCODE_VERSION\"}")"
is "opencode install reports ok" "true" "$(field '.ok' "$op_install")"
op_update="$(cli_json update opencode --version "$OPENCODE_UPDATE")"
is "CLI update reports ok" "true" "$(field '.ok' "$op_update")"
is "update records the new exact version" "$OPENCODE_UPDATE" \
  "$(field '.harness.installedVersion' "$op_update")"
has "update keeps the replaced version" "$OPENCODE_VERSION" \
  "$(field '.harness.managedVersions | join(",")' "$op_update")"

section "Credentials survive uninstall with a fallback"
dex sh -c 'mkdir -p /home/t3/.local/share/opencode && printf "%s" "{\"anthropic\":{\"type\":\"api\",\"key\":\"surfaces-key\"}}" > /home/t3/.local/share/opencode/auth.json'
ui_uninstall="$(api POST /harnesses/uninstall '{"id":"opencode"}')"
is "UI uninstall reports ok" "true" "$(field '.ok' "$ui_uninstall")"
is "the harness is no longer installed" "false" "$(field '.harness.installed' "$ui_uninstall")"
is "the baked fallback is still reported" "true" \
  "$(field '.harness.bakedFallback.present' "$ui_uninstall")"
is "credentials were preserved" "surfaces-key" \
  "$(dex sh -c 'cat /home/t3/.local/share/opencode/auth.json' | jq -r '.anthropic.key')"
cli_status="$(cli_json status opencode)"
is "CLI agrees the harness is uninstalled" "false" "$(field '.harness.installed' "$cli_status")"

section "Validation errors match on both surfaces"
is "unknown UI harness is 404" "404" \
  "$(docker exec "$NAME" curl -s --noproxy '*' --max-time 15 -o /dev/null -w '%{http_code}' -X POST -H "x-t3-setup-key: ${SETUP_KEY}" -H 'content-type: application/json' -d '{"id":"nope"}' "http://127.0.0.1:${SETUP_PORT}/harnesses/install" 2>/dev/null)"
cli_unknown="$(cli install nope 2>&1 || true)"
has "unknown CLI harness names the harness" "nope" "$cli_unknown"
is "bad UI version is 400" "400" \
  "$(docker exec "$NAME" curl -s --noproxy '*' --max-time 15 -o /dev/null -w '%{http_code}' -X POST -H "x-t3-setup-key: ${SETUP_KEY}" -H 'content-type: application/json' -d '{"id":"claude","version":"!! not a version !!"}' "http://127.0.0.1:${SETUP_PORT}/harnesses/install" 2>/dev/null)"
if cli_json install claude --version '!! not a version !!' >/dev/null 2>&1; then
  no "bad CLI version should fail"
else
  ok "bad CLI version fails"
fi

section "Concurrent operations are refused on both surfaces"
dex node -e '
import("/opt/t3-harness/index.mjs").then(async ({ createHarnessManager }) => {
  const { createFs, processAlive } = await import("/opt/t3-harness/io.mjs");
  const lock = await import("/opt/t3-harness/lock.mjs");
  const os = await import("node:os");
  const path = await import("node:path");
  const home = "/home/t3";
  const stateDir = path.join(home, ".local/state/mise");
  const ctx = { fs: createFs(), stateDir, now: Date.now, pid: process.pid,
    isAlive: processAlive, host: os.hostname(),
    lockPath: path.join(stateDir, "harness.lock"), lockStaleMs: 15*60*1000 };
  const held = await lock.acquireLock(ctx, { id: "grok", operation: "install" });
  if (!held.acquired) process.exit(1);
  await new Promise((r) => setTimeout(r, 20000));
  await held.release();
});
' >/tmp/surf-hold-$$.log 2>&1 &
holder=$!
sleep 3
ui_busy_code="$(docker exec "$NAME" curl -s --noproxy '*' --max-time 15 -o /tmp/surf-busy-$$ -w '%{http_code}' -X POST -H "x-t3-setup-key: ${SETUP_KEY}" -H 'content-type: application/json' -d '{"id":"claude"}' "http://127.0.0.1:${SETUP_PORT}/harnesses/install" 2>/dev/null)"
is "concurrent UI install is refused with 409" "409" "$ui_busy_code"
has "concurrent UI refusal is busy" '"busy"' "$(docker exec "$NAME" cat /tmp/surf-busy-$$ 2>/dev/null || printf '')"
if cli_json install claude >/dev/null 2>&1; then
  no "concurrent CLI install should fail"
else
  ok "concurrent CLI install fails"
fi
busy_facts="$(api GET /harnesses)"
is "a harness under a live lock is not runnable" "false" \
  "$(field '.harnesses[] | select(.id=="grok") | .runnable' "$busy_facts")"
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

section "Prefixed routes answer the same JSON"
prefixed="$(docker exec "$NAME" curl -fsS --noproxy '*' --max-time 15 \
  -H "x-t3-setup-key: ${SETUP_KEY}" "http://127.0.0.1:${SETUP_PORT}/__setup/harnesses" 2>/dev/null)"
is "prefixed lifecycle status lists five" "5" "$(field '.harnesses | length' "$prefixed")"
prefixed_status="$(docker exec "$NAME" curl -fsS --noproxy '*' --max-time 15 \
  -H "x-t3-setup-key: ${SETUP_KEY}" "http://127.0.0.1:${SETUP_PORT}/__setup/status" 2>/dev/null)"
is "prefixed app status lists five" "5" "$(field '.harnesses | length' "$prefixed_status")"

section "The CLI drops privileges and keeps the user environment"
droot "$BIN_DEST" status >/dev/null
is "root-invoked CLI exits ok" "0" "$?"
owner="$(droot stat -c %U /home/t3/.local/state/mise/harness-state.json 2>/dev/null || printf 'missing')"
is "manager state stays owned by t3" "t3" "$owner"
has "CLI runs against the user mise state" "mise" "$(dex sh -c 'command -v mise' 2>/dev/null || printf 'missing')"

printf '\n%d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
