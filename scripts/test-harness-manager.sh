#!/usr/bin/env bash
# Assert the persistent harness manager against one real image.
#
#   scripts/test-harness-manager.sh [image]     (default: t3code:core)
#
# The unit under test is the catalogue's lifecycle against the pinned mise
# release on a real amd64 host: exact-version install for all five harnesses,
# read-only status and resolution, concurrency and interrupted-operation
# recovery, credential-preserving uninstall with no baked fallback, and
# persistence across container recreation.
#
# The module is copied into the container rather than assumed to be baked into
# the image: wiring it into the image is TM-07/TM-08's change, and this test
# must not depend on it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-t3code:core}"
NAME="t3code-harness-$$"
VOLUME="t3code-harness-home-$$"
PORT="${HARNESS_PORT:-13777}"
MODULE_SRC="${ROOT}/docker/harness"
MODULE_DEST=/opt/t3-harness
DRIVER=/tmp/hm-driver.mjs
HOLD_LOG=/tmp/hm-hold-$$.log

# The versions the transitional image bakes, so the managed installs are the
# same exact artifacts the fallback would otherwise provide.
CLAUDE_VERSION=2.1.270
CODEX_VERSION=0.154.0
OPENCODE_VERSION=1.18.30
OPENCODE_UPDATE=1.18.31
GROK_VERSION=1.0.30
CURSOR_VERSION=2026.09.15-d2fe57e

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
matches() { # label regex haystack
  if printf '%s' "$3" | grep -Eq -- "$2"; then ok "$1"; else no "$1 (no match for /$2/ in [$3])"; fi
}
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
  rm -f "$HOLD_LOG"
}
trap cleanup EXIT

dex()  { docker exec -u t3 -w /home/t3 "$NAME" "$@"; }
droot() { docker exec "$NAME" "$@"; }
driver() { dex node "$DRIVER" "$@"; }
field() { printf '%s' "$2" | jq -r "$1"; }
mise_ls() { dex mise ls --json 2>/dev/null || printf '{}'; }
mise_config() {
  dex sh -c 'cat /home/t3/.config/mise/config.toml 2>/dev/null || printf "__absent__"'
}
recorded() {
  dex sh -c 'cat /home/t3/.local/state/mise/harness-state.json 2>/dev/null || printf "__absent__"'
}

start_container() {
  docker volume create "$VOLUME" >/dev/null
  docker run -d --name "$NAME" \
    -p "127.0.0.1:${PORT}:3773" \
    -e "T3_SETUP_KEY=harness-test-key" \
    -v "${VOLUME}:/home/t3" \
    "$IMAGE" >/dev/null

  printf 'Waiting for the container to become healthy...\n'
  local url="http://127.0.0.1:${PORT}/.well-known/t3/environment"
  local i
  for i in $(seq 1 60); do
    if curl -fsS --noproxy '*' --max-time 5 "$url" >/dev/null 2>&1; then break; fi
    if [ "$i" = 60 ]; then
      no "container never became healthy"
      docker logs "$NAME" 2>&1 | tail -30
      exit 1
    fi
    sleep 2
  done

  droot mkdir -p "$MODULE_DEST"
  docker cp "${MODULE_SRC}/." "${NAME}:${MODULE_DEST}/" >/dev/null
  droot chmod -R a+rX "$MODULE_DEST"

  # The driver is piped in as the user, so it lives in the user's tmp and the
  # manager inside it uses exactly the environment `docker exec -u t3` gives.
  docker exec -i -u t3 "$NAME" sh -c "cat > $DRIVER" <<'DRIVER_JS'
import { createHarnessManager } from "/opt/t3-harness/index.mjs";
import { createFs, processAlive } from "/opt/t3-harness/io.mjs";
import * as lock from "/opt/t3-harness/lock.mjs";
import { spawn } from "node:child_process";
import { promises as fsp } from "node:fs";
import os from "node:os";
import path from "node:path";

const manager = createHarnessManager();
const [command, ...args] = process.argv.slice(2);
const out = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
const stateDir = process.env.MISE_STATE_DIR
  || path.join(process.env.HOME || "/home/t3", ".local/state/mise");

switch (command) {
  case "status":
    out(await manager.status({ authenticate: false }));
    break;
  case "resolve":
    out(await manager.resolve(args[0], { authenticate: false }));
    break;
  case "install":
    out(await manager.install(args[0], args[1] ? { version: args[1] } : {}));
    break;
  case "update":
    out(await manager.update(args[0], args[1] ? { version: args[1] } : {}));
    break;
  case "uninstall":
    out(await manager.uninstall(args[0]));
    break;
  case "exec": {
    const harness = await manager.resolve(args[0], { authenticate: false });
    if (!harness.runnable || !harness.executable) {
      out({ ok: false, error: "not runnable" });
      break;
    }
    const child = spawn(harness.executable, ["--version"], { stdio: ["ignore", "pipe", "pipe"] });
    let text = "";
    child.stdout.on("data", (chunk) => { text += chunk; });
    child.stderr.on("data", (chunk) => { text += chunk; });
    const code = await new Promise((resolve) => child.on("close", resolve));
    out({ ok: code === 0, text: text.trim().split("\n")[0] ?? "", executable: harness.executable });
    break;
  }
  case "hold": {
    const ctx = {
      fs: createFs(), stateDir, now: Date.now, pid: process.pid, isAlive: processAlive,
      host: os.hostname(), lockPath: path.join(stateDir, "harness.lock"),
      lockStaleMs: 15 * 60 * 1000,
    };
    const held = await lock.acquireLock(ctx, { id: args[0], operation: "install" });
    if (!held.acquired) { out({ held: false, error: "could not acquire" }); break; }
    out({ held: true, pid: process.pid });
    await new Promise((resolve) => setTimeout(resolve, Number(args[1] ?? 5000)));
    await held.release();
    break;
  }
  case "interrupt": {
    await fsp.mkdir(stateDir, { recursive: true });
    // A real pid that has already exited: the lock looks live but is not.
    const dead = await new Promise((resolve) => {
      const child = spawn("true");
      child.on("exit", () => resolve(child.pid));
    });
    const statePath = path.join(stateDir, "harness-state.json");
    let state = { schema: 1, harnesses: {} };
    try { state = JSON.parse(await fsp.readFile(statePath, "utf8")); } catch { /* fresh */ }
    state.harnesses[args[0]] = {
      ...(state.harnesses[args[0]] ?? {}),
      operation: { kind: "install", state: "in-progress", startedAt: 1, finishedAt: null, error: null },
    };
    await fsp.writeFile(statePath, `${JSON.stringify(state, null, 2)}\n`);
    await fsp.writeFile(path.join(stateDir, "harness.lock"), JSON.stringify({
      pid: dead, host: os.hostname(), token: "interrupted", id: args[0],
      operation: "install", startedAt: 1,
    }));
    out(await manager.resolve(args[0], { authenticate: false }));
    break;
  }
  case "authenticated":
    out(await manager.resolve(args[0], { authenticate: true }));
    break;
  default:
    out({ error: `unknown command ${command}` });
    process.exitCode = 2;
}
DRIVER_JS
}

printf '\nTesting the persistent harness manager on %s\n' "$IMAGE"
start_container

# --- read-only baseline ------------------------------------------------------
section "Read-only baseline"
before_ls="$(mise_ls)"
before_cfg="$(mise_config)"
baseline="$(driver status)"
is "the catalogue reports five harnesses" "5" "$(field '.harnesses | length' "$baseline")"
is "no mise failure is reported" "0" "$(field '.degraded | length' "$baseline")"
for id in claude codex opencode grok cursor; do
  facts="$(field ".harnesses[] | select(.id == \"$id\")" "$baseline")"
  is "$id is not configured" "false" "$(field '.configured' "$facts")"
  is "$id is not installed" "false" "$(field '.installed' "$facts")"
  is "$id does not appear runnable" "false" "$(field '.runnable' "$facts")"
  is "$id reports no baked fallback" "false" "$(field '.bakedFallback.present' "$facts")"
  is "$id is not failed" "false" "$(field '.failed' "$facts")"
done

driver status >/dev/null
driver resolve claude >/dev/null
driver resolve cursor >/dev/null
is "read-only calls did not change mise selections" "$before_ls" "$(mise_ls)"
is "read-only calls did not change the mise config" "$before_cfg" "$(mise_config)"
is "read-only calls wrote no manager state" "__absent__" "$(recorded)"

# --- exact-version install of every catalogue entry --------------------------
section "Exact-version install"
install_one() { # id version
  local id="$1" version="$2" out
  out="$(driver install "$id" "$version")"
  is "$id installs" "true" "$(field '.ok' "$out")"
  is "$id is configured" "true" "$(field '.harness.configured' "$out")"
  is "$id is installed" "true" "$(field '.harness.installed' "$out")"
  is "$id is runnable" "true" "$(field '.harness.runnable' "$out")"
  is "$id records the exact version" "$version" "$(field '.harness.installedVersion' "$out")"
  is "$id verified the executable version" "$version" "$(field '.harness.verifiedVersion' "$out")"
  matches "$id resolves a concrete executable" "mise/installs/[^/]+/$version/" "$(field '.harness.executable' "$out")"
  local ran
  ran="$(driver exec "$id")"
  is "$id managed executable runs" "true" "$(field '.ok' "$ran")"
  has "$id prints its version" "$version" "$(field '.text' "$ran")"
}
install_one claude   "$CLAUDE_VERSION"
install_one codex    "$CODEX_VERSION"
install_one opencode "$OPENCODE_VERSION"
install_one grok     "$GROK_VERSION"
install_one cursor   "$CURSOR_VERSION"

ls_after="$(mise_ls)"
is "mise records the exact claude request" "$CLAUDE_VERSION" "$(field '.claude[0].requested_version // empty' "$ls_after")"
is "mise records the exact cursor request" "$CURSOR_VERSION" "$(field '.["cursor-agent"][0].requested_version // empty' "$ls_after")"

state="$(recorded)"
is "the manager recorded the exact claude version" "$CLAUDE_VERSION" "$(field '.harnesses.claude.version' "$state")"
is "the manager recorded the verified claude version" "$CLAUDE_VERSION" "$(field '.harnesses.claude.verifiedVersion' "$state")"

# --- update ------------------------------------------------------------------
section "Explicit update"
update_out="$(driver update opencode "$OPENCODE_UPDATE")"
is "update succeeds" "true" "$(field '.ok' "$update_out")"
is "update records the new exact version" "$OPENCODE_UPDATE" "$(field '.harness.installedVersion' "$update_out")"
has "update keeps the replaced version in the managed set" "$OPENCODE_VERSION" "$(field '.harness.managedVersions | join(",")' "$update_out")"
has "update keeps the new version in the managed set" "$OPENCODE_UPDATE" "$(field '.harness.managedVersions | join(",")' "$update_out")"
ran="$(driver exec opencode)"
has "the updated executable runs the new version" "$OPENCODE_UPDATE" "$(field '.text' "$ran")"

# --- concurrency -------------------------------------------------------------
section "Concurrency"
dex node "$DRIVER" hold opencode 8000 >"$HOLD_LOG" 2>&1 &
holder=$!
for i in $(seq 1 40); do
  grep -q '"held":true' "$HOLD_LOG" 2>/dev/null && break
  sleep 0.25
done
if grep -q '"held":true' "$HOLD_LOG" 2>/dev/null; then
  ok "a concurrent operation acquired the lock"
else
  no "the concurrent holder never acquired the lock"
fi
busy="$(driver install claude "$CLAUDE_VERSION")"
is "a concurrent install is refused" "false" "$(field '.ok' "$busy")"
is "the refusal is a busy lock" "busy" "$(field '.code' "$busy")"
held="$(driver resolve opencode)"
is "a harness under a live operation is in progress" "true" "$(field '.inProgress' "$held")"
is "a harness under a live operation is not runnable" "false" "$(field '.runnable' "$held")"
wait "$holder" 2>/dev/null || true
after_hold="$(driver resolve opencode)"
is "the harness is runnable again once the holder releases" "true" "$(field '.runnable' "$after_hold")"

# --- interrupted operation recovery ------------------------------------------
section "Interrupted operation recovery"
stuck="$(driver interrupt grok)"
is "an interrupted operation is reported failed" "true" "$(field '.failed' "$stuck")"
is "an interrupted operation is not runnable" "false" "$(field '.runnable' "$stuck")"
matches "the failure names the interruption" "interrupted" "$(field '.failure' "$stuck")"
healed="$(driver install grok "$GROK_VERSION")"
is "the next install heals the interrupted state" "true" "$(field '.ok' "$healed")"
is "the healed harness is runnable" "true" "$(field '.harness.runnable' "$healed")"
is "the healed harness is not failed" "false" "$(field '.harness.failed' "$healed")"

# --- sign-in fact ------------------------------------------------------------
# A runnable harness probes its credential file through its managed executable.
section "Sign-in fact"
CRED_FILE=/home/t3/.local/share/opencode/auth.json
dex sh -c "mkdir -p /home/t3/.local/share/opencode && printf '%s' '{\"anthropic\":{\"type\":\"api\",\"key\":\"k\"}}' > $CRED_FILE"
auth_out="$(driver authenticated opencode)"
is "opencode is reported authenticated from its credential file" "true" "$(field '.authenticated' "$auth_out")"

# --- credential-preserving uninstall -----------------------------------------
section "Uninstall preserves credentials and reports no fallback"
uninstall_out="$(driver uninstall opencode)"
is "uninstall succeeds" "true" "$(field '.ok' "$uninstall_out")"
is "the harness is no longer configured" "false" "$(field '.harness.configured' "$uninstall_out")"
is "the harness is no longer installed" "false" "$(field '.harness.installed' "$uninstall_out")"
is "the managed executable is gone" "null" "$(field '.harness.executable' "$uninstall_out")"
is "no baked fallback remains" "false" "$(field '.harness.bakedFallback.present' "$uninstall_out")"
is "the credential surface is reported" "true" "$(field '.harness.credentials.present' "$uninstall_out")"
is "credentials were preserved" "k" \
  "$(dex sh -c "cat $CRED_FILE" | jq -r '.anthropic.key')"
# With no executable to probe, the honest verdict is unknown, not signed in.
uninstalled_auth="$(driver authenticated opencode)"
is "an uninstalled harness reports auth unknown" "null" "$(field '.authenticated' "$uninstalled_auth")"
is "no opencode request remains in mise" "0" \
  "$(mise_ls | jq '(.opencode // []) | length')"
is "the managed opencode executable is removed" "absent" \
  "$(droot sh -c 'test -x /home/t3/.local/share/mise/installs/opencode/1.18.31/opencode && echo present || echo absent')"

# --- persistence across recreation -------------------------------------------
section "Recreation with the same volume"
docker rm -f "$NAME" >/dev/null 2>&1
start_container
recreated="$(driver status)"
for pair in "claude $CLAUDE_VERSION" "codex $CODEX_VERSION" "grok $GROK_VERSION" "cursor $CURSOR_VERSION"; do
  id="${pair%% *}"; version="${pair##* }"
  facts="$(field ".harnesses[] | select(.id == \"$id\")" "$recreated")"
  is "$id survived recreation as installed" "true" "$(field '.installed' "$facts")"
  is "$id survived recreation as runnable" "true" "$(field '.runnable' "$facts")"
  is "$id kept its exact version" "$version" "$(field '.installedVersion' "$facts")"
  ran="$(driver exec "$id")"
  is "$id managed executable still runs" "true" "$(field '.ok' "$ran")"
done
opencode_facts="$(field '.harnesses[] | select(.id == "opencode")' "$recreated")"
is "the uninstalled harness is still not installed" "false" "$(field '.installed' "$opencode_facts")"
is "credentials survived recreation" "k" \
  "$(dex sh -c "cat $CRED_FILE" | jq -r '.anthropic.key')"

before_ls="$(mise_ls)"
driver status >/dev/null
driver resolve codex >/dev/null
is "read-only calls after recreation changed no selection" "$before_ls" "$(mise_ls)"

printf '\n%d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
