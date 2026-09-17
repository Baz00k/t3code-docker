# T3 Provider Execution And Update Audit

TM-02 deliverable. This is the factual provider matrix behind the harness
management design: how the pinned T3 release discovers, launches, probes, and
updates each supported harness, and where the executable-override seam is. It is
deliberately limited to what can be proven from the pinned package plus
reproducible local runs; it does not redesign the product.

Companion tool: [`scripts/audit-t3-providers.mjs`](../../scripts/audit-t3-providers.mjs).
The canonical product contract is
[`TOOLCHAIN-MANAGEMENT-PLAN.md`](../../TOOLCHAIN-MANAGEMENT-PLAN.md).

## Pinned Package

| Field | Value |
| --- | --- |
| Package | `t3` |
| Version | `0.0.40` (`Dockerfile` `T3_VERSION`) |
| Tarball | `https://registry.npmjs.org/t3/-/t3-0.0.40.tgz` |
| Integrity | `sha512-lvyH1fexahy7lVXNNWP9FUE/IRlYFKEt5DksoscftVY0VBDQ3LBVrKbyYd5iiHWXr1Qun3Fcbf+kXsIP+75wjg==` |
| shasum | `544a26c9f9ee6ce3c9c9a339f23702437b220b3b` |
| Engines | `node: ^22.16 || ^23.11 || >=24.10` |
| Entry module | `dist/bin.mjs` (package `bin.t3`) |

The bundle is not minified past recognition: it ships `dist/bin.mjs.map` with
full `sourcesContent`, so the audit reads the original TypeScript rather than
inferring behavior from the bundle. That is the reproducible evidence base for
every claim below.

### Immutable T3 infrastructure

- **Entry module:** `dist/bin.mjs`. TM-03 installs it into the root-owned
  immutable prefix at `/opt/t3/lib/node_modules/t3/dist/bin.mjs`; it is no
  longer part of the mutable `/opt/npm-global` prefix. See
  [`infrastructure.md`](./infrastructure.md).
- **Runtime:** the loaded Node must satisfy the engines range above. The image
  Node is what T3 and setup must run under; nothing under a project or mise
  toolchain may shadow it.
- **CLI surface** (from `src/bin.ts` `withSubcommands`): `start`, `serve`, `app`,
  `pair`, `auth`, `project`, `service`, `__service-preflight`, `theme`, `triage`,
  `connect`. There is no provider install/update subcommand: provider
  maintenance is a server-side action only.

### Administrative call sites in this repository

These were the places that invoked T3 by name (i.e. resolved it through `PATH`)
and were therefore pinned to absolute image infrastructure by TM-03. Every call
now goes through the immutable launcher (`/usr/local/bin/t3-admin`, also
`/usr/local/bin/t3`) or the absolute image Node:

| Call site | Invocation now |
| --- | --- |
| `docker/entrypoint.sh` | `"$T3_INFRA_LAUNCHER" project add ...`, `exec "$T3_INFRA_LAUNCHER" serve ...` |
| `docker/entrypoint.sh` | `"$T3_INFRA_NODE" /opt/t3-setup/server.mjs` |
| `docker/bin/t3-pair` | `"$T3_INFRA_LAUNCHER" auth pairing create --json ...` |
| `docker/bin/t3-login` | `"$T3_INFRA_LAUNCHER" connect` |
| `docker/bin/t3-doctor` | `"$T3_INFRA_LAUNCHER" --version` |
| `docker/setup/server.mjs` | `run(T3_LAUNCHER, args, ...)` |
| `scripts/smoke-test.sh` | bundle discovery from `T3_INFRA_PREFIX`, no longer `/opt/npm-global` |
| `Dockerfile` | `npm install -g --prefix /opt/t3 t3@${T3_VERSION}`, root-owned and `go-w` |

Details, including the launcher interface and the mutable user npm prefix, are in
[`infrastructure.md`](./infrastructure.md).

## Provider Matrix

Extracted from `t3@0.0.40` by `scripts/audit-t3-providers.mjs --expect-version 0.0.40`:

| Provider | T3 driver kind | Settings default `binaryPath` | Enabled by default | Probe | Launch | Minimum version | Updater |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Claude | `claudeAgent` | `claude` | yes | `claude --version` + SDK init probe | `pathToClaudeCodeExecutable` (Claude Agent SDK) | none | package-managed `@anthropic-ai/claude-code` (`claude update` only for the native install layout) |
| Codex | `codex` | `codex` | yes | `codex app-server` initialize | `codex app-server` (JSON-RPC) | none | package-managed `@openai/codex` (`codex update` only for the standalone layout) |
| OpenCode | `opencode` | `opencode` | no (opt-in) | `opencode --version` + `opencode serve` inventory | `opencode serve` (SDK) | `1.14.19` | package-managed `opencode-ai` (`opencode upgrade` only for the native layout) |
| Grok | `grok` | `grok` | no (opt-in) | `grok --version` + `grok models` | `grok ... acp` (ACP) | none | manual-only |
| Cursor | `cursor` | `cursor-agent` | no (opt-in) | `cursor-agent about --format json` | `cursor-agent ... acp` (ACP) | none (model-picker needs CLI date `>= 2026-04-08`) | self-updating (`cursor-agent update`) |

Every provider resolves its executable from a per-instance `binaryPath` setting
(`packages/contracts/src/settings.ts`), and on Linux the configured value is
spawned verbatim (`resolveSpawnCommand` returns `{ command, args, shell: false }`
for non-`win32`; `src/provider/Drivers/ClaudeExecutable.ts` returns the value
unchanged off Windows). **That is the supported integration seam: an absolute,
concrete managed executable path per instance.** No PATH workaround is required
or permitted.

The settings also carry per-instance isolation used by the manager:

| Provider | Home / isolation setting | Credential surface |
| --- | --- | --- |
| Claude | `homePath` -> `CLAUDE_CONFIG_DIR` | `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, or `claude auth login` |
| Codex | `homePath` -> `CODEX_HOME`, plus `shadowHomePath` account overlay | `~/.codex/auth.json`, `codex login` (API key via stdin or device auth) |
| OpenCode | `serverUrl` / `serverPassword` (optional external server) | `~/.local/share/opencode/auth.json` |
| Grok | none (uses `$HOME`) | `XAI_API_KEY` wins, else `~/.grok/auth.json`, else `grok login` |
| Cursor | none (uses `$HOME`) | `~/.cursor/cli-config.json`, `cursor-agent login` |

## Update Ownership

`src/provider/providerMaintenance.ts` derives a one-click updater from the
**real path** of the resolved executable, and only when ownership is proven:

- `npm install -g --prefix <prefix> --allow-scripts=<pkg> <pkg>@latest` when the
  real path is `<prefix>/lib/node_modules/<pkg>/...`;
- `bun`/`pnpm`/`vp` global commands for those prefixes;
- `brew upgrade` only when the keg prefix matches `brew --prefix`;
- otherwise **manual-only**.

Crucially for mise:

```ts
// providerMaintenance.ts
const miseTool = /\/mise\/installs\/([^/]+)\/[^/]+$/.exec(...)?.[1];
if (miseTool && miseTool !== "node") return null;   // manual-only
```

A mise-owned harness path is treated as manual-only, so T3 never offers an
`npm`/`brew` update that would fight mise. Providers whose settings expose no
package name (Grok) are manual-only unconditionally. Cursor is the one
exception: its resolver always offers `<resolved-executable> update` whenever
the binary resolves, because the CLI is its own updater.

`enableProviderUpdateChecks` (default `true`) additionally makes T3 fetch the
npm registry "latest" for package-managed providers to compute a version
advisory. It does not install or update anything; it only decides whether an
update button appears. Grok and Cursor carry no package name and therefore make
no registry request.

### Live updater reproduction

Run against `t3@0.0.40` with `--base-dir` pointing at a throwaway data dir. T3
persists each provider snapshot to `<base-dir>/caches/<instanceId>.json`, which
is where the derived command is read from.

| Managed executable real path | Resulting `versionAdvisory.updateCommand` | `canUpdate` |
| --- | --- | --- |
| `<p>/lib/node_modules/@anthropic-ai/claude-code/cli.js` | `npm install -g --prefix <p> --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code@latest` | true |
| `<p>/lib/node_modules/@openai/codex/bin.js` | `npm install -g --prefix <p> --allow-scripts=@openai/codex @openai/codex@latest` | true |
| `<mise>/installs/codex/0.154.0/bin/codex` (mise layout) | `null` | false |
| `<mise>/installs/opencode/1.18.31/opencode` | `null` | false |
| `<mise>/installs/grok/1.0.34/grok` | `null` | false |
| plain `/tmp/.../cursor-agent` | `/tmp/.../cursor-agent update` | true |

**Verdict: proceed for all five.** A managed mise path cannot be silently
mutated by T3's npm/brew updater (it resolves manual-only). Cursor is the one
exception by design: its resolver always offers `<resolved-executable> update`
because the CLI updates itself, and that behaviour is accepted rather than
gated. A managed Cursor that is updated through T3 or `cursor-agent update`
simply becomes newer than the exact version the manager recorded; the manager
reports the version it installed, not a lock, and no code exists to prevent or
redirect the self-update.

## Executable Override Reproduction

Two fake provider trees were created; the managed ones were referenced only by
absolute `binaryPath`, and decoy `claude`/`codex`/`cursor-agent`/`opencode`/
`grok` scripts sat earlier on `PATH`. A `t3 serve` run with `enableProviderUpdateChecks`
left at default produced:

```text
MANAGED claude --version
MANAGED claude --output-format stream-json --verbose --input-format stream-json \
  --setting-sources=user,project,local --strict-mcp-config \
  --permission-mode default --no-session-persistence --settings {"disableAllHooks":true}
MANAGED codex app-server
MANAGED cursor-agent about --format json
MANAGED cursor-agent acp
MANAGED opencode --version
MANAGED opencode serve --hostname=127.0.0.1 --port=<port>
MANAGED grok --version
MANAGED grok models
MANAGED grok inspect --json
MANAGED grok agent stdio
```

The decoy log stayed empty. So:

- the configured absolute `binaryPath` wins over `PATH` for every provider;
- the same seam covers probes **and** the real launch (`app-server`, `serve`,
  `acp`, and the Claude SDK spawn);
- the Claude SDK spawn (`--output-format stream-json ...`) is the capabilities
  probe, which the source documents as never yielding a prompt, so it performs
  no API request.

## Cursor `cursor-agent` Versus `agent`

Resolved: **`cursor-agent` is canonical; `agent` is an alias the native
installer happens to create.**

Evidence:

- T3 `CursorSettings.binaryPath` default is `cursor-agent`, and the ACP and
  probe paths fall back to `cursor-agent` (`buildCursorAcpSpawnInput`,
  `checkCursorProviderStatus`).
- The vendor install script (`https://cursor.com/install`) creates **both**
  `~/.local/bin/agent` (primary) and `~/.local/bin/cursor-agent` (legacy) as
  symlinks to the same versioned binary.
- The released `agent-cli-package.tar.gz` contains exactly one launcher,
  `dist-package/cursor-agent`; there is no `agent` file in the package.
- The mise backend `http:cursor-agent` recreates only `bin/cursor-agent`:

  ```text
  postinstall=mkdir -p "$MISE_TOOL_INSTALL_PATH/bin" &&
    ln -sfn ../dist-package/cursor-agent "$MISE_TOOL_INSTALL_PATH/bin/cursor-agent"
  ```

Consequences:

- `docker/bin/t3-login:41` (`cursor) cmd=(agent login)`) is the odd one out and
  must move to `cursor-agent login`; it would break once the image stops
  installing Cursor through the vendor script.
- `docker/setup/server.mjs` already probes `cursor-agent`, matching T3.
- Do not create an `agent` alias for Cursor: no supported source needs it, and
  an `agent` binary on `PATH` collides with Grok's aqua package, whose registry
  entry also links its artifact as `agent` (`pkgs/x.ai/cli/grok/registry.yaml`,
  `files: [grok, agent]`).

## Polling And Discovery Side Effects

Status/discovery is read-only with respect to the toolchain: no provider probe
installs or updates a harness. Classified per provider:

| Provider | Processes spawned during status | Network during status | Mutates toolchain |
| --- | --- | --- | --- |
| Claude | `claude --version`; one SDK init spawn; skill discovery | npm registry "latest" (only with `enableProviderUpdateChecks`, default true) | no |
| Codex | `codex app-server` initialize; skill discovery | npm registry "latest" | no |
| OpenCode | `opencode --version`; local `opencode serve` for inventory | npm registry "latest" | no |
| Grok | `grok --version`; `grok models`; `grok inspect`; skill discovery | none (manual-only, no package name) | no |
| Cursor | `cursor-agent about`; ACP model discovery (`cursor-agent acp`) | none (no package name) | no |

Additional notes:

- A provider with `enabled: false` returns a disabled snapshot without spawning
  anything (Cursor/Grok/OpenCode default to disabled).
- Results are cached: provider snapshots are persisted to
  `<base-dir>/caches/<instanceId>.json`, the Claude capabilities probe has a
  5-minute TTL, maintenance capabilities a 1-hour TTL, and npm "latest" a
  1-hour TTL. Polling does not cause repeated work.
- T3 also refreshes a remote model manifest in the background
  (`modelManifest.refreshInBackground`) for Claude. It is a network fetch, not
  an install/update.
- Offline behavior and the 5-second `/status` budget are TM-09's concern; this
  audit only establishes that these probes exist and are side-effect free.

## mise Exact-Version Sources And Architecture

Catalogue tools (`mise registry`): `claude`, `codex`, `opencode`, `grok`,
`cursor-agent`. Exact versions are resolvable for all five; linux/amd64 and
linux/arm64 artifacts were confirmed with HTTP 206 range requests.

| Tool | mise backend | Exact-version source | linux/amd64 | linux/arm64 | Checksum |
| --- | --- | --- | --- | --- | --- |
| claude | `aqua:anthropics/claude-code` | GitHub releases `anthropics/claude-code` `vX.Y.Z`; assets `claude-linux-{x64,arm64}.tar.gz`, `SHASUMS256.txt` | yes | yes | sha256 + cosign |
| codex | `aqua:openai/codex` | GitHub releases `openai/codex` `rust-vX.Y.Z`; `codex-package-{x86_64,aarch64}-unknown-linux-musl.tar.gz` | yes | yes | none in registry |
| opencode | `aqua:anomalyco/opencode` | GitHub releases `anomalyco/opencode` `vX.Y.Z`; `opencode-linux-{x64,arm64}.tar.gz` | yes | yes | sha256 |
| grok | `http:grok` | `storage.googleapis.com/grok-build-public-artifacts/cli/grok-<v>-linux-{x86_64,aarch64}`; `version_list_url` only advertises stable | yes | yes | none |
| cursor-agent | `http:cursor-agent` | `downloads.cursor.com/lab/<date-hash>/linux/{x64,arm64}/agent-cli-package.tar.gz`; version discovered from the install script | yes | yes | none |

The transitional image pins `claude 2.1.270`, `codex 0.154.0`,
`opencode 1.18.30`, `grok 1.0.30`, and unpinned Cursor; all of those exact
versions exist on the sources above.

Risks handed to TM-06:

- Grok's `version_list_url` returns only the current stable version, so an
  exact pin must be recorded at install time and the artifact must still exist;
  there is no historical listing to fall back to.
- Cursor's version list is scraped from the install script, so exact versions
  are date-hash pins. They are reproducible but not semver-ordered.
- codex, grok, and cursor installs carry no checksum in mise's metadata; the
  manager must not claim verified downloads for them.
- The aqua Grok package (`aqua:x.ai/cli/grok`) is currently unusable (`does not
  have repo_owner and/or repo_name`), so `http:grok` is the active backend.

## Verdicts

| Provider | Discovery | Launch | Update | Verdict |
| --- | --- | --- | --- | --- |
| Claude | `binaryPath` | SDK `pathToClaudeCodeExecutable` | manual-only for mise paths | proceed |
| Codex | `binaryPath` | `codex app-server` | manual-only for mise paths | proceed |
| OpenCode | `binaryPath` | `opencode serve` | manual-only for mise paths; `MINIMUM_OPENCODE_VERSION=1.14.19` must be honoured by the manager | proceed |
| Grok | `binaryPath` | `grok ... acp` | manual-only | proceed |
| Cursor | `binaryPath` | `cursor-agent ... acp` | self-updating; accepted for managed instances | proceed |

No upstream blocker: every provider exposes the supported executable override
seam the plan requires, and none of them installs or updates during discovery.

## Reproductions

Static matrix (offline, needs a `t3@0.0.40` package; `npm i t3@0.0.40` in a
scratch dir produces one):

```sh
node scripts/audit-t3-providers.mjs --package node_modules/t3 --expect-version 0.0.40
node scripts/audit-t3-providers.mjs --package node_modules/t3 --json
node scripts/audit-t3-providers.mjs --package node_modules/t3 --mise --mise-versions
```

Live executable-override and updater reproduction:

```sh
# 1. fake provider trees; the managed ones are only referenced by absolute path
# 2. decoy claude/codex/cursor-agent/opencode/grok earlier on PATH
# 3. seed <base>/userdata/settings.json with providers.<kind>.{enabled,binaryPath}
# 4. run:
node node_modules/t3/dist/bin.mjs serve --base-dir <base> --port <p> --host 127.0.0.1
# 5. managed log shows every probe/launch; decoy log stays empty
# 6. read the derived updater from <base>/caches/<kind>.json .versionAdvisory.updateCommand
```

Cursor alias:

```sh
curl -fsSL https://cursor.com/install | grep -n 'local/bin/agent'
# 130: ln -s .../cursor-agent ~/.local/bin/agent
# 131: ln -s .../cursor-agent ~/.local/bin/cursor-agent
curl -fsSL https://downloads.cursor.com/lab/<version>/linux/x64/agent-cli-package.tar.gz \
  | tar -tzf - | grep -E 'cursor-agent$'
```

## Handoff

- **Immutable entry discovery:** T3's package `bin.t3` (`dist/bin.mjs`); the
  image path is `/opt/t3/lib/node_modules/t3/dist/bin.mjs`. Launch it with the
  absolute image Node through the `/usr/local/bin/t3-admin` launcher, never
  through a mise shim or an `env node` shebang; see
  [`infrastructure.md`](./infrastructure.md).
- **Provider adapter contract:** one concrete absolute executable per instance
  via `<Provider>Settings.binaryPath`; optional per-instance home
  (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`). Probes and launches use it on Linux
  verbatim; no PATH manipulation.
- **Canonical Cursor executable:** `cursor-agent`. `agent` is native-installer
  only and must not be relied on or aliased.
- **Updater policy:** mise-owned paths are manual-only for T3's npm/brew
  updater; the manager owns Install/Update/Uninstall. Cursor's own
  `cursor-agent update` is accepted and is not intercepted or disabled.
- **Credentials to preserve on Uninstall:** `~/.claude` / `CLAUDE_CONFIG_DIR`,
  `~/.codex` / `CODEX_HOME` (plus shadow home),
  `~/.local/share/opencode/auth.json`, `~/.cursor/cli-config.json`,
  `~/.grok/auth.json` and `XAI_API_KEY`.
- **Blockers:** none. Cursor may self-update a managed binary; that is an
  accepted product decision, not a caveat to code around.
- **Limits inside providers:** project mise toolchains are only selected on
  explicit `mise exec`/`mise run` paths; a harness subprocess sees the image or
  project PATH, not a transparent project toolchain, unless the harness runs
  mise itself.
