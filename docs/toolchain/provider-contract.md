# T3 Provider Contract

This is the durable integration contract between T3 Code, the harness manager,
and the five supported providers. It records the conclusions that implementation
and regression tests depend on; the one-off source audit and reproduction script
used during development are intentionally not shipped.

The concrete settings writer is documented in
[`provider-integration.md`](./provider-integration.md), and lifecycle behavior is
documented in [`harness-api.md`](./harness-api.md).

## Executable selection

Every supported T3 provider exposes a per-instance `binaryPath`. On Linux, T3
spawns that configured value verbatim for both status probes and real launches.
Managed integrations must therefore write one absolute executable path and must
not manipulate `PATH` to override provider discovery.

| Provider | T3 driver | Managed executable | Probe and launch | T3 updater for a mise path |
| --- | --- | --- | --- | --- |
| Claude Code | `claudeAgent` | `claude` | `claude --version`; Claude SDK with `pathToClaudeCodeExecutable` | manual-only |
| Codex | `codex` | `codex` | `codex app-server` | manual-only |
| OpenCode | `opencode` | `opencode` | `opencode --version`; `opencode serve` | manual-only; minimum `1.14.19` |
| Grok | `grok` | `grok` | version/models probes; ACP launch | manual-only |
| Cursor | `cursor` | `cursor-agent` | `about`; ACP launch | self-updating by product policy |

`cursor-agent` is canonical. The vendor installer may also create an `agent`
alias, but the managed artifact and T3 both use `cursor-agent`; this repository
must not create or depend on the alias.

## Update ownership

T3 derives package-manager update actions from the real path of an executable.
A path under `.../mise/installs/<tool>/<version>/...` resolves to manual-only,
so T3 does not mutate Claude, Codex, OpenCode, or Grok installations owned by
the harness manager. Install, Update, and Uninstall remain explicit manager
operations.

Cursor is the accepted exception. `cursor-agent update` can change the installed
binary after the manager recorded its exact version. The recorded Cursor version
is advisory rather than a lock; no repository code blocks, redirects, or hides
the self-update.

## Read-only discovery

Provider status may spawn provider probes and may perform advisory network
checks, but it must never install or update a harness. Setup polling uses cached
or bounded local state as described in [`offline.md`](./offline.md). Provider
integration `status` and `resolve` are read-only; `sync` writes executable
selection only after startup or an explicit lifecycle operation.

## Credentials and uninstall

Uninstall removes the managed selection and executable but preserves provider
credentials and user data, including:

- Claude configuration (`~/.claude` / `CLAUDE_CONFIG_DIR`);
- Codex configuration (`~/.codex` / `CODEX_HOME`, including its shadow home);
- OpenCode authentication (`~/.local/share/opencode/auth.json`);
- Grok authentication (`~/.grok/auth.json`; `XAI_API_KEY` may also be used);
- Cursor configuration (`~/.cursor/cli-config.json`).

## Regression coverage

The durable contract is enforced rather than re-audited during ordinary
maintenance:

- `tests/provider-integration.test.mjs` covers settings merge, preservation,
  clearing, and degraded-state behavior;
- `scripts/test-provider-integration.sh` proves a running T3 uses managed
  absolute paths, ignores PATH decoys, reports manual-only updates for mise
  installs, and registers browser MCP servers through managed harnesses;
- `scripts/test-toolchain-e2e.sh` installs all five harnesses and verifies T3
  launches them through the configured provider seam;
- `docker/harness/catalogue.mjs` owns install source, executable, architecture,
  and credential metadata.

When upgrading T3, review upstream provider settings, probes, launch paths,
minimum versions, and updater ownership. Update this contract and its regression
tests if any supported seam changes.
