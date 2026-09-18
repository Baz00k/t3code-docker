# T3 Managed Harness Integration

TM-07 deliverable. T3 Code launches the exact executable the persistent harness
manager (TM-06) selected, through the one supported integration seam - the
per-provider `binaryPath` setting - with no PATH workaround and no code that
touches a provider's own updater.

Companion verification:

```sh
node --test tests/provider-integration.test.mjs              # 14 unit tests
scripts/test-provider-integration.sh t3code:core t3code:browser # 54 container assertions
```

The provider facts behind the seam are in
[`provider-audit.md`](./provider-audit.md); the manager API is in
[`harness-api.md`](./harness-api.md); mise storage and policy are in
[`project-execution.md`](./project-execution.md). The canonical product
contract is [`TOOLCHAIN-MANAGEMENT-PLAN.md`](../../TOOLCHAIN-MANAGEMENT-PLAN.md).

## The seam

T3 Code reads provider configuration from
`$T3CODE_HOME/userdata/settings.json` (`ServerConfig.deriveServerPaths`). Each
provider has an absolute `binaryPath` setting, and on Linux the driver spawns
that value verbatim for its probe **and** its real launch (the audit's
reproduction). T3 watches the settings file and re-reads it live, so a write
reaches a running server without a restart.

Two representations exist in the file:

| Representation | Key | Behaviour |
| --- | --- | --- |
| Legacy single instance | `providers.<driverKind>.binaryPath` | Hydrated into a default instance by T3 when no explicit one exists. This is what the audit proved live. |
| Explicit instance | `providerInstances.<driverKind>.config.binaryPath` | Wins over the legacy mirror; must be updated too or it would shadow the selection. |

Driver kinds are not harness ids: Claude is `claudeAgent`, and Cursor's driver
kind is `cursor` while its executable is `cursor-agent`. The mapping is in
`docker/provider-integration/providers.mjs`.

`sync()` edits the legacy blob and, when an explicit default instance already
exists, that instance's config. It **never creates** a `providerInstances`
entry: synthesising one would shadow the legacy `enabled` flag and silently
change enablement. Every unrelated key at every level is preserved, so a
user-authored `launchArgs`, `homePath`, `enabled: false` or top-level setting
survives untouched.

## Module layout

| File | Responsibility |
| --- | --- |
| `docker/provider-integration/providers.mjs` | Harness id ↔ T3 driver kind mapping. |
| `docker/provider-integration/settings.mjs` | Pure `applyManaged`/`clearManaged` edits, path helpers, atomic JSON read/write. |
| `docker/provider-integration/index.mjs` | `createProviderIntegration({ harness, fs, env, home, baseDir })`; owns `sync()`. |
| `docker/provider-integration/fsutil.mjs` | Filesystem seam (injectable). |
| `docker/provider-integration/cli.mjs` | `resolve`, `sync`, `status` for the shell helpers and the entrypoint. |

Import it with plain ESM:

```js
import { createProviderIntegration } from "/opt/t3-provider/index.mjs";
const integration = createProviderIntegration({ harness }); // harness = createHarnessManager()
const report = await integration.sync();
```

## `sync()` semantics

1. Ask the manager for `status({ authenticate: false })` - **one** read-only
   `mise ls` plus filesystem checks. No call in this path installs or updates
   anything.
2. For every harness that is `runnable` with a concrete `executable`, write
   that absolute path to `binaryPath` (legacy blob and explicit default
   instance).
3. For a harness this module previously managed that is no longer runnable
   (for example after Uninstall), retract the value **only if it is still
   exactly what this module wrote**. A user who edited the field keeps their
   edit; the module stops tracking it.
4. Record what it wrote in `$T3CODE_HOME/provider-integration.json` (mode
   `0600`, atomic), which is what makes step 3 safe across restarts.

`sync()` returns `{ ok, applied, cleared, unchanged, missing, degraded,
settingsChanged }`. A degraded mise is reported, not fatal - T3 keeps its own
defaults and no `binaryPath` is written, so an installed provider is not
half-configured. A malformed settings file is **never overwritten**: `sync`
returns `{ ok: false, code: "settings-unreadable" }` and leaves the bytes alone.

Writes are atomic (temp file plus `rename`). `sync` writes the settings file
only when a value actually changed, and the state file only when its record
changed.

## CLI contract

```sh
node /opt/t3-provider/cli.mjs resolve <id>          # print managed executable
node /opt/t3-provider/cli.mjs sync [--json]         # apply selections to T3
node /opt/t3-provider/cli.mjs status                # manager facts as JSON
```

`resolve` prints nothing and exits `3` when the harness is not runnable, so
callers can fall back. Any other non-zero exit (`4` for a broken module or a
missing manager, `2` for usage) means "no managed answer". `T3_HARNESS_MODULE`
overrides the baked `/opt/t3-harness/index.mjs` for tests.

`sync` writes the JSON report to stdout with `--json`; without it, one summary
line (`applied claude,opencode; cleared none`) that the entrypoint logs.

## Entrypoint, `t3-login`, `t3-browser-mcp`

- **Entrypoint:** `sync_managed_providers` runs once per start, after the user
  tool environment is sourced and before setup/serve. Success is logged; a
  missing module is a no-op and a failure only warns.
- **`t3-login`:** resolves the managed executable for the requested harness and
  runs the sign-in through it, falling back to the baked harness on PATH. It
  now uses `cursor-agent login` - `agent` is native-installer-only (the audit
  resolved the naming inconsistency; an `agent` binary would also collide with
  Grok's aqua package).
- **`t3-browser-mcp`:** each of Claude, Codex and OpenCode is registered
  through its managed executable when one is runnable, and through the baked
  harness otherwise. The script prints `(via <path>)` so the choice is visible,
  and the container test asserts against it.

Both shell helpers source `/etc/profile.d/t3-user-env.sh` after dropping to
`t3`, so the resolver sees the same `MISE_*` paths the server does.

## MCP configuration locations

| Harness | Registration | Config written |
| --- | --- | --- |
| Claude | `<managed claude> mcp add --scope user <name> -- <server> ...` | `~/.claude.json` (`mcpServers`) |
| Codex | direct TOML block | `${CODEX_HOME:-$HOME/.codex}/config.toml` (`[mcp_servers.<name>]`) |
| OpenCode | direct JSON edit | `${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json` (`.mcp.<name>`) |

Registration is idempotent: any block this script wrote before is removed
first. Chromium flags are unchanged (`--no-sandbox`, `--isolated`).

## Cursor's self-updater is deliberately not gated

Cursor's CLI is its own updater, and the product decision is to accept that. A
managed Cursor may update itself directly or through T3's update action and
become newer than the exact version the manager recorded at install time. The
recorded version is **advisory, not a lock**. No code in this integration (or
anywhere TM-07 owns) blocks, redirects, disables or re-surfaces that
self-update, and no `enableProviderUpdateChecks` override is written. The
container test asserts that no gating tokens exist in the owned files.

For the other four harnesses the updater question is answered by mise, not by
this code: a mise-owned path (`.../mise/installs/<tool>/<version>/...`) makes
T3's npm/brew updater resolve `manual-only`, so T3 cannot mutate a managed
harness. The container test proves it by reading the running server's cached
Claude snapshot: `versionAdvisory.updateCommand === null` and `canUpdate ===
false` for the managed path.

## Selection changes and session semantics

- T3 re-reads `settings.json` live, so an Install/Update/Uninstall reaches the
  server as soon as the setup console calls `sync()`. No container restart.
- A selection change applies to **new** provider sessions. A session already
  running keeps the executable it launched with; its in-flight process is not
  migrated. Restart the thread (or the provider session) to pick up a new
  version, as `t3-browser-mcp` already tells users for MCP changes.
- `status`/`resolve` never write and never install: polling a provider
  catalogue or the setup console does not change a toolchain. `sync()` is only
  called on start and after an explicit lifecycle operation.

## Project toolchain limits inside providers

A harness is a managed executable, not a shell that activates mise. A provider
subprocess sees the image or project `PATH`; it does **not** get a transparent
project toolchain. Project-declared runtimes are selected only on explicit
`mise exec` / `mise run` paths (see
[`project-execution.md`](./project-execution.md)). Document this rather than
papering over it with PATH tricks: the plan's contract is a concrete absolute
executable per instance, and the harness is responsible for running mise itself
if it needs a project runtime.

## Verification

`tests/provider-integration.test.mjs` (14) covers the pure merge/clear rules,
the legacy/instance precedence, preservation, the unreadable-settings refusal,
and degraded-mise behaviour with an injected filesystem and manager.

`scripts/test-provider-integration.sh` (54 on native amd64) exercises a real
container:

- sync on a fresh home writes nothing;
- a runnable Claude is written into the legacy blob and an explicit default
  instance, preserving user config and `enabled: false` on an unrelated
  instance;
- Uninstall retracts only the recorded value;
- a **running** `t3 serve` probes the managed Claude: its cached snapshot
  reports the managed version, `installed: true`, and a manual-only update
  command, while decoy binaries earlier on `PATH` are unused for managed
  harnesses (an unmanaged provider still falls back to `PATH`);
- browser registration on `browser` runs through the managed Claude, Codex and
  OpenCode and produces valid config for all three;
- `t3-login` names `cursor-agent` and accepts the managed Claude.

Launch evidence is T3's own probe and SDK/ACP spawn of the configured absolute
path; the version in the cached snapshot is the managed binary's. Auth is a
separate field (`auth.status`) and is not inferred from a successful launch, so
a missing credential stays visible rather than reading as a launch failure.
Credentialed agent sessions require accounts and are covered by TM-12's
end-to-end run.

## Handoff

- **TM-08 (setup UI/CLI):** after every Install/Update/Uninstall, call
  `createProviderIntegration({ harness }).sync()` from
  `/opt/t3-provider/index.mjs` (or shell out to `cli.mjs sync --json`). Do not
  implement a second settings writer. The manager remains the only source of
  executable selection; `sync` is the notification.
- **TM-09 (offline status):** `sync` is not part of status polling. `cli.mjs
  status` and `resolve` use `authenticate: false` and are local-only.
- **TM-12 (E2E):** assert per-harness launch in T3's cached snapshot and the
  manual-only updater verdict; treat a self-updated Cursor as observed drift
  (advisory version), not a failure.
- **TM-13 (product switch):** removing the baked harnesses only changes what
  `t3-login`/`t3-browser-mcp` fall back to; the managed path and `sync`
  behaviour are unchanged, and `bakedFallback.present` already reports their
  absence.
- **Image:** `Dockerfile` copies `docker/harness/` to `/opt/t3-harness` and
  `docker/provider-integration/` to `/opt/t3-provider`; the entrypoint logs the
  one summary line at start.
