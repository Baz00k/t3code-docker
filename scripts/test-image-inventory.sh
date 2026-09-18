#!/usr/bin/env bash
# Assert the image target inventory for one variant.
#
#   scripts/test-image-inventory.sh [--variant NAME] [image]
#       (default image: t3code:core)
#
# The unit under test is the package contract in
# docs/toolchain/image-contract.md, not behavior:
#
#   - every target carries base + T3 infra + mise + the harness installer;
#   - core preserves the required non-browser union;
#   - browser adds only Chromium/fonts/MCP on top of core;
#   - neither target contains a baked harness or a baked language runtime.
#
# The variant selects the expected profile; it is never inferred from the
# presence of Chromium. When omitted it is inferred from the image tag;
# digest references require an explicit --variant.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/image-profile.sh
. "$SCRIPT_DIR/lib/image-profile.sh"

VARIANT=""
IMAGE=""

usage() {
  cat <<'USAGE'
Usage: scripts/test-image-inventory.sh [--variant NAME] [image]

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
    -*) echo "test-image-inventory.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) IMAGE="$1"; shift ;;
  esac
done
[ -n "$IMAGE" ] || IMAGE="t3code:core"

t3_image_profile_resolve "test-image-inventory.sh" "$IMAGE" "$VARIANT"

NAME="t3code-inventory-$$"

pass=0
fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }
is() { # label expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected [$2], got [$3])"; fi
}

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

dex() { docker exec "$NAME" "$@"; }
droot() { docker exec "$NAME" "$@"; }

printf '\nTesting image inventory of %s (variant %s)\n\n' "$IMAGE" "$VARIANT"

docker run -d --name "$NAME" "$IMAGE" sleep infinity >/dev/null
for i in $(seq 1 30); do
  docker exec "$NAME" true >/dev/null 2>&1 && break
  [ "$i" = 30 ] && { no "container never started"; exit 1; }
  sleep 1
done

printf 'Image stamp\n'
is "T3_IMAGE_VARIANT names the tested variant" \
  "$VARIANT" "$(droot printenv T3_IMAGE_VARIANT 2>/dev/null || true)"
check "T3_IMAGE_VERSION is stamped" \
  "droot sh -c 'test -n \"\$T3_IMAGE_VERSION\"'"

printf '\nBase + infrastructure (all variants)\n'
check "image Node exists" "droot test -x /usr/local/bin/node"
check "immutable T3 platform binary exists" "droot test -x /opt/t3/t3"
check "T3 client shell exists beside the binary" "droot test -f /opt/t3/client/index.html"
check "t3 launcher exists" "droot test -x /usr/local/bin/t3-admin"
check "entrypoint exists" "droot test -x /usr/local/bin/entrypoint.sh"
check "setup service ships" "droot test -f /opt/t3-setup/server.mjs"
check "harness manager ships" "droot test -f /opt/t3-harness/manager.mjs"
check "provider integration ships" "droot test -f /opt/t3-provider/cli.mjs"
check "t3-harness CLI ships" "droot sh -c 'command -v t3-harness'"
check "t3-browser-mcp helper ships" "droot sh -c 'command -v t3-browser-mcp'"
check "mise ships" "droot sh -c 'command -v mise'"
check "system mise config ships" "droot test -f /etc/mise/config.toml"
for bin in git python3 gh cloudflared; do
  check "$bin present (base)" "droot sh -c 'command -v $bin'"
done

printf '\nNon-browser OS union (core/browser)\n'
# The union is the old full apt set minus Chromium/fonts. Checked via dpkg (the
# authoritative record) and via the user-visible binary where one exists.
nonbrowser_pkgs="clang lld cmake pkg-config gdb ffmpeg imagemagick postgresql-client redis-tools"
for pkg in $nonbrowser_pkgs; do
  check "dpkg $pkg installed" "droot sh -c 'dpkg -l $pkg 2>/dev/null | grep -q \"^ii\"'"
done
for bin in clang cmake ffmpeg psql gdb; do
  check "$bin present (union)" "droot sh -c 'command -v $bin'"
done
check "redis-cli present (union)" "droot sh -c 'command -v redis-cli'"

printf '\nBaked harnesses (none in any target)\n'
for bin in /opt/npm-global/bin/claude /opt/npm-global/bin/codex \
           /opt/npm-global/bin/opencode /opt/npm-global/bin/grok \
           /opt/cursor/.local/bin/cursor-agent; do
  check "no baked $bin" "! droot test -e $bin"
done
for bin in claude codex opencode grok cursor-agent; do
  check "no $bin on root PATH" "! droot sh -c 'command -v $bin'"
done

printf '\nBaked language runtimes (none in any target)\n'
check "no baked Go" "! droot test -e /usr/local/go/bin/go"
check "no baked Rust" "! droot test -e /usr/local/cargo/bin/rustc"
check "no baked Bun" "! droot test -e /usr/local/bun/bin/bun"
check "no baked Deno" "! droot test -e /usr/local/deno/bin/deno"
check "no baked uv" "! droot test -e /usr/local/bin/uv"

printf '\nBrowser capability (browser only)\n'
if [ "$HAS_BROWSER" -eq 1 ]; then
  check "dpkg chromium installed" "droot sh -c 'dpkg -l chromium 2>/dev/null | grep -q \"^ii\"'"
  check "chromium present" "droot sh -c 'command -v chromium'"
  for pkg in fonts-liberation fonts-dejavu-core fonts-noto-core fonts-noto-color-emoji fonts-noto-cjk; do
    check "dpkg $pkg installed" "droot sh -c 'dpkg -l $pkg 2>/dev/null | grep -q \"^ii\"'"
  done
  check "playwright-mcp present" "droot sh -c 'command -v playwright-mcp'"
  check "chrome-devtools-mcp present" "droot sh -c 'command -v chrome-devtools-mcp'"
  check "CHROME_PATH points at chromium" "droot sh -c 'test -x \"\$CHROME_PATH\"'"
else
  check "no chromium" "! droot sh -c 'command -v chromium'"
  check "dpkg chromium absent" "! droot sh -c 'dpkg -l chromium 2>/dev/null | grep -q \"^ii\"'"
  check "no playwright-mcp" "! droot sh -c 'command -v playwright-mcp'"
  check "no chrome-devtools-mcp" "! droot sh -c 'command -v chrome-devtools-mcp'"
fi

printf '\n%d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
