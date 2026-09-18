#!/usr/bin/env bash
# Assert T3 Code is wired to the managed harness executables.
#
#   scripts/test-provider-integration.sh [image] [browser-image]
#       (defaults: t3code:core, t3code:browser)
#
# The unit under test is the provider seam, on one real amd64 image:
#
#   - sync writes each runnable harness's exact managed executable into T3's
#     `providers.<driver>.binaryPath`, preserving unrelated config;
#   - an explicit `providerInstances` default instance is updated in place;
#   - Uninstall retracts only the value this module wrote;
#   - a running T3 server actually reads that path and probes the managed
#     executable (its cached snapshot reports the managed version and resolves
#     the update as manual-only), while a decoy earlier on PATH stays unused;
#   - t3-browser-mcp registers MCP with the managed Claude, Codex and OpenCode;
#   - no code gates Cursor's own self-updater.
#
# The modules are baked into the image by the Dockerfile; a current image is
# required because t3-login and t3-browser-mcp are baked too. The test still
# re-copies the modules so a run cannot accidentally test a stale build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-t3code:core}"
BROWSER_IMAGE="${2:-t3code:browser}"
NAME="t3code-provider-$$"
BROWSER_NAME="t3code-provider-browser-$$"
VOLUME="t3code-provider-home-$$"
BROWSER_VOLUME="t3code-provider-browser-home-$$"
HARNESS_SRC="${ROOT}/docker/harness"
PROVIDER_SRC="${ROOT}/docker/provider-integration"
HARNESS_DEST=/opt/t3-harness
PROVIDER_DEST=/opt/t3-provider
DRIVER=/tmp/pi-driver.mjs
STATE=/home/t3/.t3
SETTINGS="${STATE}/userdata/settings.json"
STATE_FILE="${STATE}/provider-integration.json"

# Exact versions to install through the manager, so the test exercises the
# same resolved artifact a user install would.
CLAUDE_VERSION=2.1.274
CODEX_VERSION=0.154.0
OPENCODE_VERSION=1.18.31

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
  docker rm -f "$NAME" "$BROWSER_NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" "$BROWSER_VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Which container the helpers act on. The browser section switches this.
CONTAINER="$NAME"
dex()       { docker exec -u t3 -e HOME=/home/t3 -w /home/t3 "$CONTAINER" "$@"; }
droot()     { docker exec "$CONTAINER" "$@"; }
sync_json() { dex node "${PROVIDER_DEST}/cli.mjs" sync --json; }
resolve_path() { dex node "${PROVIDER_DEST}/cli.mjs" resolve "$1" 2>/dev/null || true; }
resolve_code() { # exit code of the resolver for one harness
  if dex node "${PROVIDER_DEST}/cli.mjs" resolve "$1" >/dev/null 2>&1; then echo 0; else echo $?; fi
}
settings() { dex cat "$SETTINGS" 2>/dev/null || printf '{}'; }
manager_state() { dex cat "$STATE_FILE" 2>/dev/null || printf '{}'; }
field() { printf '%s' "$2" | jq -r "$1"; }

start_container() { # name image volume
  local name="$1" image="$2" volume="$3"
  docker volume create "$volume" >/dev/null
  docker run -d --name "$name" -e "T3_SETUP_KEY=provider-test-key" \
    -v "${volume}:/home/t3" "$image" sleep infinity >/dev/null

  # The entrypoint finishes ownership migration before it execs sleep; wait for
  # the user to be able to write its home before doing anything as t3.
  local i
  for i in $(seq 1 60); do
    docker exec -u t3 "$name" test -w /home/t3 >/dev/null 2>&1 && break
    [ "$i" = 60 ] && { no "container $name never became usable"; exit 1; }
    sleep 1
  done

  docker exec "$name" mkdir -p "$HARNESS_DEST" "$PROVIDER_DEST"
  docker cp "${HARNESS_SRC}/." "${name}:${HARNESS_DEST}/" >/dev/null
  docker cp "${PROVIDER_SRC}/." "${name}:${PROVIDER_DEST}/" >/dev/null
  docker exec "$name" chmod -R a+rX "$HARNESS_DEST" "$PROVIDER_DEST"

  # The driver runs as t3 with exactly the environment `docker exec` gives, and
  # imports the modules from where the image will bake them.
  docker exec -i -u t3 -e HOME=/home/t3 "$name" sh -c "cat > $DRIVER" <<'DRIVER_JS'
import { createHarnessManager } from "/opt/t3-harness/index.mjs";
import { promises as fsp } from "node:fs";
import path from "node:path";

const manager = createHarnessManager();
const [command, ...args] = process.argv.slice(2);
const out = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
const stateDir = process.env.T3CODE_HOME || path.join(process.env.HOME || "/home/t3", ".t3");
const settingsPath = path.join(stateDir, "userdata", "settings.json");

switch (command) {
  case "install":
    out(await manager.install(args[0], args[1] ? { version: args[1] } : {}));
    break;
  case "uninstall":
    out(await manager.uninstall(args[0]));
    break;
  case "status":
    out(await manager.status({ authenticate: false }));
    break;
  case "seed": {
    const seed = {
      defaultTheme: "dark",
      providers: {
        codex: { homePath: "/home/t3/.codex" },
        grok: { binaryPath: "/user/grok" },
      },
      providerInstances: {
        claudeAgent: { driver: "claudeAgent", config: { launchArgs: "--chrome" } },
        cursor: { driver: "cursor", enabled: false, config: { apiEndpoint: "https://cursor.example" } },
      },
    };
    await fsp.mkdir(path.dirname(settingsPath), { recursive: true });
    await fsp.writeFile(settingsPath, `${JSON.stringify(seed, null, 2)}\n`);
    out({ ok: true });
    break;
  }
  default:
    out({ error: `unknown command ${command}` });
    process.exitCode = 2;
}
DRIVER_JS
}

driver() { dex node "$DRIVER" "$@"; }

printf '\nTesting provider integration on %s\n' "$IMAGE"
start_container "$NAME" "$IMAGE" "$VOLUME"

# --- read-only baseline ------------------------------------------------------
section "Read-only baseline"
is "resolve reports no managed Claude" "3" "$(resolve_code claude)"
sync_baseline="$(sync_json)"
is "sync is ok" "true" "$(field '.ok' "$sync_baseline")"
is "sync applied nothing" "0" "$(field '.applied | length' "$sync_baseline")"
is "sync created no settings file" "absent" \
  "$(dex sh -c "test -f $SETTINGS && echo present || echo absent")"
is "sync created no state file" "absent" \
  "$(dex sh -c "test -f $STATE_FILE && echo present || echo absent")"
is "the image bakes the provider integration" "true" \
  "$(dex test -r /opt/t3-provider/cli.mjs && echo true || echo false)"
is "the baked entrypoint wires the integration" "true" \
  "$(droot sh -c 'grep -q sync_managed_providers /usr/local/bin/entrypoint.sh && echo true || echo false')"

# --- apply, preserving unrelated configuration -------------------------------
section "Apply managed executables and preserve unrelated config"
driver seed >/dev/null
install_claude="$(driver install claude "$CLAUDE_VERSION")"
is "claude installs from mise" "true" "$(field '.ok' "$install_claude")"
managed_claude="$(field '.harness.executable' "$install_claude")"
has "claude resolves to a mise install" "mise/installs/claude/$CLAUDE_VERSION/" "$managed_claude"
is "resolve prints the managed executable" "$managed_claude" "$(resolve_path claude)"
is "resolve exits 0 for a runnable harness" "0" "$(resolve_code claude)"
has "t3-login names the canonical cursor executable" "cursor-agent login" \
  "$(dex t3-login --help 2>&1)"
login_nostty="$(dex t3-login claude 2>&1 || true)"
has "t3-login accepts the managed claude" "no TTY" "$login_nostty"
hasnt "t3-login does not report the managed claude missing" "not installed" "$login_nostty"

sync_applied="$(sync_json)"
is "sync applied claude" "claude" "$(field '.applied[0].id' "$sync_applied")"
cfg="$(settings)"
is "settings records the managed claude path" "$managed_claude" \
  "$(field '.providers.claudeAgent.binaryPath' "$cfg")"
is "unrelated codex config is preserved" "/home/t3/.codex" \
  "$(field '.providers.codex.homePath' "$cfg")"
is "an unrelated top-level setting is preserved" "dark" "$(field '.defaultTheme' "$cfg")"
is "a user-set grok path is left alone" "/user/grok" "$(field '.providers.grok.binaryPath' "$cfg")"
is "an explicit default instance gets the managed path" "$managed_claude" \
  "$(field '.providerInstances.claudeAgent.config.binaryPath' "$cfg")"
is "its unrelated instance config is preserved" "--chrome" \
  "$(field '.providerInstances.claudeAgent.config.launchArgs' "$cfg")"
is "an unrelated instance keeps its disabled flag and config" "false" \
  "$(field '.providerInstances.cursor.enabled' "$cfg")"
is "no path is invented for an unmanaged instance" "null" \
  "$(field '.providerInstances.cursor.config.binaryPath // null' "$cfg")"
is "the cursor instance config is preserved" "https://cursor.example" \
  "$(field '.providerInstances.cursor.config.apiEndpoint' "$cfg")"
state="$(manager_state)"
is "the integration records what it wrote" "$managed_claude" \
  "$(field '.managed.claude.executable' "$state")"
is "the record names the T3 driver" "claudeAgent" "$(field '.managed.claude.driver' "$state")"

# --- uninstall retracts only our value ---------------------------------------
section "Uninstall retracts only the managed value"
driver uninstall claude >/dev/null
sync_cleared="$(sync_json)"
is "sync cleared claude" "claude" "$(field '.cleared[0].id' "$sync_cleared")"
cfg="$(settings)"
is "the managed claude path is gone" "null" \
  "$(field '.providers.claudeAgent.binaryPath // null' "$cfg")"
is "the instance path is gone too" "null" \
  "$(field '.providerInstances.claudeAgent.config.binaryPath // null' "$cfg")"
is "the preserved instance config survives" "--chrome" \
  "$(field '.providerInstances.claudeAgent.config.launchArgs' "$cfg")"
is "the user grok path is still untouched" "/user/grok" "$(field '.providers.grok.binaryPath' "$cfg")"
is "the state record is empty" "0" "$(field '.managed | length' "$(manager_state)")"

# --- a running T3 server uses the managed executable -------------------------
section "T3 server launches the managed executable"
driver install claude "$CLAUDE_VERSION" >/dev/null
driver install opencode "$OPENCODE_VERSION" >/dev/null
sync_launch="$(sync_json)"
is "sync applied two harnesses" "2" "$(field '.applied | length' "$sync_launch")"

# Decoys sit earlier on PATH. T3 must not use them: the configured absolute
# path is the seam, and a PATH resolution would prove it was ignored.
dex sh -c '
  mkdir -p /tmp/decoys
  rm -f /tmp/decoy.log
  for b in claude codex opencode grok cursor-agent; do
    printf "#!/bin/sh\nprintf \"decoy:%s\\n\" %s >> /tmp/decoy.log\nexit 0\n" "$b" "$b" > "/tmp/decoys/$b"
    chmod +x "/tmp/decoys/$b"
  done'

dex sh -c 'PATH=/tmp/decoys:$PATH nohup t3-admin serve --host 127.0.0.1 --port 3773 /workspace >/tmp/t3.log 2>&1 &'

cache="${STATE}/caches/claudeAgent.json"
colon=""
for _ in $(seq 1 90); do
  if dex test -f "$cache"; then colon=1; break; fi
  sleep 2
done
if [ -n "$colon" ]; then
  ok "T3 wrote a Claude provider snapshot"
else
  no "T3 never wrote a Claude provider snapshot"
  dex sh -c 'tail -40 /tmp/t3.log' || true
fi

if [ -n "$colon" ]; then
  snap="$(dex cat "$cache")"
  is "T3 reports the managed Claude version" "$CLAUDE_VERSION" "$(field '.version' "$snap")"
  is "the mise path resolves manual-only (no update command)" "null" \
    "$(field '.versionAdvisory.updateCommand // null' "$snap")"
  is "the mise path cannot be updated by T3" "false" "$(field '.versionAdvisory.canUpdate' "$snap")"
  is "the probe names the installed executable" "true" "$(field '.installed' "$snap")"
fi
decoy_log="$(dex sh -c 'cat /tmp/decoy.log 2>/dev/null || true')"
hasnt "the managed claude was not resolved from PATH" "decoy:claude" "$decoy_log"
hasnt "the managed opencode was not resolved from PATH" "decoy:opencode" "$decoy_log"
has "an unmanaged provider still falls back to PATH" "decoy:codex" "$decoy_log"
is "T3 never received an enableProviderUpdateChecks override" "null" \
  "$(field '.enableProviderUpdateChecks // null' "$(settings)")"

# --- MCP registration follows the managed harnesses --------------------------
printf '\nTesting browser MCP registration on %s\n' "$BROWSER_IMAGE"
if ! docker image inspect "$BROWSER_IMAGE" >/dev/null 2>&1; then
  no "browser image $BROWSER_IMAGE is not available"
else
  start_container "$BROWSER_NAME" "$BROWSER_IMAGE" "$BROWSER_VOLUME"
  CONTAINER="$BROWSER_NAME"

  install_claude="$(driver install claude "$CLAUDE_VERSION")"
  install_codex="$(driver install codex "$CODEX_VERSION")"
  install_opencode="$(driver install opencode "$OPENCODE_VERSION")"
  is "claude installs in the browser image" "true" "$(field '.ok' "$install_claude")"
  is "codex installs in the browser image" "true" "$(field '.ok' "$install_codex")"
  is "opencode installs in the browser image" "true" "$(field '.ok' "$install_opencode")"
  browser_sync="$(sync_json)"
  is "browser image sync applied three harnesses" "3" "$(field '.applied | length' "$browser_sync")"

  mcp_out="$(dex t3-browser-mcp --harness claude,codex,opencode 2>&1)"
  has "claude registers through the managed executable" \
    "via /home/t3/.local/share/mise/installs/claude/" "$mcp_out"
  has "codex registers through the managed executable" \
    "via /home/t3/.local/share/mise/installs/codex/" "$mcp_out"
  has "opencode registers through the managed executable" \
    "via /home/t3/.local/share/mise/installs/opencode/" "$mcp_out"
  has "claude registered playwright" "claude: registered playwright" "$mcp_out"

  is "codex config records the mcp server" "true" \
    "$(dex sh -c "grep -q '^\\[mcp_servers.playwright\\]' /home/t3/.codex/config.toml && echo true || echo false")"
  is "opencode config records the mcp server" "true" \
    "$(dex jq -e '.mcp.playwright.enabled' /home/t3/.config/opencode/opencode.json >/dev/null && echo true || echo false)"
  claude_mcp="$(dex sh -c 'grep -l playwright /home/t3/.claude.json 2>/dev/null | head -1 || true')"
  if [ -n "$claude_mcp" ]; then
    ok "claude user config records the mcp server"
  else
    no "claude user config does not record the mcp server"
  fi
fi

# --- no updater gating anywhere ----------------------------------------------
section "No provider updater is gated"
gate_files=(
  "${ROOT}/docker/provider-integration/index.mjs"
  "${ROOT}/docker/provider-integration/cli.mjs"
  "${ROOT}/docker/provider-integration/settings.mjs"
  "${ROOT}/docker/provider-integration/providers.mjs"
  "${ROOT}/docker/bin/t3-login"
  "${ROOT}/docker/bin/t3-browser-mcp"
  "${ROOT}/docker/entrypoint.sh"
)
gated=0
for file in "${gate_files[@]}"; do
  if grep -Eq 'cursor-agent[[:space:]]+update|self[-_]?update|disableUpdate|updateDisabled|DISABLE_UPDATE|--no-update' "$file"; then
    gated=1
    no "gating logic found in ${file#"$ROOT"/}"
  fi
done
[ "$gated" -eq 0 ] && ok "no code blocks, redirects or disables a provider self-update"

printf '\n%d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
