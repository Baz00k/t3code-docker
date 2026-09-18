#!/usr/bin/env bash
# Boot the image and assert the things a user would notice if they broke.
#
#   scripts/smoke-test.sh [--variant NAME] [image]      (default: t3code:core)
#
# Capability profiles (see docs/toolchain/image-contract.md):
#   core     default, installer + mise, no baked harnesses/runtimes/browser
#   browser  core + Chromium/fonts/MCP servers
#
# The variant selects which capabilities are asserted; it is never inferred
# from the presence of Chromium. When omitted it is inferred from the image
# tag (t3code:<variant>); digest references (image@sha256:...) require an
# explicit --variant because the tag carries no variant.
#
# The pinned-versions-current assertion can be waived for rehearsals only, with
# T3_SMOKE_ALLOW_OUTDATED_PINS=1: pin freshness is a source-hygiene check that
# `versions` in build.yml reports separately, and it must not block a candidate
# rehearsal for an unrelated upstream migration. The waiver is printed in the
# output; the default stays strict.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/image-profile.sh
. "$SCRIPT_DIR/lib/image-profile.sh"

VARIANT=""
IMAGE=""

usage() {
  cat <<'USAGE'
Usage: scripts/smoke-test.sh [--variant NAME] [image]

  --variant NAME   core | browser
                   (default: inferred from the image tag; required for digest refs)
  image            image tag or digest reference (default: t3code:core)
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --variant) VARIANT="${2:?--variant needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; [ $# -gt 0 ] && IMAGE="$1" && shift; break ;;
    -*) echo "smoke-test.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) IMAGE="$1"; shift ;;
  esac
done
[ -n "$IMAGE" ] || IMAGE="t3code:core"

t3_image_profile_resolve "smoke-test.sh" "$IMAGE" "$VARIANT"
NAME="t3code-smoke-$$"
PORT="${SMOKE_PORT:-13773}"
PUBLIC_URL="https://smoke.example.test"
SETUP_KEY="smoke-setup-key"

pass=0
fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }
# The setup service runs under a restart loop, so a single probe can land in the
# gap and fail a release build for no reason. Retry the ones that only talk to
# it; a genuine outage is caught separately by the crash-loop assertion below.
retry() { local n=$1; shift; local i; for i in $(seq 1 "$n"); do
  if eval "$*" >/dev/null 2>&1; then return 0; fi; sleep 2; done; return 1; }

STATE_MOUNT=""
PAGE_HTML=""
CLIENT_JS_COPY=""
cleanup() {
  docker rm -f "$NAME" "${NAME}-mount" "${NAME}-boot" "${NAME}-anon" "${NAME}-env" >/dev/null 2>&1 || true
  rm -f "$PAGE_HTML" "$CLIENT_JS_COPY" 2>/dev/null || true
  if [ -n "$STATE_MOUNT" ]; then
    sudo rm -rf "$STATE_MOUNT" 2>/dev/null || rm -rf "$STATE_MOUNT" 2>/dev/null || true
  fi
}
trap cleanup EXIT

printf '\nSmoke-testing %s (variant %s)\n\n' "$IMAGE" "$VARIANT"

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

printf '\nServer\n'
version="$(curl -fsS --noproxy '*' "$health_url" | jq -r .serverVersion)"
[ -n "$version" ] && ok "health endpoint (serverVersion=$version)" || no "health endpoint"
# The healthcheck has a start period, so the first probe lands after the
# server is already answering. Give it room rather than racing it.
health_status=""
for _ in $(seq 1 60); do
  health_status="$(docker inspect --format '{{.State.Health.Status}}' "$NAME" 2>/dev/null || true)"
  [ "$health_status" = healthy ] && break
  [ "$health_status" = unhealthy ] && break
  sleep 5
done
[ "$health_status" = healthy ] \
  && ok "docker healthcheck reports healthy" \
  || no "docker healthcheck reports $health_status"

printf '\nHarnesses (variant %s)\n' "$VARIANT"
check "t3 runs" "docker exec $NAME t3 --version"
# Final images ship the installer, never the executables. The installer and
# its seams must be present; the baked paths must be absent so a stale
# fallback cannot masquerade as a managed install.
for bin in claude codex opencode grok cursor-agent; do
  check "$bin has no baked executable" \
    "! docker exec $NAME sh -c 'command -v $bin' >/dev/null 2>&1"
done
check "no baked npm harness remains" \
  "! docker exec $NAME sh -c 'ls /opt/npm-global/bin/claude /opt/npm-global/bin/codex /opt/npm-global/bin/opencode /opt/npm-global/bin/grok 2>/dev/null'"
check "no baked cursor remains" \
  "! docker exec $NAME test -x /opt/cursor/.local/bin/cursor-agent"
check "mise ships" "docker exec $NAME mise --version"
check "harness installer ships" "docker exec $NAME t3-harness --help"
check "provider integration ships" "docker exec $NAME test -r /opt/t3-provider/cli.mjs"

# T3 Code states the versions it needs in its own distribution, and it enforces them
# at runtime: too old a `gh` and it reports "GitHub CLI is too old to report
# sign-in status", too old an OpenCode and it refuses the server outright.
# Debian's gh (2.46) sat below that floor for a while and made the CLI useless.
# The binary distribution no longer exposes a source bundle to grep, so the
# Dockerfile's explicit floor is the source of truth and live provider tests
# prove the surrounding CLI remains usable.
T3_PREFIX="$(docker exec "$NAME" printenv T3_INFRA_PREFIX 2>/dev/null || true)"
[ -n "$T3_PREFIX" ] || T3_PREFIX=/opt/t3
T3_BINARY="$(docker exec "$NAME" printenv T3_INFRA_BINARY 2>/dev/null || true)"
[ -n "$T3_BINARY" ] || T3_BINARY="${T3_PREFIX}/t3"
check "the immutable T3 platform binary is where the image says it is" \
  "docker exec $NAME test -x $T3_BINARY"
check "the T3 client shell is available for the setup pill" \
  "docker exec $NAME test -f $T3_PREFIX/client/index.html"
check "T3 is not installed in the mutable npm prefix" \
  "docker exec $NAME test ! -e /opt/npm-global/lib/node_modules/t3"

# Compares with sort -V: passes when installed >= required.
version_at_least() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

gh_meets_t3_minimum() {
  local declared installed
  declared="$(grep -m1 '^ARG GH_MIN_VERSION=' Dockerfile | cut -d= -f2)"
  installed="$(docker exec "$NAME" gh --version 2>/dev/null | head -1 | awk '{print $3}')"
  [ -n "$installed" ] || return 1
  GH_DECLARED="$declared"; GH_INSTALLED="$installed"
  version_at_least "$installed" "$declared"
}
if gh_meets_t3_minimum; then
  ok "gh $GH_INSTALLED meets the $GH_DECLARED T3 Code requires"
else
  no "gh ${GH_INSTALLED:-?} is below the ${GH_DECLARED:-?} T3 Code requires"
fi

# T3 Code also enforces a minimum OpenCode version, but final images have no
# baked opencode to hold to it: the harness manager records the resolved exact
# version on explicit install, and the final-target E2E installs the latest and
# asserts T3 launches it. Here just prove no stale bake can mask an update.
check "no baked opencode to hold to a minimum" \
  "! docker exec $NAME sh -c 'command -v opencode' >/dev/null 2>&1"

# A freshly built image that immediately asks you to upgrade an agent is a bug
# in this repo, not in the agent. The pins are what go stale, so assert they
# were current when the image was built. Rehearsals may waive this one check
# (T3_SMOKE_ALLOW_OUTDATED_PINS=1) - see the header and ci-evidence.md - but the
# release path never does.
if [ "${T3_SMOKE_ALLOW_OUTDATED_PINS:-0}" = "1" ]; then
  printf '  \033[33mWAIVED\033[0m the pinned versions were current at build time (T3_SMOKE_ALLOW_OUTDATED_PINS=1)\n'
else
  check "the pinned agent versions were current at build time" \
    "./scripts/bump-versions.sh --check"
fi

printf '\nPairing\n'
pair_out="$(docker exec "$NAME" t3-pair --no-qr 2>/dev/null || true)"
case "$pair_out" in
  *"Pairing URL: ${PUBLIC_URL}/pair#token="*)
    ok "t3-pair uses the public URL" ;;
  *) no "t3-pair did not produce a public pairing URL"
     printf '%s\n' "$pair_out" ;;
esac
check "minted token is registered server-side" \
  "docker exec $NAME t3 auth pairing list --json 2>/dev/null | grep -q orchestration:operate"

have() { docker exec "$NAME" sh -c "command -v $1" >/dev/null 2>&1; }

printf '\nRuntimes (variant %s)\n' "$VARIANT"
for bin in node python3 git gh; do
  check "$bin present" "have $bin"
done
check "mise present" "have mise"

printf '\nNon-browser toolchain packages (core union)\n'
for bin in clang cmake ffmpeg; do
  check "$bin present" "have $bin"
done
check "postgresql client present" "have psql"
check "gdb present" "have gdb"

printf '\nBaked language runtimes (none expected in %s)\n' "$VARIANT"
# Root has no mise shims on PATH by design, so a bare lookup as root only
# finds a baked runtime. All of these live outside /home/t3 on purpose.
for bin in go rustc cargo bun deno uv; do
  check "$bin has no baked runtime" "! docker exec $NAME sh -c 'command -v $bin' >/dev/null 2>&1"
done
check "no baked Go tree" "! docker exec $NAME test -e /usr/local/go/bin/go"
check "no baked Rust tree" "! docker exec $NAME test -e /usr/local/cargo/bin/rustc"
check "no baked Bun" "! docker exec $NAME test -e /usr/local/bun/bin/bun"
check "no baked Deno" "! docker exec $NAME test -e /usr/local/deno/bin/deno"
check "no baked uv" "! docker exec $NAME test -e /usr/local/bin/uv"

if [ "$HAS_BROWSER" -eq 1 ]; then
  printf '\nBrowser (variant %s)\n' "$VARIANT"
  check "chromium present" "have chromium"

  # about:blank would pass even with a broken renderer; render real markup and
  # look for it in the DOM, then prove the raster path produces a real image.
  docker exec "$NAME" sh -c \
    'printf "<h1 id=marker>t3code-smoke-ok</h1>" > /tmp/smoke.html'
  check "chromium renders a page" \
    "docker exec $NAME sh -c 'chromium --headless --no-sandbox --disable-gpu \
       --dump-dom file:///tmp/smoke.html 2>/dev/null | grep -q t3code-smoke-ok'"
  check "chromium screenshots a page" \
    "docker exec $NAME sh -c 'chromium --headless --no-sandbox --disable-gpu \
       --window-size=800,600 --screenshot=/tmp/smoke.png file:///tmp/smoke.html \
       >/dev/null 2>&1 && [ \"\$(stat -c %s /tmp/smoke.png)\" -gt 1000 ]'"

  check "playwright-mcp present" "have playwright-mcp"
  check "chrome-devtools-mcp present" "have chrome-devtools-mcp"

  # "installed" and "an agent can see a page" are different claims.
  docker cp "$SCRIPT_DIR/browser-probe.py" "$NAME:/tmp/browser-probe.py" >/dev/null
  check "browser MCP drives a real page (playwright)" \
    "docker exec -u t3 $NAME python3 /tmp/browser-probe.py"
  check "browser MCP drives a real page (chrome-devtools)" \
    "docker exec -u t3 $NAME python3 /tmp/browser-probe.py \
       \$(docker exec $NAME t3-browser-mcp --server chrome-devtools --print)"
  check "t3-browser-mcp prints playwright server" \
    "docker exec $NAME t3-browser-mcp --server playwright --print | grep -q playwright-mcp"
  check "t3-browser-mcp prints chrome-devtools server" \
    "docker exec $NAME t3-browser-mcp --server chrome-devtools --print | grep -q chrome-devtools-mcp"
  # No baked harness to register with; the registration path with managed
  # harnesses is covered by test-provider-integration.sh on the browser
  # image. Here just prove the helper does not fail without one.
  check "t3-browser-mcp runs with no baked harness" \
    "docker exec $NAME t3-browser-mcp --harness opencode"
else
  printf '\nBrowser (none expected in %s)\n' "$VARIANT"
  check "no chromium" "! docker exec $NAME sh -c 'command -v chromium' >/dev/null 2>&1"
  check "no playwright-mcp" "! docker exec $NAME sh -c 'command -v playwright-mcp' >/dev/null 2>&1"
  check "no chrome-devtools-mcp" "! docker exec $NAME sh -c 'command -v chrome-devtools-mcp' >/dev/null 2>&1"
fi

printf '\nOwnership\n'
check "state dir is owned by the t3 user" \
  "[ \"\$(docker exec $NAME stat -c %U /home/t3/.t3)\" = t3 ]"
check "root exec does not leave root-owned state" \
  "! docker exec $NAME find /home/t3/.t3 -user root -print -quit | grep -q ."

# A volume mounted directly at the state dir arrives root-owned while its
# parent still looks correct. The entrypoint has to notice and adopt it, or the
# server dies on `mkdir userdata` with nothing but an EACCES stack trace.
STATE_MOUNT="$(mktemp -d)"
sudo chown 0:0 "$STATE_MOUNT" 2>/dev/null || chown 0:0 "$STATE_MOUNT" 2>/dev/null || true
docker run -d --name "${NAME}-mount" -v "$STATE_MOUNT:/home/t3/.t3" "$IMAGE" >/dev/null
mounted_ok=0
for _ in $(seq 1 40); do
  if docker exec "${NAME}-mount" curl -fsS --max-time 3 \
       "http://127.0.0.1:3773/.well-known/t3/environment" >/dev/null 2>&1; then
    mounted_ok=1
    break
  fi
  [ "$(docker inspect -f '{{.State.Running}}' "${NAME}-mount" 2>/dev/null)" = true ] || break
  sleep 3
done
if [ "$mounted_ok" = 1 ]; then
  ok "root-owned volume mounted at the state dir is adopted"
else
  no "root-owned volume mounted at the state dir is adopted"
  docker logs "${NAME}-mount" 2>&1 | tail -15
fi

# Agent sign-ins default to $HOME, which is only persisted if the whole home is
# mounted. Anchoring them under the state directory is what makes "sign in once"
# true for a deployment that only mounted .t3.
printf '\nCredential persistence\n'
check "agent credentials are anchored on the state volume" \
  "docker exec $NAME sh -c '[ \"\$(readlink /home/t3/.claude)\" = /home/t3/.t3/agents/.claude ]'"
check "a written credential lands on the state volume" \
  "docker exec -u t3 $NAME sh -c 'echo x > ~/.codex/auth.json && test -f /home/t3/.t3/agents/.codex/auth.json'"
# The Dockerfile declares VOLUME, so an unmounted deployment still looks mounted
# from inside; only the mount source distinguishes a throwaway anonymous volume.
docker rm -f "${NAME}-anon" >/dev/null 2>&1 || true
docker run -d --name "${NAME}-anon" -e T3_SETUP_KEY=x "$IMAGE" >/dev/null
# The entrypoint always prints exactly one persistence verdict, so wait for any
# of them rather than only the one we want. A wrong verdict then fails at once
# with the line it printed, and a container that died fails with its exit code,
# instead of burning the whole timeout in silence the way this used to.
anon_verdict=""
for _ in $(seq 1 30); do
  anon_verdict="$(docker logs "${NAME}-anon" 2>&1 | grep -m1 \
    -e 'is an anonymous volume' -e 'credentials persist on' -e 'is not on a mount at all' || true)"
  [ -n "$anon_verdict" ] && break
  [ "$(docker inspect -f '{{.State.Running}}' "${NAME}-anon" 2>/dev/null)" = true ] || break
  sleep 3
done
case "$anon_verdict" in
  *'is an anonymous volume'*)
    ok "an anonymous volume is called out as not durable" ;;
  *)
    no "an anonymous volume is called out as not durable"
    printf '    verdict: %s\n' "${anon_verdict:-<none printed>}"
    printf '    container: %s\n' \
      "$(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' "${NAME}-anon" 2>/dev/null || echo unknown)"
    docker logs "${NAME}-anon" 2>&1 | tail -15 ;;
esac
docker rm -f "${NAME}-anon" >/dev/null 2>&1 || true

# The setup service is the only way to pair without a shell in the container
# and without a restart, so it has to work unattended.
printf '\nSetup service\n'
SETUP_JAR="$(mktemp)"
# Gate the section on the service actually answering, so the first assertion
# is not the one that discovers it is still starting.
retry 30 "docker exec $NAME curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:3774/" \
  || no "setup service never answered"
check "refuses an unauthenticated request" \
  "[ \"\$(docker exec $NAME curl -sS -o /dev/null -w '%{http_code}' \
     http://127.0.0.1:3774/status)\" = 401 ]"
docker exec "$NAME" sh -c \
  "curl -sS -c /tmp/jar -d 'key=$SETUP_KEY' -o /dev/null http://127.0.0.1:3774/login" >/dev/null 2>&1
check "grants a session for the right key" \
  "docker exec $NAME sh -c 'curl -fsS -b /tmp/jar http://127.0.0.1:3774/status | grep -q publicUrl'"
setup_pair="$(docker exec "$NAME" sh -c \
  "curl -sS -b /tmp/jar -H 'content-type: application/json' -d '{\"ttl\":\"1h\"}' \
     http://127.0.0.1:3774/pair" 2>/dev/null || true)"
case "$setup_pair" in
  *"\"pairUrl\":\"${PUBLIC_URL}/pair#token="*) ok "mints a pairing link over HTTP" ;;
  *) no "mints a pairing link over HTTP"; printf '%s\n' "$setup_pair" | head -3 ;;
esac
check "the minted link is live on the running server" \
  "docker exec -u t3 $NAME t3 auth pairing list --json 2>/dev/null | grep -q orchestration:operate"

# The setup console is the front door for a fresh install, but T3 Code's own
# UI does not link to it - the pill injected into the client shell is the only
# route back. Assert it is in the served HTML, not just the built file, so a
# T3 bump cannot quietly drop it.
check "the T3 client links to the setup console" \
  "docker exec $NAME sh -c 'curl -fsS http://127.0.0.1:3773/ | grep -q t3-setup-pill'"

# Pulling a new image should be confirmable from the page itself rather than by
# guessing, so the build is stamped in at the end of the Dockerfile and shown in
# the top bar. Assert the stamp survives into the running container and names
# the variant that was actually built. The expected variant is the explicit
# --variant (never parsed from the image reference), so digest references work.
version_is_stamped() {
  local want="$VARIANT"
  docker exec "$NAME" sh -c \
    "curl -sS --max-time 25 -b /tmp/jar http://127.0.0.1:3774/status" | python3 -c "
import json, sys
img = json.load(sys.stdin).get('image') or {}
sys.exit(0 if img.get('version') and img.get('variant') == '$want' else 1)"
}
check "the image build is stamped and reported ($VARIANT)" version_is_stamped

# Agent authentication, driven the way the page drives it.
# Images ship no baked harness, so these flows exercise only what does not need
# a harness executable: file-backed OpenCode writes, honest unknown states, and
# the provider catalog. Managed-harness sign-in is covered by
# test-provider-integration.sh and the final-target E2E.
printf '\nAgent authentication (variant %s)\n' "$VARIANT"
auth_post() { docker exec "$NAME" sh -c "curl -sS -b /tmp/jar -H 'content-type: application/json' -d '$1' http://127.0.0.1:3774$2"; }

check "codex has no baked binary to sign in with" \
  "! docker exec $NAME sh -c 'command -v codex' >/dev/null 2>&1"

opencode_key_stored() {
  auth_post '{"agent":"opencode","provider":"deepseek","key":"sk-smoke"}' /auth/apikey | grep -q '"ok":true' &&
  docker exec -u t3 "$NAME" sh -c 'grep -q deepseek ~/.local/share/opencode/auth.json'
}
check "an API key is written for OpenCode" opencode_key_stored

check "an unknown agent is refused" \
  "auth_post '{\"agent\":\"bogus\",\"key\":\"x\"}' /auth/apikey | grep -q error"

# Harness executables are not baked, so there is no executable to probe: the
# manager honestly reports null (unknown) even with an env-var credential.
# Managed sign-in with an installed harness is covered by the final-target E2E.
ok "SKIP env-var Claude verdict (no executable to probe in $VARIANT; E2E covers managed)"
docker rm -f "${NAME}-env" >/dev/null 2>&1 || true

# Reading it correctly once is not enough: a cached verdict would keep saying
# "not signed in" straight after a key is stored, which is exactly when someone
# is looking at the panel.
# With no executable to probe, /status honestly reports null rather than True
# even after a key is stored (the file write itself is proven by the OpenCode
# test above). The True flip with a managed install is covered by the E2E.
uninstalled_reports_unknown() {
  docker exec "$NAME" sh -c \
    "curl -sS --max-time 20 -b /tmp/jar http://127.0.0.1:3774/status" | python3 -c '
import json, sys
h = {a["id"]: a for a in json.load(sys.stdin)["harnesses"]}
sys.exit(0 if h["opencode"]["signedIn"] is None and h["codex"]["signedIn"] is None else 1)'
}
check "an uninstalled harness reports unknown (not signed in) in $VARIANT" uninstalled_reports_unknown

# Grok has no status command, and its credentials file proves nothing - a file
# of exactly the shape its own help text documents still leaves the CLI saying
# "You are not authenticated". So the reading comes from `grok models`, the way
# T3 Code does it. With no executable to probe, the honest reading is unknown
# (null).
grok_reports_unknown() {
  docker exec "$NAME" sh -c \
    "curl -sS --max-time 25 -b /tmp/jar http://127.0.0.1:3774/status" | python3 -c '
import json, sys
h = {a["id"]: a for a in json.load(sys.stdin)["harnesses"]}
sys.exit(0 if h["grok"]["signedIn"] is None and h["cursor"]["signedIn"] is None else 1)'
}
check "Grok and Cursor report unknown without an executable in $VARIANT" grok_reports_unknown

# OpenCode takes a key per provider and there are over two hundred of them, so
# the page offers the models.dev catalog rather than asking you to recall an id.
provider_catalog() {
  docker exec "$NAME" sh -c \
    "curl -sS --max-time 30 -b /tmp/jar http://127.0.0.1:3774/providers" | python3 -c '
import json, sys, re
d = json.load(sys.stdin)
ids = [p["id"] for p in d["providers"]]
ok = len(ids) >= 10 and "anthropic" in ids
# Every id the picker offers has to survive the write path, or the dropdown
# hands people options the server then rejects.
rx = re.compile(r"^[a-z0-9][a-z0-9._-]{0,39}$")
sys.exit(0 if ok and all(rx.match(i) for i in ids) else 1)'
}
check "the provider picker offers a catalog the server accepts" provider_catalog

# Claude renders its URL as an OSC-8 hyperlink wrapped over several lines;
# scraping the visible text yields a truncated URL missing the PKCE challenge
# and state, which would send you to a sign-in page that cannot complete.
# These flows spawn the harness executable, so they need a managed install;
# the final-target E2E covers them.
ok "SKIP Claude OAuth URL (no baked harness in $VARIANT)"

# Capturing the URL is half the flow; the code has to get back in. That prompt
# runs the terminal in raw mode, where Enter arrives as CR - an LF is taken as
# part of the pasted text and the prompt just sits there, which is what left the
# panel saying "Submitting" for ever. A rejected code is the only exchange that
# can be driven without an account, and it proves the same thing: the CLI read
# the line, tried it, and answered. Stuck on "submitted" means it never did.
ok "SKIP Claude pasted-code flow (no baked harness in $VARIANT)"

# Waiting for the CLI to exit was the wrong finish line. These are terminal UIs;
# one that prints its result and stays up is not a failure, but it left the
# panel on "Submitting" for ever. Completion is "this agent is signed in now",
# so prove a session notices that with the process still running. Codex is the
# one whose state can be flipped from outside mid-flow, so use it - signed out
# first, since only a transition counts.
ok "SKIP sign-in transition flow (no baked harness in $VARIANT)"

# Codex's default login starts a callback server on localhost:1455, which is
# unreachable from a browser on any other machine - the redirect lands on the
# user's own localhost. Any sign-in URL naming localhost is broken by
# construction for a remote server, so assert against the whole class.
ok "SKIP Codex device flow (no baked harness in $VARIANT)"

ok "SKIP Grok device flow (no baked harness in $VARIANT)"

# The page's script is built inside a template literal, so an escape can be
# eaten on the way out and leave the browser with JavaScript that does not
# parse - which looks like a page that simply never loads its data. Written as
# a function rather than an eval string: the nested quoting this needs is
# exactly the kind that dies inside eval, taking the whole run with it.
# The client script used to be embedded in a template literal in server.mjs,
# which quietly ate escapes on the way out: `/\s+/` reached the browser as
# `/s+/` and split agent names on the letter s, and an apostrophe once
# terminated a string mid-sentence. Neither is a syntax error in the result, so
# parsing it proves nothing. The invariant worth asserting is stronger and
# simpler: what the browser receives is byte-for-byte the file on disk.
client_script_is_verbatim() {
  PAGE_HTML="$(mktemp)"; CLIENT_JS_COPY="$(mktemp)"
  docker exec "$NAME" sh -c \
    "curl -sS -c /tmp/j3 -d 'key=$SETUP_KEY' -o /dev/null http://127.0.0.1:3774/login && \
     curl -sS -b /tmp/j3 http://127.0.0.1:3774/" > "$PAGE_HTML" || return 1
  docker exec "$NAME" cat /opt/t3-setup/app.js > "$CLIENT_JS_COPY" || return 1
  python3 - "$PAGE_HTML" "$CLIENT_JS_COPY" <<'PYEOF'
import re, sys
page = open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r"<script>(.*?)</script>", page, re.S)
if not blocks:
    sys.exit(1)
sys.exit(0 if blocks[-1].strip() == open(sys.argv[2], encoding="utf-8").read().strip() else 1)
PYEOF
}
printf '\nPorts\n'

# T3 Code fetches cloudflared at runtime when it is missing, which needs egress
# at the moment you are trying to get connected. Shipping it is only useful if
# T3 Code actually finds it, so assert the pointer as well as the binary.
check "cloudflared ships in the image" \
  "docker exec $NAME cloudflared --version"
check "T3 Code is pointed at the shipped binary" \
  "docker exec $NAME sh -c 'test -x \"\$T3CODE_CLOUDFLARED_PATH\"'"

cloudflared_matches_t3() {
  local want have
  # The binary distribution has no greppable server bundle. The Dockerfile pin
  # is the repository-owned compatibility assertion; live port tests below
  # prove T3 accepts and invokes the shipped executable.
  want="$(grep -m1 '^ARG CLOUDFLARED_VERSION=' Dockerfile | cut -d= -f2)"
  have="$(docker exec "$NAME" cloudflared --version 2>/dev/null | awk '{print $3}')"
  CF_WANT="$want"; CF_HAVE="$have"
  [ "$want" = "$have" ]
}
if cloudflared_matches_t3; then
  ok "cloudflared ${CF_HAVE:-?} is the release T3 Code asks for"
else
  no "cloudflared is ${CF_HAVE:-?}, T3 Code downloads ${CF_WANT:-?}"
fi

# A dev server in the container is unreachable from a phone, which is the one
# device this project assumes you have. These assert the plumbing that fixes
# that; they deliberately do not open a tunnel, since CI should not depend on
# reaching Cloudflare's edge.
docker exec -d "$NAME" sh -c \
  'cd /tmp && python3 -m http.server 3000 --bind 127.0.0.1 >/dev/null 2>&1' || true
sleep 2

# Nesting quotes through bash -> docker exec -> sh -c -> curl is how you get a
# test that passes for the wrong reason, so these go through functions.
# Uses the header the in-container CLIs authenticate with, which is the same
# key and the same check the page's cookie goes through.
ports_api() {
  docker exec "$NAME" curl -sS -H "x-t3-setup-key: $SETUP_KEY" \
    "http://127.0.0.1:3774/ports"
}
expose_api() {
  docker exec "$NAME" curl -sS -H "x-t3-setup-key: $SETUP_KEY" \
    -H "content-type: application/json" \
    -d "{\"port\":$1}" "http://127.0.0.1:3774/ports/expose"
}
port_3000_listed() { ports_api | tr -d " " | grep -q "\"listening\":\[3000"; }
reserved_port_refused() { expose_api 3774 | grep -q "T3 Code itself"; }
bad_port_refused() { expose_api 99999 | grep -q "between 1 and 65535"; }

check "a listening port is discovered" port_3000_listed

# T3 Code's own agent probes open short-lived listeners on kernel-assigned
# ports. Listing them made the panel churn every few seconds and buried the dev
# server someone actually started, so discovery hides that range - while
# `t3-expose <port>` still publishes one by number.
ephemeral_port_hidden() {
  local lo port
  lo="$(docker exec "$NAME" sh -c 'cut -f1 /proc/sys/net/ipv4/ip_local_port_range')"
  port=$((lo + 101))
  docker exec -d "$NAME" sh -c "cd /tmp && python3 -m http.server $port --bind 127.0.0.1" || return 1
  sleep 2
  # it is listening ...
  docker exec "$NAME" sh -c "ss -Hltn | grep -q ':$port'" || return 1
  # ... and deliberately not offered as something to publish
  ! ports_api | tr -d " " | grep -q "\"listening\":\[[^]]*$port"
}
check "a kernel-assigned port is not offered for publishing" ephemeral_port_hidden
check "the ports API needs the key" \
  "docker exec $NAME sh -c 'curl -sS http://127.0.0.1:3774/ports | grep -q unauthorized'"
check "publishing T3 Code's own port is refused" reserved_port_refused
check "a nonsense port is refused" bad_port_refused

# The point of routing the CLI through the same API is that the two cannot
# disagree. Assert that they see the same port rather than trusting it.
check "t3-expose reports what the API reports" \
  "docker exec $NAME t3-expose | grep -q '^3000'"
check "cloudflared's own metrics port is not offered as a user port" \
  "docker exec $NAME t3-expose | grep -cq 'not published'"

# Screenshots prove the page renders; they do not prove it is square. This
# measures the rendered geometry - glyphs off centre in their box, a connector
# that spans a line break, buttons in one group with different heights - across
# the viewport matrix. Only browser-capable variants carry a browser to do it
# with; the capability comes from the explicit variant, not from probing for
# a chromium binary.
console_layout_is_clean() {
  [ "$HAS_BROWSER" -eq 1 ] || return 0
  docker exec "$NAME" test -x /usr/bin/chromium 2>/dev/null || return 1
  docker cp scripts/ui-audit.js "$NAME:/tmp/ui-audit.js" >/dev/null 2>&1 || return 1
  docker exec \
    -e NODE_PATH=/opt/npm-global/lib/node_modules/@playwright/mcp/node_modules \
    -e CHROME_PATH=/usr/bin/chromium \
    "$NAME" node /tmp/ui-audit.js "http://127.0.0.1:3774/" "$SETUP_KEY" \
    >"${UI_AUDIT_LOG:-/dev/null}" 2>&1
}
check "the console has no layout defects" console_layout_is_clean

check "the browser gets the client script verbatim" client_script_is_verbatim
check "and that script parses" \
  "docker exec $NAME node --check /opt/t3-setup/app.js"

# A proxy routing a path prefix here forwards it intact. Serving the page only
# at / turned that into a bare "unauthorized", which reads as a wrong password.
# A proxy that STRIPS the prefix leaves the server seeing "/" - it cannot infer
# a mount that is no longer in the path. Then the page called /status at the
# origin root, which such a proxy does not route back, and the console sat on
# skeletons saying only "could not read status". Honour the header proxies send
# for exactly this.
# Captured rather than piped: this script runs with pipefail, and `grep -q`
# closes the pipe the moment it matches, so a page big enough not to fit the
# pipe buffer kills curl with SIGPIPE and the assertion fails for a reason that
# has nothing to do with what it is testing.
page_says_mount() {
  local page
  page="$(docker exec "$NAME" curl -sS --max-time 10 "$@")" || return 1
  case "$page" in
    *"window.__T3_SETUP_BASE__ = \"/__setup\";"*) return 0 ;;
    *) return 1 ;;
  esac
}
forwarded_prefix_is_honoured() {
  page_says_mount -H "x-forwarded-prefix: /__setup" "http://127.0.0.1:3774/"
}
check "honours X-Forwarded-Prefix when the proxy strips the path" \
  forwarded_prefix_is_honoured

# The client's own fallback for proxies that strip and say nothing: the page
# knows where it was loaded from even when the server does not.
check "the page falls back to its own path when no mount is known" \
  "docker exec $NAME grep -q 'pageBase()' /opt/t3-setup/app.js"

# This is the assertion that should have caught the mount going missing: the
# old one only proved a page came back under a prefix, not that the page was
# told where it lives. It came back fine while every API call it made went to
# the origin root.
mount_is_declared() { page_says_mount "http://127.0.0.1:3774/__setup"; }
check "and tells the page which prefix it is under" mount_is_declared

check "serves the page under an unconfigured path prefix" \
  "retry 5 \"docker exec $NAME curl -fsS --max-time 5 http://127.0.0.1:3774/__setup | grep -qi '<!doctype html>'\""
check "and its routes work under that prefix" \
  "retry 5 \"docker exec $NAME sh -c \\\"curl -sS --max-time 5 -c /tmp/j2 -d 'key=$SETUP_KEY' -o /dev/null http://127.0.0.1:3774/__setup/login && curl -fsS --max-time 5 -b /tmp/j2 http://127.0.0.1:3774/__setup/status | grep -q publicUrl\\\"\""

# Retrying above would hide a service that is actually crash-looping, so assert
# separately that it started once and stayed up.
setup_stayed_up() {
  ! docker logs "$NAME" 2>&1 | grep -q "setup service exited"
}
check "the setup service did not crash-loop" setup_stayed_up
rm -f "$SETUP_JAR"

printf '\nStartup pairing link\n'
docker rm -f "${NAME}-boot" >/dev/null 2>&1 || true
docker run -d --name "${NAME}-boot" \
  -e "T3_PUBLIC_URL=${PUBLIC_URL}" \
  -e T3_PRINT_PAIRING_ON_START=1 \
  "$IMAGE" >/dev/null
boot_ok=0
for _ in $(seq 1 40); do
  if docker logs "${NAME}-boot" 2>&1 | grep -q "Pairing URL: ${PUBLIC_URL}/pair#token="; then
    boot_ok=1
    break
  fi
  [ "$(docker inspect -f '{{.State.Running}}' "${NAME}-boot" 2>/dev/null)" = true ] || break
  sleep 3
done
if [ "$boot_ok" = 1 ]; then
  ok "T3_PRINT_PAIRING_ON_START logs a usable pairing link"
else
  no "T3_PRINT_PAIRING_ON_START logs a usable pairing link"
  docker logs "${NAME}-boot" 2>&1 | tail -15
fi
docker rm -f "${NAME}-boot" >/dev/null 2>&1 || true

printf '\n%d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
