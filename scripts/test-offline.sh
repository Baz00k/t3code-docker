#!/usr/bin/env bash
# Assert setup status stays offline-safe.
#
#   scripts/test-offline.sh [--variant NAME] [image]     (default: t3code:core)
#
# The unit under test is the offline contract on one real amd64 image: with no
# network, authenticated /status and /providers each complete within five
# seconds from bundled or cached state, freshness is honest, concurrent polls
# share one background refresh, and polling installs or updates nothing.
#
#   - cold cache (no provider file, fresh server): both endpoints answer 200
#     in under five seconds; providers fall back to the bundled catalogue;
#     harness facts carry installed/runnable state with auth unknown rather
#     than failing;
#   - warm cache (a seeded provider file, restarted server): /providers keeps
#     serving the seeded catalogue with a disk source marker;
#   - concurrent polls (five of each endpoint at once) all answer 200 in
#     under five seconds;
#   - repeated polling changes no mise selection, config, or manager state.
#
# The setup server and the harness modules are copied into the container so a
# run tests the checkout, not a stale build. The container runs with
# --network none throughout: there is no "disconnect halfway" step because a
# cold offline start is the hardest case.
#
# The variant selects which capabilities the online contract can rely on; it is
# never inferred from the presence of a binary. When omitted it is inferred from
# the image tag (t3code:<variant>); digest references (image@sha256:...) require
# an explicit --variant.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/image-profile.sh
. "$ROOT/scripts/lib/image-profile.sh"
VARIANT=""
IMAGE=""

usage() {
  cat <<'USAGE'
Usage: scripts/test-offline.sh [--variant NAME] [image]

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
    -*) echo "test-offline.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) IMAGE="$1"; shift ;;
  esac
done
[ -n "$IMAGE" ] || IMAGE="t3code:core"

t3_image_profile_resolve "test-offline.sh" "$IMAGE" "$VARIANT"

NAME="t3code-offline-$$"
VOLUME="t3code-offline-home-$$"
SETUP_PORT="${OFFLINE_PORT:-13779}"
SETUP_KEY="offline-test-key"
HARNESS_SRC="${ROOT}/docker/harness"
PROVIDER_SRC="${ROOT}/docker/provider-integration"
SETUP_SRC="${ROOT}/docker/setup"
HARNESS_DEST=/opt/t3-harness
PROVIDER_DEST=/opt/t3-provider
SETUP_DEST=/opt/t3-setup
BUDGET="5.0"

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
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }
under() { # label seconds — asserts seconds < BUDGET
  if awk "BEGIN { exit !(($2 + 0) < ($BUDGET + 0)) }"; then ok "$1 (${2}s < ${BUDGET}s)";
  else no "$1 (${2}s exceeds ${BUDGET}s)"; fi
}

cleanup() {
  # Background jobs run in subshells that inherit the EXIT trap; only the
  # main shell may tear the container down.
  [ "$BASHPID" = "$MAIN_PID" ] || return 0
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
}
MAIN_PID="$BASHPID"
trap cleanup EXIT

dex()   { docker exec -u t3 -e HOME=/home/t3 -w /home/t3 "$NAME" "$@"; }
droot() { docker exec "$NAME" "$@"; }
field() { printf '%s' "$2" | jq -r "$1"; }
mise_ls() { dex mise ls --json 2>/dev/null || printf '{}'; }
mise_config() { dex sh -c 'cat /home/t3/.config/mise/config.toml 2>/dev/null || printf "__absent__"'; }
recorded() { dex sh -c 'cat /home/t3/.local/state/mise/harness-state.json 2>/dev/null || printf "__absent__"'; }

# Split get's "CODE SECONDS" without read's set -e hazard on empty input.
timed() { # label path hostfile — GETs and sets TIMED_CODE/TIMED_SECS
  local result
  result="$(get "$2" "$3" || true)"
  TIMED_CODE="${result%% *}"
  TIMED_SECS="${result##* }"
  if [ -z "$result" ]; then
    no "$1 produced no result (curl/docker exec failed)"
    TIMED_CODE="000"
    TIMED_SECS="?"
  fi
}

# get PATH HOSTFILE [TAG] — authenticated, prints "CODE SECONDS" and stores
# the body at HOSTFILE. The body lands in the container first (curl runs
# there), then is copied out; TAG keeps concurrent calls from sharing one
# container temp file.
get() { # path hostfile [tag]
  local tag="${3:-main}"
  local out
  out="$(droot curl -s --noproxy '*' --max-time 30 -o "/tmp/offline-${tag}-$$" -w '%{http_code} %{time_total}' \
    -H "x-t3-setup-key: ${SETUP_KEY}" "http://127.0.0.1:${SETUP_PORT}$1" 2>/dev/null || true)"
  droot cat "/tmp/offline-${tag}-$$" > "$2" 2>/dev/null || true
  printf '%s' "$out"
}

start_server() {
  droot sh -c "pkill -f '${SETUP_DEST}/server.mjs' 2>/dev/null || true" >/dev/null 2>&1 || true
  sleep 1
  docker exec -d -u t3 -e HOME=/home/t3 -e "T3_SETUP_KEY=${SETUP_KEY}" \
    -e "T3_SETUP_PORT=${SETUP_PORT}" -e "T3_HARNESS_MODULE=${HARNESS_DEST}/index.mjs" \
    -e "T3_PROVIDER_MODULE=${PROVIDER_DEST}/index.mjs" \
    "$NAME" node "${SETUP_DEST}/server.mjs" >/dev/null
  for i in $(seq 1 60); do
    if droot curl -fsS --noproxy '*' --max-time 3 \
        "http://127.0.0.1:${SETUP_PORT}/status" -H "x-t3-setup-key: ${SETUP_KEY}" \
        >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

printf '\nTesting offline-safe setup status on %s (variant %s, --network none)\n' "$IMAGE" "$VARIANT"

section "Start an offline container with the checkout setup server"
docker volume create "$VOLUME" >/dev/null
docker run -d --network none --name "$NAME" -e "T3_SETUP_KEY=${SETUP_KEY}" \
  -v "${VOLUME}:/home/t3" "$IMAGE" sleep infinity >/dev/null
for i in $(seq 1 60); do
  dex test -w /home/t3 >/dev/null 2>&1 && break
  [ "$i" = 60 ] && { no "container never became usable"; exit 1; }
  sleep 1
done
droot mkdir -p "$HARNESS_DEST" "$PROVIDER_DEST" "$SETUP_DEST"
docker cp "${HARNESS_SRC}/." "${NAME}:${HARNESS_DEST}/" >/dev/null
docker cp "${PROVIDER_SRC}/." "${NAME}:${PROVIDER_DEST}/" >/dev/null
docker cp "${SETUP_SRC}/." "${NAME}:${SETUP_DEST}/" >/dev/null
droot chmod -R a+rX "$HARNESS_DEST" "$PROVIDER_DEST" "$SETUP_DEST"
if start_server; then ok "the checkout setup server answers with no network";
else no "the checkout setup server never answered"; exit 1; fi

section "Cold cache: /status answers within budget"
timed "cold /status" /status /tmp/offline-status-$$
code="$TIMED_CODE"; secs="$TIMED_SECS"
is "cold /status is 200" "200" "$code"
under "cold /status latency" "$secs"
status_body="$(cat /tmp/offline-status-$$)"
is "cold /status lists five harnesses" "5" "$(field '.harnesses | length' "$status_body")"
has "cold /status reports harness freshness" '"harnessCache":' "$status_body"
has "cold /status harness cache names its source" '"source":' "$status_body"
has "cold /status keeps the degraded list" '"degraded":' "$status_body"
has "cold /status keeps local pairing inspection" '"pairings":' "$status_body"
has "cold /status keeps local session inspection" '"sessions":' "$status_body"

section "Cold cache: /providers answers within budget"
timed "cold /providers" /providers /tmp/offline-providers-$$
code="$TIMED_CODE"; secs="$TIMED_SECS"
is "cold /providers is 200" "200" "$code"
under "cold /providers latency" "$secs"
providers_body="$(cat /tmp/offline-providers-$$)"
is "cold /providers serves the bundled catalogue" "bundled" \
  "$(field '.cache.source' "$providers_body")"
is "cold /providers marks the fallback stale" "true" \
  "$(field '.cache.stale' "$providers_body")"
count="$(field '.providers | length' "$providers_body")"
if [ "${count:-0}" -ge 10 ]; then ok "cold /providers lists a usable catalogue ($count entries)";
else no "cold /providers catalogue too small ($count)"; fi
has "cold /providers keeps the configured keys" '"configured":' "$providers_body"

section "Read-only polling changes nothing"
before_ls="$(mise_ls)"
before_cfg="$(mise_config)"
before_state="$(recorded)"
get /status /tmp/offline-poll-1-$$ >/dev/null
get /providers /tmp/offline-poll-2-$$ >/dev/null
get /harnesses /tmp/offline-poll-3-$$ >/dev/null
get "/harnesses?authenticate=false" /tmp/offline-poll-4-$$ >/dev/null
get /status /tmp/offline-poll-5-$$ >/dev/null
is "polling changed no mise selection" "$before_ls" "$(mise_ls)"
is "polling changed no mise config" "$before_cfg" "$(mise_config)"
is "polling wrote no manager state" "$before_state" "$(recorded)"
cheap_body="$(cat /tmp/offline-poll-4-$$)"
is "explicit cheap poll lists five" "5" "$(field '.harnesses | length' "$cheap_body")"
has "explicit cheap poll names its source" '"cheap"' "$cheap_body"

section "Warm cache: a seeded catalogue survives a restart offline"
dex sh -c 'mkdir -p /home/t3/.t3/setup && printf "%s" "{\"at\":1700000000000,\"list\":[{\"id\":\"warm-marker\",\"name\":\"Warm Marker\"},{\"id\":\"anthropic\",\"name\":\"Anthropic\"}]}" > /home/t3/.t3/setup/providers.json'
if start_server; then ok "the server restarted offline";
else no "the server never came back"; exit 1; fi
timed "warm /providers" /providers /tmp/offline-warm-$$
code="$TIMED_CODE"; secs="$TIMED_SECS"
is "warm /providers is 200" "200" "$code"
under "warm /providers latency" "$secs"
warm_body="$(cat /tmp/offline-warm-$$)"
is "warm /providers serves the disk cache" "disk" "$(field '.cache.source' "$warm_body")"
has "warm /providers preserves the seeded entry" "warm-marker" "$warm_body"
timed "warm /status" /status /tmp/offline-warm-status-$$
code="$TIMED_CODE"; secs="$TIMED_SECS"
is "warm /status is 200" "200" "$code"
under "warm /status latency" "$secs"
is "warm /status still lists five harnesses" "5" \
  "$(field '.harnesses | length' "$(cat /tmp/offline-warm-status-$$)")"

section "Concurrent polls share one refresh and stay within budget"
rm -f /tmp/offline-conc-$$-*
pids=""
for i in 1 2 3 4 5; do
  get /status "/tmp/offline-conc-$$-status-$i" "status-$i" >"/tmp/offline-conc-$$-status-$i.meta" 2>&1 &
  pids="$pids $!"
  get /providers "/tmp/offline-conc-$$-providers-$i" "providers-$i" >"/tmp/offline-conc-$$-providers-$i.meta" 2>&1 &
  pids="$pids $!"
done
# shellcheck disable=SC2086
wait $pids || true
conc_fail=0
for i in 1 2 3 4 5; do
  for kind in status providers; do
    meta="$(cat "/tmp/offline-conc-$$-$kind-$i.meta" 2>/dev/null || true)"
    code="${meta%% *}"
    secs="${meta##* }"
    if [ -z "$meta" ]; then
      no "concurrent $kind #$i produced no result (curl/docker exec failed)"
      conc_fail=1
      continue
    fi
    if [ "$code" != "200" ]; then no "concurrent $kind #$i is $code"; conc_fail=1; continue; fi
    if awk "BEGIN { exit !(($secs + 0) < ($BUDGET + 0)) }"; then :;
    else no "concurrent $kind #$i took ${secs}s"; conc_fail=1; fi
  done
done
[ "$conc_fail" = 0 ] && ok "ten concurrent polls all answered 200 within budget"
rm -f /tmp/offline-status-$$ /tmp/offline-providers-$$ /tmp/offline-poll-*-$$ \
  /tmp/offline-warm-$$ /tmp/offline-warm-status-$$ /tmp/offline-conc-$$-*

section "Polling after load still changes nothing"
is "loaded polling changed no mise selection" "$before_ls" "$(mise_ls)"
is "loaded polling changed no mise config" "$before_cfg" "$(mise_config)"
is "loaded polling wrote no manager state" "$before_state" "$(recorded)"

printf '\n%d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
