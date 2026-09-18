# Persistent Harness Manager API

One module owns exact-version installation, state, locking,
and executable resolution for the five supported harnesses. The setup console
and the T3 integration consume this API instead of inventing
their own install/resolve logic, so there is exactly one source of truth for
which executable a provider launches - no PATH workaround.

Companion verification:

```sh
node --test tests/harness-manager.test.mjs          # 22 unit tests
scripts/test-harness-manager.sh t3code:core         # 125 container assertions
```

The provider facts behind the catalogue are in
[`provider-contract.md`](./provider-contract.md); the mise storage and policy are in
[`project-execution.md`](./project-execution.md). The canonical product
contract is [`TOOLCHAIN-MANAGEMENT-PLAN.md`](../../TOOLCHAIN-MANAGEMENT-PLAN.md).

## Module layout

| File | Responsibility |
| --- | --- |
| `docker/harness/catalogue.mjs` | The five entries: mise tool, executable layout, architectures, minimum version, credential surface, baked fallback, auth kind. |
| `docker/harness/manager.mjs` | Public manager: `status`, `resolve`, `install`, `update`, `uninstall`. Owns the state machine and the lock. |
| `docker/harness/mise.mjs` | The `mise -C <home> ...` argv shapes and JSON parsing. |
| `docker/harness/lock.mjs` | One global O_EXCL lock with stale-owner detection. |
| `docker/harness/state.mjs` | Atomic read/write of the manager's state file. |
| `docker/harness/probe.mjs` | Bounded version and sign-in probes; credential-surface listing. |
| `docker/harness/version.mjs` | Dotted-numeric comparison for the one minimum. |
| `docker/harness/io.mjs` | Child-process and filesystem seams (injectable for tests). |
| `docker/harness/index.mjs` | Public re-exports. |

Import it with or without a bundler; it is plain ESM with Node built-ins only.

```js
import { createHarnessManager } from "./harness/index.mjs";
const harness = createHarnessManager();
```

`createHarnessManager(options)` accepts injectable `env`, `home`, `fs`, `run`,
`now`, `pid`, `isAlive`, `host`, `arch`, `miseBin`, the four `MISE_*` dirs,
`lockStaleMs`, `authCacheTtlMs`, and `timeouts`. Production callers pass
nothing.

## Catalogue

Exactly five entries, ids stable and independent of the mise tool name:

| id | mise tool | executable (relative to install dir) | minimum | arches |
| --- | --- | --- | --- | --- |
| `claude` | `claude` | `claude` | - | x64, arm64 |
| `codex` | `codex` | `bin/codex` | - | x64, arm64 |
| `opencode` | `opencode` | `opencode` | `1.14.19` | x64, arm64 |
| `grok` | `grok` | `grok` | - | x64, arm64 |
| `cursor` | `cursor-agent` | `dist-package/cursor-agent` | - | x64, arm64 |

Cursor is canonical as `cursor-agent`. The native installer's `agent` alias is
never created, named, or relied on - it collides with Grok's aqua package and
mise's backend recreates only `cursor-agent` (see
[`provider-contract.md`](./provider-contract.md)).

`arch` is normalized from node (`x64`/`arm64`) or `dpkg`/uname (`amd64`,
`x86_64`, `aarch64`). `install`/`update` refuse an entry with no build for the
host arch (`unsupported-arch`) before touching mise.

## Facts schema

`status(options)` returns `{ harnesses, degraded }`; `resolve(id, options)`
returns one entry. Both are strictly read-only: they run `mise ls --json`
(forced `MISE_AUTO_INSTALL=false`) and bounded probes, and never `use`,
`install`, `uninstall`, or `unuse`. `degraded` is a list of `{ what, error }`
for a mise read that failed; the facts are then all `false`/`null` rather than
throwing.

| Field | Meaning |
| --- | --- |
| `configured` / `configuredVersion` | A mise config selects this tool (global or otherwise), and the requested version. |
| `installed` / `installedVersion` | The selected version is installed in mise's data dir. |
| `recordedVersion` / `recordedExecutable` | What the manager's own state recorded at the last successful install. |
| `verifiedVersion` | The version the executable reported when it was installed/updated. |
| `executable` | The concrete managed path, present only when the file exists and is executable. |
| `runnable` | `installed` and executable and not failed and no live operation on this harness. |
| `authenticated` | Sign-in verdict: `true`, `false`, or `null` (not readable). Only probed when there is an executable. |
| `failed` / `failure` | The last operation failed, was interrupted, or the installed version is below the minimum. |
| `operation` / `operationState` / `inProgress` | Last operation kind and state; `inProgress` is a live lock held for this harness. |
| `minimumVersion` / `minimumSatisfied` | The enforced floor and whether the installed version meets it. |
| `managedVersions` | Every version this manager installed for the harness. |
| `bakedFallback` | `{ present, executable, version }` for the historical baked binary; always `present: false` in the final images. |
| `credentials` | `{ present, env, paths }` - which credential sources exist. |

`options.authenticate` (default `true`) controls sign-in probing;
`options.probeBaked` (default `false`) adds a version probe for the baked
binary. Pass `authenticate: false` for a cheap poll.

Facts are never derived from a silent PATH search. `executable` is
`<install_path>/<relative executable>` from the catalogue, cross-checked with
`mise which` at operation time.

## Operations

```js
await harness.install("claude");                       // resolve latest, record exact
await harness.install("opencode", { version: "1.18.30" });
await harness.update("opencode");                      // explicit; latest
await harness.update("opencode", { version: "1.18.31" });
await harness.uninstall("grok");
await harness.invalidateAuth("claude");                // after a sign-in changes it
```

- **Install** resolves `mise latest <tool>` unless a version is given, records
  the exact version and the concrete executable, and verifies the executable by
  running its `--version`. It uses `mise use -g`, so the selection is recorded
  in `~/.config/mise/config.toml` system-wide.
- **Update** requires an installed harness (`not-installed` otherwise), resolves
  an exact version the same way, and keeps the replaced version in
  `managedVersions`. It never prunes other versions; Uninstall removes what the
  manager installed.
- **Uninstall** removes the global selection and every `managedVersions` entry.
  It never touches credential directories or files, and it reports remaining
  installed versions instead of claiming the provider is absent.
- Versions are validated against a strict syntax before use and the
  `version:`/`tool:` are always separate argv entries, so no request input can
  become a shell token.
- Operations return `{ ok, code, error?, harness }`. `code` is one of `ok`,
  `unknown-harness`, `unsupported-arch`, `busy`, `lock-error`,
  `invalid-version`, `version-below-minimum`, `not-runnable`, `not-installed`,
  `failed`.

## Concurrency, locking, and interrupted operations

All operations serialize on one lock file, `$MISE_STATE_DIR/harness.lock`. It
is created with `O_EXCL`, records `{ pid, host, token, id, operation, startedAt }`,
and is removed only by its owner (verified by token). mise writes one user-wide
config and one installs tree, so concurrent operations could otherwise
half-write configuration or report a harness runnable mid-extraction.

- A second operation while a live lock exists returns `busy` without touching
  state.
- A lock is stale when its recorded pid no longer exists or it is older than
  `lockStaleMs` (15 minutes). A stale lock is removed and the operation
  proceeds, so a `SIGKILL`ed install heals on the next attempt.
- The in-progress operation is recorded in the state file. While a live lock
  exists, `runnable` is forced `false` for that harness. If the operation was
  interrupted, `status`/`resolve` report `failed: true` with a message, and
  `runnable: false`, until a successful install/update supersedes it.
- Status and resolve never write: they read the lock and interpret it, so a
  stuck lock cannot be silently cleared into a concurrent install.

## State schema

`$MISE_STATE_DIR/harness-state.json`, mode `0600`, atomically replaced via a
temp file plus `rename`:

```json
{
  "schema": 1,
  "harnesses": {
    "claude": {
      "version": "2.1.270",
      "executable": "/home/t3/.local/share/mise/installs/claude/2.1.270/claude",
      "verifiedVersion": "2.1.270",
      "managedVersions": ["2.1.270"],
      "installedAt": 1750000000000,
      "updatedAt": 1750000000000,
      "operation": { "kind": "install", "state": "ok", "startedAt": null, "finishedAt": 1750000000000, "error": null }
    }
  }
}
```

`operation.state` is `in-progress`, `ok`, or `failed`. mise remains the source
of truth for what is installed now; this file adds the facts mise cannot express
- the resolved executable, the versions this manager owns, and whether an
operation was interrupted.

## Executable paths and aliases

Resolved as `<MISE_DATA_DIR>/installs/<mise tool>/<version>/<relative>`:

```text
claude         .../installs/claude/<v>/claude
codex          .../installs/codex/<v>/bin/codex
opencode       .../installs/opencode/<v>/opencode
grok           .../installs/grok/<v>/grok
cursor         .../installs/cursor-agent/<v>/dist-package/cursor-agent
```

`mise which <tool>` is consulted after install/update and used when it answers;
the catalogue path is the fallback so resolution never depends on a PATH search.
No `agent` alias is created for Cursor.

## Baked fallback semantics

The catalogue still lists the historical fallback paths
(`/opt/npm-global/bin/<name>`, `/opt/cursor/.local/bin/cursor-agent`), but the
final `core`/`browser` images ship no baked harness executables: `present` is
always `false` there, and Uninstall always removes the provider. The field is
kept so the manager's contract does not change shape and an older image
loaded alongside this code still reports honestly. A live read-only status of
the fallback binary is opt-in via `probeBaked: true`; the default reports
presence and path only.

## Credentials and sign-in

Uninstall never deletes a credential. The catalogued surfaces are:

| Harness | Env | Files (relative to `$HOME`) |
| --- | --- | --- |
| Claude | `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` | `.claude/.credentials.json` |
| Codex | - | `.codex/auth.json` |
| OpenCode | - | `.local/share/opencode/auth.json` |
| Grok | `XAI_API_KEY` | `.grok/auth.json` |
| Cursor | - | `.cursor/cli-config.json` |

`authenticated` is answered per harness the way the setup console asks: Claude
`auth status --json`, Codex `login status`, OpenCode its credential file (and
whether it holds any provider), Grok `XAI_API_KEY` then `grok models`, Cursor
`status --format json`. Probes are bounded by `timeouts.probe` (20s) and cached
for `authCacheTtlMs` (10s) per `id`, keyed by executable and version. Call
`invalidateAuth(id)` (or `invalidateAuth()` for all) after a sign-in changes
the verdict.

## Architecture and exact-version policy

Both x64 and arm64 are supported for every entry; verification in this effort is
native amd64 only, per the plan. Exact versions are resolved by mise at
install/update time and recorded verbatim; no floating selection is retained.
Known backend limits are not papered over: Grok advertises only the current
stable version and cursor versions are date-hash pins, so an exact recorded
version is reproduced from the recorded artifact, not re-derived. The manager
does not claim verified downloads for backends without checksums (Codex, Grok,
Cursor); only the executable-run verification is promised.

## Integration constraints

Consumers write `resolve(id).executable` to the provider's `binaryPath` only
when the harness is runnable; no PATH shim is needed or permitted. Setup renders
the manager's configured/installed/runnable/authenticated/failed facts and calls
the lifecycle methods directly. `status({ authenticate: false })` is the cheap,
local path for polling and never installs or updates. Cursor's native self-update
remains accepted, and final images report no baked fallback.
