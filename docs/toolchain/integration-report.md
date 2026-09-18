# Transitional Product Integration Report

> **Historical record (TM-12).** This report verified the transitional product
> before the atomic switch. The transitional `slim`/`full` targets it refers to
> were removed by TM-13; see [`migration.md`](./migration.md) for the current
> product and [`image-contract.md`](./image-contract.md) for the final target
> contract.

TM-12 deliverable. The assembled transition product is verified end to end
before the atomic switch is authorized: a fresh final image installs and
launches every supported harness through T3, exact versions and credentials
survive recreation (including offline), project toolchains work while T3 and
setup stay on the image Node, the browser variant registers MCP through managed
harnesses and drives real pages, and Uninstall leaves no baked claim behind.

The canonical product contract is
[`TOOLCHAIN-MANAGEMENT-PLAN.md`](../../TOOLCHAIN-MANAGEMENT-PLAN.md). The
verification script ships with this report
([`scripts/test-toolchain-e2e.sh`](../../scripts/test-toolchain-e2e.sh)); the
candidate matrix that runs it is described in
[`ci-evidence.md`](./ci-evidence.md).

## Verdict

Ready for the atomic switch (TM-13). The native rehearsal at `208808a8f607526fc1c1fb0111d43822238cfd52`
(run [35299926144](https://github.com/Baz00k/t3code-docker/actions/runs/35299926144)) built all four targets for amd64 and arm64,
passed every capability check on native amd64, and passed the TM-12 E2E on both
final targets against their tested digests. No blocker is open for this ticket;
the one carried risk (T3 0.0.42, TM-16) blocks the release path, not this
verification (see [Blockers](#blockers)).

## Method

`scripts/test-toolchain-e2e.sh --variant core|browser <image>` is the E2E
harness. The candidate workflow runs it in the same native amd64 test job that
produces the `candidate-tested-<target>.json` artifact, against the exact
platform digest the other capability checks used; the tested artifact is
written only after every step (E2E included) passed. The same job therefore
covers both the exact artifact and the assembled product.

Each run:

1. starts a fresh final image on a fresh home volume and an empty project
   volume, and asserts the installer lists five harnesses and no baked
   fallback exists;
2. installs all five harnesses through `t3-harness` (mise's latest, resolved
   and recorded exactly), checks each executable runs, and records the
   version, path and SHA-256;
3. installs a project Node through mise and proves `mise exec` and a login
   shell select it while T3 and setup still run on the image Node;
4. writes realistic credential fixtures, asserts every credential surface is
   reported and the file-backed OpenCode sign-in reads as signed in, and never
   infers auth from a launch;
5. enables all five T3 providers, recreates the container, waits for T3's
   cached provider snapshots, and asserts per harness that the managed version
   was launched, that the mise path resolves manual-only, and that T3 never
   offers an update command for it;
6. polls the CLI and setup surfaces repeatedly and asserts mise selection,
   mise config, manager state and the four non-Cursor executables are
   byte-identical to the pre-launch capture (Cursor is recorded as drift);
7. on `browser`, registers both MCP servers through the managed Claude, Codex
   and OpenCode and drives a real page through each server;
8. uninstalls one harness, asserts the managed path is retracted from T3
   settings, the executable is removed, credentials survive, and no baked
   fallback is claimed;
9. recreates online, asserts T3 drops the uninstalled provider and everything
   else survives at its exact version, then recreates with `--network none`
   and asserts the same state, the project Node selection, the credentialed
   surfaces, and healthy T3 and setup on the image Node.

Versions default to mise's latest so a run reflects a fresh install; the
report records the resolved exact versions. The script exits non-zero on any
failure and prints a `T3C_E2E_RESULT` JSON line for the evidence.

Local dry runs at `208808a` (native amd64, images built from the same tree)
passed 147 checks on `core` and 156 on `browser`; the native candidate
rehearsal is the authoritative evidence.

## Managed harnesses on a fresh final image

The rehearsal resolved the same exact versions the transitional images pin, on
both final targets (`sha256:0124a626ada3623f2c2bf13ae476fcce6ec6d4e705b800af061931e539ef558a`,
`sha256:8cfb76332cef6af8bfcd253c2a73da806f6aa395faf8b4e1cefd4ff5f496b678`):

| Harness | Resolved version | Managed executable | T3 cached snapshot | T3 updater verdict |
| --- | --- | --- | --- | --- |
| Claude Code | `2.1.274` | `<MISE_DATA_DIR>/installs/claude/2.1.274/claude` | installed, ready, version `2.1.274` | manual-only (`updateCommand: null`, `canUpdate: false`) |
| Codex | `0.154.0` | `<MISE_DATA_DIR>/installs/codex/0.154.0/bin/codex` | installed, ready, version `0.154.0` | manual-only; advisory reports `behind_latest` 0.155.0 with no update command |
| OpenCode | `1.18.31` | `<MISE_DATA_DIR>/installs/opencode/1.18.31/opencode` | installed, version `1.18.31` | manual-only |
| Grok | `1.0.34` | `<MISE_DATA_DIR>/installs/grok/1.0.34/grok` | installed, version `1.0.34` | manual-only |
| Cursor | `2026.09.15-d2fe57e` | `<MISE_DATA_DIR>/installs/cursor-agent/2026.09.15-d2fe57e/dist-package/cursor-agent` | installed, version `2026.09.15-d2fe57e` | self-updating, deliberately not gated; no drift observed |

`MISE_DATA_DIR` is `/home/t3/.local/share/mise`. The T3 snapshots are the
running server's own cached probe results, not a status field copied from the
manager: Claude's is the SDK init path, Codex's the `app-server` initialize,
OpenCode's `serve`, Grok's CLI probe, and Cursor's `acp` discovery. The four
mise-owned paths resolve manual-only, so T3 offers no `npm`/`brew`/self update
that could fight mise; Codex's informational `behind_latest` advisory has no
command attached.

Probe notes from the run:

- The unauthenticated Grok and Cursor snapshots legitimately report `error`
  auth states ("not logged in" / "not authenticated"); their `installed` and
  version fields are still the managed ones, and credentialed completion is a
  separate check (below).
- A malformed empty `{}` Codex `auth.json` makes T3's `codex app-server` probe
  fail before it can report a version ("plan type is required for chatgpt
  authentication"). The E2E writes a realistic API-key file, and Codex then
  reports `ready` with its exact managed version. This is a fixture-shape
  finding, recorded for other authors; no repository code changed.

## Persistence, recreation, and offline

Evidence, from the same E2E runs:

- **Invocation and polling do not update.** After T3 probed all five managed
  executables and the script polled `t3-harness list`, `/status`, and
  `/harnesses?authenticate=false` repeatedly, `mise ls --json`, the mise
  config, the manager state, and the SHA-256 of the Claude, Codex, OpenCode
  and Grok executables were byte-identical to the pre-probe capture. No tool
  moved.
- **Exact versions survive recreation.** The container was recreated (fresh
  container, same named home volume) and later recreated again with
  `--network none`. Both times every installed harness reported
  `installed: true`, `runnable: true` at its exact recorded version, with the
  same executable bytes (outside Cursor, which is allowed to drift) and the
  same mise selection and config.
- **Credentials survive.** All five credential surfaces were reported present
  after installs, after Uninstall of OpenCode, and after both recreations; the
  OpenCode file-backed sign-in read as `signedIn: true` via the setup API.
- **Offline works.** T3 and setup became healthy with no network, and the
  project Node still resolved and ran offline.

The per-check pass/fail and resolved versions are in the `core` and `browser`
native test jobs (run [35299926144](https://github.com/Baz00k/t3code-docker/actions/runs/35299926144)); the local dry runs printed
the same state transitions with 147/0 and 156/0.

## Project toolchain vs image infrastructure

The project volume held a `mise.toml` selecting Node `22`; the image Node is
`v24.21.0`. Both `mise exec -- node --version` and a bare `node` in a login
shell returned `v22.23.2`. At the same time:

- the running T3 server process was `/usr/local/bin/node` with the immutable
  bundle (`/opt/t3/lib/node_modules/t3/dist/bin.mjs`) in its command line,
  under a shadowing-capable project environment;
- the setup service process was `/usr/local/bin/node` running
  `/opt/t3-setup/server.mjs`;
- both held after the online recreate and after the offline recreate.

This is the documented boundary: project tools select through mise, while T3
and setup never leave image infrastructure.

## Browser integration

On `browser`, after installing all five harnesses, `t3-browser-mcp` registered
both MCP servers through the managed executables:

- Claude registered via
  `/home/t3/.local/share/mise/installs/claude/2.1.274/claude`;
- Codex via `.../installs/codex/0.154.0/bin/codex`;
- OpenCode via `.../installs/opencode/1.18.31/opencode`;
- `~/.claude.json`, `${CODEX_HOME:-~/.codex}/config.toml`, and
  `~/.config/opencode/opencode.json` all recorded the server.

Real pages were driven, not just binaries checked: `browser-probe.py` reached a
served page through both `playwright-mcp` (`browser_navigate`, 26 tools,
Playwright 1.64.0-alpha-2026-09-14) and `chrome-devtools-mcp` (`new_page`, 29
tools, chrome_devtools 1.9.0). The same probes run in the transitional smoke
test on `full`/`browser` in the rehearsed artifacts.

## Transition matrix

Rehearsal: run [35299926144](https://github.com/Baz00k/t3code-docker/actions/runs/35299926144) at
`208808a8f607526fc1c1fb0111d43822238cfd52`, `targets="slim full core browser"`,
`run_e2e=true`.

| Target | Native amd64 checks (evidence artifact) | TM-12 E2E | Result | amd64 tested digest | arm64 built digest | Candidate manifest digest |
| --- | --- | --- | --- | --- | --- | --- |
| `slim` | infrastructure, mise, ownership, harness, offline, inventory, smoke, measure | not run (transitional) | pass | `sha256:d7ed66213ce0705aa8344d8eddc1662d6abc7f39905677dd3853e2f94d31494f` | `sha256:a85e6d809cce92b0e1a10c92431efd79ef0359f6f1d7f10723bf787587f89596` | `sha256:753d568afb92b91131dfe94def6a81507c05b76285473d454d8230b8f7172211` |
| `full` | infrastructure, mise, ownership, harness, offline, inventory, smoke, measure | not run (transitional) | pass | `sha256:268d10a75649a0298967eec8b86787591093fd908268f1af23e672133a54fc3d` | `sha256:045efa74e3ba19e0d1f214d597f4944f876b422bf968943612de1e4dd2f18a30` | `sha256:d12e57949289bf319c95f2154a1c6cb3b7c822037863b0617dd18a22ea8fa3e9` |
| `core` | infrastructure, mise, ownership, offline, runtime, inventory, smoke, measure | **147 passed, 0 failed** | pass | `sha256:0124a626ada3623f2c2bf13ae476fcce6ec6d4e705b800af061931e539ef558a` | `sha256:2e8b7cd1a8b4f23f34da1093fa5d2b8ee88fa4bdaeaf5349fb8c534b88628954` | `sha256:555099914fcb24b3330cbe816c928b1bc03074768ff1daa3bcb24fd3f3685747` |
| `browser` | infrastructure, mise, ownership, offline, runtime, inventory, smoke, measure | **156 passed, 0 failed** | pass | `sha256:8cfb76332cef6af8bfcd253c2a73da806f6aa395faf8b4e1cefd4ff5f496b678` | `sha256:d77316bbed59de46b77b88b76609b6d42404a3ae3d5b5a52ad45db2c636cd615` | `sha256:4d3581a9523a0cebcc661665651cfb7685454e09bebbcc5f63b350c5bc9f42ba` |

Measured on the same artifacts (startup is the first healthy response):
`slim` 3.58 s, `full` 3.65 s, `core` 3.41 s, `browser` 3.40 s. All four tested
evidence records are `tested: true` with `pinFreshness: "waived"`.

The transitional `slim` and `full` targets passed their existing full smoke test
(`smoke-test.sh --variant <v>` against the exact amd64 digest) on the same run,
which covers their baked-harness sign-in and browser flows; the final targets
have no baked harness, so their harness lifecycle is covered by the E2E
instead. Measurement and promotion ran for all four targets; the promoted
members are the exact digests the checks used, verified in-run by
`scripts/verify-promoted-manifest.sh`.

### Evidence reconciliation

Two gaps in the capability matrix were found while reconciling the interfaces;
both are returned to their owners below rather than silently changed here:

- `scripts/test-provider-integration.sh` (TM-07) is documented as verification
  but no workflow runs it. For the final targets, the TM-12 E2E covers the
  managed-provider seam more strongly; for `slim`/`full`, the baked-harness
  path is covered by smoke, but the managed-install-into-running-server path
  is not exercised in CI.
- The `candidate-tested-<target>.json` `checks` array names capability checks
  but not the E2E step. The E2E step still gates the artifact (a failure
  prevents `tested-<target>.json`), so the tested digest is the one E2E
  exercised; naming it would make the artifact self-describing.

## Credentialed checks versus executable-launch checks

The two are deliberately separate and reported separately:

| Check | Status | Evidence |
| --- | --- | --- |
| Executable launch through T3 (all five) | Passed | T3 cached snapshots: `installed: true`, managed version, Claude/Codex `ready`, manual-only updater verdicts; executables also run directly. |
| Credential surfaces reported and preserved | Passed | Manager facts marked all five surfaces present; Uninstall and both recreations preserved the OpenCode file-backed credential; `signedIn: true` read through the setup API. |
| Auth is not inferred from a launch | Passed | A failed Claude sign-in never read as signed in while the harness was installed; Grok/Cursor snapshots report unauthenticated. |
| Credentialed completion (real provider sign-in and an agent turn) | **Not run** | No provider accounts are available to this effort; first-party device/OAuth flows need a human and a provider account. Nothing in this report claims a completed credentialed session. |

The suite therefore proves launches, not conversations: a missing credential
stays visible as an auth state and is never read as a launch failure.

## Cursor drift

Cursor's CLI is its own updater, and the product decision is to accept that: a
managed Cursor may move past the exact version the manager recorded, and the
recorded version is advisory, not a lock. The E2E records this as observed
drift rather than failure: it compares the pre-invocation and post-invocation
executable bytes, reports the executable's own `--version`, and never gates on
Cursor matching its recorded version.

No drift was observed in the rehearsed run: the managed Cursor stayed
`2026.09.15-d2fe57e` across T3's ACP discovery, both recreations, and the
offline run, and T3 kept launching it. A run that does observe drift will
report it in the `T3C_E2E_RESULT` line (`cursorDrift: true`) while keeping the
run green; only Cursor is exempt from the byte-identity and exact-version
assertions.

## Corrections returned to owners

1. **TM-11 (candidate matrix):** add `e2e` to the `core`/`browser` capability
   strings so `candidate-tested-<target>.json` names the E2E step that gated it,
   or fold the E2E into a named check. Non-blocking.
2. **TM-07/TM-11 (provider integration in CI):** wire
   `scripts/test-provider-integration.sh` into the matrix. `full` can pass
   itself as the browser image; `slim` needs a small `--no-browser` mode (the
   script otherwise requires `playwright-mcp`, which `slim` does not ship).
   Non-blocking.
3. **Harness fixture guidance:** an empty `{}` Codex `auth.json` breaks T3's
   Codex probe before it can report a version. The E2E writes a realistic
   API-key file; anyone seeding Codex credentials for a probe should do the
   same.

## Blockers

None for TM-12. The rehearsal ran with
`T3_SMOKE_ALLOW_OUTDATED_PINS=1` and recorded `pinFreshness: "waived"`, so the
pinned-versions drift (T3 0.0.40 vs 0.0.42) is visible but not a blocker here.
TM-16 owns the binary-distribution migration; it blocks TM-13's strict release
path, and the atomic switch must not be tagged until it lands or the policy is
deliberately changed.

## Unavailable checks

- **Credentialed completion.** No provider accounts; see the separation table
  above.
- **arm64 behavior.** Built and digest-mapped for publication; not separately
  smoke-tested or E2E-tested by policy (native amd64 is the evidence platform).
- **Registry-mode startup measurement.** `measure-image.sh --registry` cannot
  time a boot; the candidate test job measures from the pulled digest, as in
  `ci-evidence.md`.
- **T3's own auth verdicts for Claude, Grok, and Cursor** are informational in
  this effort (Claude reported ready in the local dry run, Grok/Cursor
  unauthenticated); only the OpenCode file-backed sign-in is asserted, and the
  setup surface is the authority for the others.

## Reproducing

```sh
# Build and run the E2E on the final targets (native amd64):
scripts/build.sh --target core    --tag t3code:core
scripts/build.sh --target browser --tag t3code:browser
scripts/test-toolchain-e2e.sh --variant core    t3code:core
scripts/test-toolchain-e2e.sh --variant browser t3code:browser

# Pin the harness versions instead of resolving mise's latest:
T3C_E2E_CLAUDE_VERSION=2.1.274 T3C_E2E_CODEX_VERSION=0.154.0 \
T3C_E2E_OPENCODE_VERSION=1.18.31 T3C_E2E_GROK_VERSION=1.0.34 \
T3C_E2E_CURSOR_VERSION=2026.09.15-d2fe57e \
  scripts/test-toolchain-e2e.sh --variant core t3code:core

# Transitional smoke tests:
scripts/smoke-test.sh --variant slim t3code:slim
scripts/smoke-test.sh --variant full t3code:full

# The full native rehearsal (builds both architectures, runs every capability
# check plus the E2E hook, promotes only the tested digests):
gh workflow run toolchain-candidate.yml --ref <branch> \
  -f targets="slim full core browser" -f run_e2e=true
```
