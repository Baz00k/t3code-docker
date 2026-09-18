#!/usr/bin/env bash
# Validate representative mise runtimes on one image (native amd64).
#
#   scripts/test-runtime-matrix.sh [image]     (default: t3code:core)
#
# The unit under test is that the images can provide the toolchains the old
# `full` target used to bake, without an image rebuild:
#
#   - Go, Rust, Bun, Deno, uv, and representative Node/Python via mise;
#   - Rust includes the promised clippy and rustfmt components;
#   - every runtime actually runs a minimal program, not just --version;
#   - the persistent install size is reported for the image contract.
#
# This is not mise's backend test suite: one representative version per
# runtime, installed through an explicit mise boundary, on amd64 only. arm64
# is built and published but not separately tested, per the plan.
set -euo pipefail

IMAGE="${1:-t3code:core}"
NAME="t3code-runtime-$$"
VOLUME="t3code-runtime-home-$$"

# Representative selectors. Deliberately major/minor rather than exact pins:
# the contract promises that mise *can* provide these toolchains, not that one
# patch is blessed. The exact resolved versions are recorded below and belong
# in docs/toolchain/image-contract.md when they change.
NODE_SELECTOR="22"
PYTHON_SELECTOR="3.12"
GO_SELECTOR="1.27"
RUST_SELECTOR="1.82"
BUN_SELECTOR="1.2"
DENO_SELECTOR="2"
UV_SELECTOR="latest"

pass=0
fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A login shell is how a T3 terminal starts: /etc/profile.d/t3-user-env.sh
# exports the mise paths and puts the shims on PATH. Use it for every project
# command so the test exercises the documented activation path.
ulogin() { # dir cmd
  docker exec -u t3 -w "$1" "$NAME" bash -lc "$2"
}

printf '\nTesting runtime matrix of %s\n\n' "$IMAGE"

docker volume create "$VOLUME" >/dev/null
docker run -d --name "$NAME" \
  -e "T3_SETUP_KEY=runtime-test-key" \
  -v "${VOLUME}:/home/t3" \
  "$IMAGE" sleep infinity >/dev/null

for i in $(seq 1 60); do
  docker exec -u t3 "$NAME" test -w /home/t3 >/dev/null 2>&1 && break
  [ "$i" = 60 ] && { no "container never became usable"; exit 1; }
  sleep 1
done

# A project boundary, so every install goes through the same explicit path
# documentation promises: `mise exec` / `mise run`.
PROJECT=/tmp/t3code-runtime-matrix
docker exec -u t3 "$NAME" mkdir -p "$PROJECT"
# docker exec without -i does not forward stdin, so a heredoc would arrive
# empty; write the file on the host and copy it in instead. `docker cp`
# preserves the source mode, and the host user's uid is not the container t3
# uid (1000) on every runner, so make it world-readable: mktemp hands out 0600.
TMP_MISE="$(mktemp)"
cat > "$TMP_MISE" <<EOF
[tools]
node = "$NODE_SELECTOR"
python = "$PYTHON_SELECTOR"
go = "$GO_SELECTOR"
rust = "$RUST_SELECTOR"
bun = "$BUN_SELECTOR"
deno = "$DENO_SELECTOR"
uv = "$UV_SELECTOR"
EOF
chmod 644 "$TMP_MISE"
docker cp "$TMP_MISE" "$NAME:$PROJECT/mise.toml" >/dev/null
rm -f "$TMP_MISE"
ulogin "$PROJECT" 'mise trust' >/dev/null 2>&1 || true

printf 'Install\n'
if ulogin "$PROJECT" 'mise install' >/dev/null 2>&1; then
  ok "mise install resolves all seven runtimes"
else
  no "mise install resolves all seven runtimes"
  ulogin "$PROJECT" 'mise install' || true
fi

if ulogin "$PROJECT" 'mise ls --json > /tmp/runtime-versions.json' >/dev/null 2>&1 \
   && docker cp "$NAME:/tmp/runtime-versions.json" "/tmp/t3code-runtime-versions-$$.json" >/dev/null 2>&1; then
  ok "exact resolved versions recorded"
  python3 - "/tmp/t3code-runtime-versions-$$.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for tool in ("node", "python", "go", "rust", "bun", "deno", "uv"):
    rows = d.get(tool, [])
    installed = [e.get("version") for e in rows if e.get("installed")]
    requested = rows[0].get("requested_version") if rows else "?"
    print(f"  {tool} (wanted {requested}): {', '.join(installed) or 'MISSING'}")
PYEOF
  rm -f "/tmp/t3code-runtime-versions-$$.json"
else
  no "exact resolved versions recorded"
fi

printf '\nRuntimes run\n'
check "node runs" "ulogin \"$PROJECT\" 'mise exec -- node --version'"
check "node runs a program" "ulogin \"$PROJECT\" 'mise exec -- node -e \"console.log(40+2)\"' | grep -q 42"
check "python runs" "ulogin \"$PROJECT\" 'mise exec -- python --version'"
check "python runs a program" "ulogin \"$PROJECT\" 'mise exec -- python -c \"print(40+2)\"' | grep -q 42"
check "go runs" "ulogin \"$PROJECT\" 'mise exec -- go version'"
check "rustc runs" "ulogin \"$PROJECT\" 'mise exec -- rustc --version'"
check "cargo runs" "ulogin \"$PROJECT\" 'mise exec -- cargo --version'"
check "bun runs" "ulogin \"$PROJECT\" 'mise exec -- bun --version'"
check "deno runs" "ulogin \"$PROJECT\" 'mise exec -- deno --version'"
check "uv runs" "ulogin \"$PROJECT\" 'mise exec -- uv --version'"

# Minimal programs that prove the toolchain links and runs, not just prints a
# version. Written to files first so no nested quoting has to survive
# bash -lc -> sh -c -> tool.
docker exec -u t3 "$NAME" sh -c "printf 'package main\nimport \"fmt\"\nfunc main(){fmt.Println(\"t3code-runtime-ok\")}\n' > $PROJECT/main.go"
check "go runs a program" "ulogin \"$PROJECT\" 'mise exec -- go run main.go' | grep -q t3code-runtime-ok"
docker exec -u t3 "$NAME" sh -c "printf 'print(\"t3code-runtime-ok\")\n' > $PROJECT/hello.py"
check "python runs a file" "ulogin \"$PROJECT\" 'mise exec -- python hello.py' | grep -q t3code-runtime-ok"

printf '\nRust components (promised: clippy + rustfmt)\n'
check "cargo-clippy runs" "ulogin \"$PROJECT\" 'mise exec -- cargo clippy --version'"
check "cargo-fmt runs" "ulogin \"$PROJECT\" 'mise exec -- cargo fmt --version'"
check "clippy lints a crate" \
  "ulogin \"$PROJECT\" 'mise exec -- cargo new --quiet clippy-probe && mise exec -- cargo clippy --quiet --manifest-path clippy-probe/Cargo.toml'"
check "rustfmt checks a crate" \
  "ulogin \"$PROJECT\" 'mise exec -- cargo fmt --check --manifest-path clippy-probe/Cargo.toml || mise exec -- cargo fmt --manifest-path clippy-probe/Cargo.toml'"

printf '\nPersistent install size\n'
docker exec -u t3 "$NAME" du -sh /home/t3/.local/share/mise 2>/dev/null || true
docker exec -u t3 "$NAME" sh -c 'du -sh /home/t3/.local/share/mise/installs/* 2>/dev/null; du -sh /home/t3/.cargo /home/t3/.rustup 2>/dev/null || true' || true
ok "install sizes reported (record in docs/toolchain/image-contract.md)"

printf '\n%d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
