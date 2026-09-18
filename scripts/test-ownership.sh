#!/usr/bin/env bash
# Assert the persistent-ownership contract on one image.
#
#   scripts/test-ownership.sh [image]     (default: t3code:core)
#
# The unit under test is ownership migration and persistence diagnostics, not
# the server:
#
#   - a fresh home volume is already owned correctly and is never traversed;
#   - a root-owned tree is adopted recursively, and the migration intent is
#     recorded before the account or the tree is touched;
#   - an interrupted migration (a read-only mount makes chown fail) stays
#     pending and is retried to completion on the next start, with unchanged
#     ids and with a uid/gid remap;
#   - a direct state mount and an external T3CODE_HOME are adopted;
#   - workspace adoption stays non-recursive;
#   - t3-doctor reports the mise paths, active config, installed tools and the
#     observed mounts, distinguishes observed from guaranteed persistence,
#     names a state-only mount as insufficient for tools, and creates no
#     root-owned state.
#
# Every volume and temporary directory is created and removed by this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-t3code:core}"
PREFIX="t3ow-$$"
MISE_VERSION="$(grep -m1 '^ARG MISE_VERSION=' "$ROOT/Dockerfile" | cut -d= -f2)"

pass=0
fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }
is() { # label expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected [$2], got [$3])"; fi
}
has() { # label needle haystack
  if printf '%s' "$3" | grep -Fq -- "$2"; then ok "$1"; else no "$1 (missing [$2])"; fi
}
hasnt() { # label needle haystack
  if printf '%s' "$3" | grep -Fq -- "$2"; then no "$1 (unexpected [$2])"; else ok "$1"; fi
}
matches() { # label regex haystack
  if printf '%s' "$3" | grep -Eq -- "$2"; then ok "$1"; else no "$1 (no match for /$2/)"; fi
}

CONTAINERS=()
VOLUMES=()
TMP_DIRS=()
cleanup() {
  local c v d
  for c in "${CONTAINERS[@]:-}"; do [ -n "$c" ] && docker rm -f "$c" >/dev/null 2>&1 || true; done
  for v in "${VOLUMES[@]:-}"; do [ -n "$v" ] && docker volume rm "$v" >/dev/null 2>&1 || true; done
  for d in "${TMP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null || true; done
}
trap cleanup EXIT

new_vol() { docker volume create "$1" >/dev/null; VOLUMES+=("$1"); }
# Run an arbitrary script inside a volume without the entrypoint, so a tree can
# be seeded root-owned (or foreign-owned) the way an inherited volume arrives.
volsh() { # volume mount-point script
  docker run --rm --entrypoint sh -v "$1:$2" "$IMAGE" -c "$3"
}
# Boot the image with the migration-only half doing the work; the command after
# the entrypoint is irrelevant, only that it reaches the unprivileged step.
run_bg() { # name docker-args...
  local name="$1"; shift
  CONTAINERS+=("$name")
  docker run -d --name "$name" "$@" "$IMAGE" sleep infinity >/dev/null
}
wait_exec() {
  local c="$1"
  for _ in $(seq 1 40); do docker exec "$c" true >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}
wait_marker_gone() { # container [marker]
  local c="$1" m="${2:-/home/t3/.t3/.ownership-migration}"
  for _ in $(seq 1 40); do docker exec "$c" test ! -e "$m" >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}
logs_of()   { docker logs "$1" 2>&1 || true; }
own()       { docker exec "$1" stat -c '%u:%g' "$2" 2>/dev/null || true; }
line_of()   { printf '%s\n' "$2" | grep -n -- "$1" | head -1 | cut -d: -f1; }
# The doctor colours its labels; strip the escapes so assertions read plainly.
doctor()    { docker exec "$1" t3-doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true; }

printf '\nTesting the ownership and persistence contract of %s\n\n' "$IMAGE"

# --- fresh home --------------------------------------------------------------
printf 'Fresh home\n'
new_vol "${PREFIX}-home"
run_bg "${PREFIX}-fresh" -v "${PREFIX}-home:/home/t3"
wait_exec "${PREFIX}-fresh" || no "the fresh container started"
uidgid="$(docker exec "${PREFIX}-fresh" sh -c 'printf "%s:%s" "$(id -u t3)" "$(id -g t3)"')"
fresh_logs="$(logs_of "${PREFIX}-fresh")"
hasnt "a fresh home volume is not traversed" "taking ownership" "$fresh_logs"
check "no migration marker is left behind" \
  "docker exec ${PREFIX}-fresh test ! -e /home/t3/.t3/.ownership-migration"
is "the fresh home is owned by ${uidgid}" "$uidgid" "$(own "${PREFIX}-fresh" /home/t3)"
check "the unprivileged user can write the fresh home" \
  "docker exec -u t3 ${PREFIX}-fresh test -w /home/t3"

# A recreate on the same volume is the steady state: nothing should be walked.
docker rm -f "${PREFIX}-fresh" >/dev/null 2>&1
run_bg "${PREFIX}-recreate" -v "${PREFIX}-home:/home/t3"
wait_exec "${PREFIX}-recreate" || no "the recreated container started"
hasnt "a recreate on the same volume is not traversed" \
  "taking ownership" "$(logs_of "${PREFIX}-recreate")"
check "no marker after the recreate" \
  "docker exec ${PREFIX}-recreate test ! -e /home/t3/.t3/.ownership-migration"

# --- root-owned home adoption ------------------------------------------------
printf '\nRoot-owned home adoption\n'
new_vol "${PREFIX}-rooty"
volsh "${PREFIX}-rooty" /home/t3 '
  mkdir -p /home/t3/.local/share/mise/installs/node/24.0.0/bin /home/t3/.t3/userdata /home/t3/.config/mise
  chown -R 0:0 /home/t3'
run_bg "${PREFIX}-adopt" -v "${PREFIX}-rooty:/home/t3"
wait_marker_gone "${PREFIX}-adopt" || no "the root-owned home finished migrating"
adopt_logs="$(logs_of "${PREFIX}-adopt")"
has "records the migration intent" "recorded ownership migration intent" "$adopt_logs"
has "traverses the home" "taking ownership of /home/t3" "$adopt_logs"
has "reports the migration complete" "ownership migration complete" "$adopt_logs"
check "the marker is cleared" \
  "docker exec ${PREFIX}-adopt test ! -e /home/t3/.t3/.ownership-migration"
intent_line="$(line_of 'recorded ownership migration intent' "$adopt_logs")"
chown_line="$(line_of 'taking ownership of /home/t3' "$adopt_logs")"
check "intent is recorded before the traversal" \
  "[ ${intent_line:-0} -gt 0 ] && [ ${intent_line:-0} -lt ${chown_line:-0} ]"
for path in /home/t3 /home/t3/.t3 /home/t3/.config/mise \
            /home/t3/.local/share/mise/installs/node/24.0.0/bin /home/t3/.t3/userdata; do
  is "adopted ${path}" "$uidgid" "$(own "${PREFIX}-adopt" "$path")"
done

# --- interrupted migration ---------------------------------------------------
printf '\nInterrupted migration\n'
new_vol "${PREFIX}-interrupted"
volsh "${PREFIX}-interrupted" /home/t3 '
  mkdir -p /home/t3/.t3/userdata /home/t3/.local/share/mise/installs/node/24.0.0/bin
  chown -R 0:0 /home/t3'
# A read-only mount under the home makes the recursive chown fail partway. The
# entrypoint must abort with the marker still on the state volume.
RO_DIR="$(mktemp -d)"; TMP_DIRS+=("$RO_DIR")
printf 'keep\n' > "$RO_DIR/keep"
CONTAINERS+=("${PREFIX}-interrupt")
docker run -d --name "${PREFIX}-interrupt" \
  -v "${PREFIX}-interrupted:/home/t3" \
  -v "${RO_DIR}:/home/t3/.local/share/mise:ro" \
  "$IMAGE" sleep infinity >/dev/null
for _ in $(seq 1 40); do
  [ "$(docker inspect -f '{{.State.Running}}' "${PREFIX}-interrupt" 2>/dev/null)" = false ] && break
  sleep 1
done
interrupt_ec="$(docker inspect -f '{{.State.ExitCode}}' "${PREFIX}-interrupt" 2>/dev/null || echo 0)"
if [ "${interrupt_ec:-0}" -ne 0 ]; then
  ok "an interrupted migration exits non-zero (${interrupt_ec})"
else
  no "an interrupted migration should not report success"
fi
interrupt_logs="$(logs_of "${PREFIX}-interrupt")"
has "the intent survives the interruption" "recorded ownership migration intent" "$interrupt_logs"
hasnt "an interrupted migration is not reported complete" \
  "ownership migration complete" "$interrupt_logs"
marker_dump="$(volsh "${PREFIX}-interrupted" /home/t3 \
  'cat /home/t3/.t3/.ownership-migration 2>/dev/null')"
has "the pending marker records the format version" "version=1" "$marker_dump"
has "the pending marker records the target uid" "target_uid=${uidgid%%:*}" "$marker_dump"
has "the pending marker records the target gid" "target_gid=${uidgid##*:}" "$marker_dump"
matches "the pending marker records when it started" '^started=[0-9]{4}-' "$marker_dump"

docker rm -f "${PREFIX}-interrupt" >/dev/null 2>&1
run_bg "${PREFIX}-retry" -v "${PREFIX}-interrupted:/home/t3"
wait_marker_gone "${PREFIX}-retry" || no "the retry finished migrating"
retry_logs="$(logs_of "${PREFIX}-retry")"
has "the retry reports it is resuming" "resuming an interrupted ownership migration" "$retry_logs"
has "the retry completes the migration" "ownership migration complete" "$retry_logs"
check "the marker is cleared after the retry" \
  "docker exec ${PREFIX}-retry test ! -e /home/t3/.t3/.ownership-migration"
is "the previously blocked directory is adopted" "$uidgid" \
  "$(own "${PREFIX}-retry" /home/t3/.local/share/mise)"
is "a deep seeded directory is adopted" "$uidgid" \
  "$(own "${PREFIX}-retry" /home/t3/.local/share/mise/installs/node/24.0.0/bin)"

# --- uid/gid remap -----------------------------------------------------------
printf '\nUID/GID remap\n'
new_vol "${PREFIX}-remap"
run_bg "${PREFIX}-remap" -e PUID=1234 -e PGID=1234 -v "${PREFIX}-remap:/home/t3"
wait_marker_gone "${PREFIX}-remap" || no "the remapped account finished migrating"
remap_logs="$(logs_of "${PREFIX}-remap")"
remap_intent="$(line_of 'recorded ownership migration intent' "$remap_logs")"
remap_user="$(line_of 'remapping user' "$remap_logs")"
check "the marker is written before the account is changed" \
  "[ ${remap_intent:-0} -gt 0 ] && [ ${remap_intent:-0} -lt ${remap_user:-0} ]"
is "the account carries the requested uid" "1234" \
  "$(docker exec "${PREFIX}-remap" id -u t3)"
is "the home is owned by the requested uid:gid" "1234:1234" \
  "$(own "${PREFIX}-remap" /home/t3)"
check "the remap leaves no pending marker" \
  "docker exec ${PREFIX}-remap test ! -e /home/t3/.t3/.ownership-migration"

# --- direct state mount ------------------------------------------------------
printf '\nDirect state mount\n'
new_vol "${PREFIX}-state"
volsh "${PREFIX}-state" /home/t3/.t3 'mkdir -p /home/t3/.t3/userdata; chown -R 0:0 /home/t3/.t3'
run_bg "${PREFIX}-state" -v "${PREFIX}-state:/home/t3/.t3"
wait_marker_gone "${PREFIX}-state" "/home/t3/.t3/.ownership-migration" \
  || no "the root-owned state mount finished migrating"
has "the direct state mount is adopted" "taking ownership of /home/t3/.t3" \
  "$(logs_of "${PREFIX}-state")"
is "the direct state mount is owned by ${uidgid}" "$uidgid" "$(own "${PREFIX}-state" /home/t3/.t3)"
state_doctor="$(doctor "${PREFIX}-state")"
has "doctor calls the state mount durable" "named volume" "$state_doctor"
has "doctor warns that tools need the whole home" "durable tools" "$state_doctor"
has "doctor names the anonymous tools volume" "anonymous volume" "$state_doctor"

# --- external state dir ------------------------------------------------------
printf '\nExternal T3CODE_HOME\n'
new_vol "${PREFIX}-ext"
volsh "${PREFIX}-ext" /data/t3 'mkdir -p /data/t3/userdata; chown -R 0:0 /data/t3'
run_bg "${PREFIX}-ext" -e T3CODE_HOME=/data/t3 -v "${PREFIX}-ext:/data/t3"
wait_marker_gone "${PREFIX}-ext" "/data/t3/.ownership-migration" \
  || no "the external state dir finished migrating"
has "the external state dir is adopted" "taking ownership of /data/t3" \
  "$(logs_of "${PREFIX}-ext")"
is "the external state dir is owned by ${uidgid}" "$uidgid" "$(own "${PREFIX}-ext" /data/t3)"
check "the external marker is cleared" \
  "docker exec ${PREFIX}-ext test ! -e /data/t3/.ownership-migration"
has "doctor follows the external state dir" "/data/t3" "$(doctor "${PREFIX}-ext")"

# --- workspace adoption ------------------------------------------------------
printf '\nWorkspace adoption\n'
new_vol "${PREFIX}-ws"
volsh "${PREFIX}-ws" /workspace '
  mkdir -p /workspace/repo/.git
  printf "keep\n" > /workspace/repo/rootfile
  printf "other\n" > /workspace/repo/otherfile
  chown -R 0:0 /workspace
  chown 4321:4321 /workspace/repo/otherfile'
run_bg "${PREFIX}-ws" -v "${PREFIX}-ws:/workspace"
wait_exec "${PREFIX}-ws" || no "the workspace container started"
is "the workspace root is adopted" "$uidgid" "$(own "${PREFIX}-ws" /workspace)"
is "a nested root-owned file is left alone" "0:0" \
  "$(own "${PREFIX}-ws" /workspace/repo/rootfile)"
is "a nested foreign-owned file is left alone" "4321:4321" \
  "$(own "${PREFIX}-ws" /workspace/repo/otherfile)"

# --- diagnostics -------------------------------------------------------------
printf '\nDiagnostics\n'
new_vol "${PREFIX}-diag"
run_bg "${PREFIX}-diag" -v "${PREFIX}-diag:/home/t3"
wait_exec "${PREFIX}-diag" || no "the diagnostics container started"
# Seed a fake installed tool so the report has something to list without a
# network call; mise records installation by the install path plus the config.
docker exec -u t3 "${PREFIX}-diag" sh -c '
  set -e
  mkdir -p /home/t3/.local/share/mise/installs/jq/9.9.9/bin /home/t3/.config/mise
  printf "#!/bin/sh\necho jq-9.9.9\n" > /home/t3/.local/share/mise/installs/jq/9.9.9/bin/jq
  chmod 0755 /home/t3/.local/share/mise/installs/jq/9.9.9/bin/jq
  printf "[tools]\njq = \"9.9.9\"\n" > /home/t3/.config/mise/config.toml' >/dev/null
diag="$(doctor "${PREFIX}-diag")"
has "doctor reports the pinned mise release" "$MISE_VERSION" "$diag"
has "doctor reports the persistent data dir" "/home/t3/.local/share/mise" "$diag"
has "doctor reports the active user config" "/home/t3/.config/mise/config.toml" "$diag"
has "doctor lists the installed tool" "jq 9.9.9" "$diag"
has "doctor reports the effective policy" "not_found_system_fallback=false" "$diag"
has "doctor reports the observed mounts" "Persistence (observed now)" "$diag"
has "doctor distinguishes observed from guaranteed" "Observed at this start only" "$diag"
matches "doctor reports a healthy migration" 'migration[[:space:]]+complete' "$diag"
hasnt "a durable home is not flagged as insufficient" "durable tools" "$diag"
check "diagnostics leave no root-owned files under the home" \
  "[ -z \"\$(docker exec ${PREFIX}-diag find /home/t3 -user root -print -quit 2>/dev/null)\" ]"
check "diagnostics create no root-owned mise state" \
  "[ -z \"\$(docker exec ${PREFIX}-diag find /home/t3/.config/mise /home/t3/.local /home/t3/.cache -user root -print -quit 2>/dev/null)\" ]"

printf '\n%d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
