# Mise Toolchain Management Plan

## Goal

Replace baked language runtimes and agent harnesses with user-installable,
project-aware tooling managed by [mise](https://mise.jdx.dev/).

The result should provide:

- a smaller default image;
- project-specific tool versions without image rebuilds;
- installations that persist across container recreation;
- automatic installation of project-declared tools;
- explicit installation of supported agent harnesses;
- an offline-safe T3 server and setup surface;
- equivalent behavior on `linux/amd64` and `linux/arm64`.

`linux/amd64` and `linux/arm64` both remain supported, published targets, and
every image must still build for both. Test and verification evidence is
collected on `linux/amd64` only: `linux/arm64` is expected to behave
analogously, so it is not separately smoke-tested or required as evidence, and
nothing in this effort is blocked on arm64 hardware or CI.

This is developed end-to-end on a fork, then proposed to
`dizys/t3code-docker` as one coherent upstream pull request. The upstream remote
remains read-only. If the change is not accepted upstream, the fork remains a
maintained distribution of this product model.

## Settled Product Decisions

- `latest` eventually points to `core`.
- `browser` is `core` plus Chromium, fonts, Playwright MCP, and Chrome DevTools
  MCP.
- No language-specific `full` or compatibility image remains after the switch.
- Historical `slim` and `full` artifacts remain in the registry, but those tags
  stop receiving updates.
- No agent harness executable ships in the final images.
- Claude, Codex, OpenCode, Grok, and Cursor are installable through the setup UI
  and a noninteractive CLI.
- Antigravity is out of scope because T3 requires a separate managed ACP runtime,
  not the mise-managed `agy` CLI.
- Project-declared tools may install automatically.
- No undeclared global command stubs ship initially.
- Installed personal tools and harnesses never update during ordinary command
  invocation.
- The whole `/home/t3` volume is required for durable toolchains.
- Normal agent work may trust and execute repository mise configuration. Docker
  isolation is the primary security boundary; `MISE_SAFE=1` remains available
  for inspection-only work.
- Compatibility is more important than removing small, useful OS packages.
- System package installation and `T3_ALLOW_SUDO` are outside this effort.

## Architecture Contract

### Image Targets

The final image inventory is authoritative:

| Capability | `core` / `latest` | `browser` |
| --- | :---: | :---: |
| T3, setup UI, image Node, Python, Git/SSH, `gh`, `cloudflared` | Yes | Yes |
| mise and project toolchain support | Yes | Yes |
| Agent harness installer/catalogue | Yes | Yes |
| Agent harness executables | No | No |
| Existing base utilities and diagnostics | Yes | Yes |
| `build-essential`, clang, lld, CMake, `pkg-config`, GDB | Yes | Yes |
| ffmpeg, ImageMagick, PostgreSQL client, Redis tools | Yes | Yes |
| Go, Rust, Bun, Deno, uv | Via mise | Via mise |
| Project-specific Node, Python, Java, Ruby, .NET, Elixir, PHP, Zig, and other mise tools | Via mise | Via mise |
| Chromium, fonts, browser MCP servers | No | Yes |

Preserve the existing OS package set during the initial migration. Add
`ninja-build`, MySQL/MariaDB clients, or extra development headers only when a
real compatibility failure demonstrates the need. Package removal belongs in a
separate measured PR.

For `core`, "preserve the existing OS package set" means the union of the
current base packages and current `full` non-browser packages. Chromium, fonts,
and browser MCP packages move only to `browser`. MySQL/MariaDB tooling is a
possible addition, not part of the current inventory.

### Infrastructure Isolation

T3 and setup must not run through project or user mise shims.

The implementation must:

- keep the image Node and T3 installation root-owned and immutable at runtime;
- stop using the same writable npm prefix for T3 infrastructure and user global
  packages;
- launch setup with the absolute image Node path;
- launch T3 by passing its entry module to the absolute image Node path rather
  than relying on an `env node` shebang;
- update setup helpers and administrative paths that invoke `t3` by name;
- remove or scope the current process-wide `NPM_CONFIG_PREFIX=/opt/npm-global`
  so project npm cannot modify T3's installation.

The exact immutable T3 path should be discovered during implementation rather
than hard-coded in this plan.

### User Tool Environment

Runtime installations execute as `t3` and use the persistent home:

```text
MISE_CONFIG_DIR=/home/t3/.config/mise
MISE_DATA_DIR=/home/t3/.local/share/mise
MISE_STATE_DIR=/home/t3/.local/state/mise
MISE_CACHE_DIR=/home/t3/.cache/mise
```

Interactive T3 terminals activate mise. Noninteractive project commands use an
explicit mise boundary:

```sh
mise exec -- <command>
mise run <task>
```

Entrypoint exports only affect its descendants. They do not configure an
independent `docker exec`. Therefore:

- raw `docker exec -u t3 <tool>` is not promised to select a project toolchain;
- documentation uses `docker exec -u t3 ... mise exec -- <tool>` for
  noninteractive project commands;
- root's default `HOME` and `PATH` never include user-controlled mise state;
- helpers that need mise drop privileges and set the user environment first.

Transparent tool selection inside T3 or a harness is supported only where the
upstream provider launcher exposes an executable override or another explicit
integration seam. The plan does not assume control over opaque subprocesses.

### Project Configuration

Projects may use:

- `mise.toml` and `mise.lock`;
- `.tool-versions`;
- mise-supported idiomatic files such as `.nvmrc`, `.python-version`,
  `rust-toolchain.toml`, `go.mod`, `global.json`, and `package.json` fields.

The end state enables every idiomatic integration supported by the pinned mise
release. Mise has no wildcard setting, so the image must generate and commit the
exact tool-ID allowlist from that release's registry. Refresh the list whenever
mise is upgraded.

Universal idiomatic detection is a deliberate product change and lands in its
own PR. Tests cover representative shared manifests, explicit-config
precedence, malformed files, and unsupported versions; they do not duplicate
mise's complete backend test suite.

Set `not_found_system_fallback = false`, but scope its guarantee correctly: it
only applies after execution reaches mise. A configured missing interpreter is
guaranteed to fail or install when invoked through `mise exec`, `mise run`, or a
known mise shim. Direct PATH resolution that bypasses mise is outside that
guarantee.

### Persistence And Ownership

The supported durable configuration mounts all of `/home/t3`. Mounting only
`/home/t3/.t3` preserves T3 state and credentials but not installed tools,
global mise selections, or trust state.

Diagnostics may report the observed mount layout, but cannot guarantee that an
operator will reuse the volume on the next container.

UID/GID remapping currently recursively changes ownership under `/home/t3`.
With large toolchains this can be slow, and interruption can leave a partially
migrated tree. Before runtime installs ship, ownership migration needs a marker
or equivalent completion mechanism so an interrupted migration retries on the
next start.

### Harness Management

The harness catalogue contains exactly:

- Claude Code;
- Codex;
- OpenCode;
- Grok;
- Cursor.

One harness-management module backs both the existing Agents card and a small
noninteractive CLI. Do not add a setup wizard.

The module owns:

- catalogue metadata and architecture support;
- installed selections and exact resolved versions;
- concrete executable resolution;
- Install, Update, and Uninstall operations;
- configured, installed, runnable, authenticated, and failed states.

Install defaults to the latest available version, resolves it to an exact
version, and records that exact version. The CLI may accept an explicit version.
Update is always explicit. Uninstall removes the harness selection and managed
executable but preserves credentials and user data.

Before implementing this module, audit the pinned T3 release for each provider's
executable discovery, launch path, status probe, minimum version, and update
behavior. Setup polling and T3 provider discovery must never trigger an
installation or update.

The integration must define one source of truth for executable selection. If T3
cannot accept managed executable paths or cannot disable/redirect its native
provider updater, that is an upstream blocker rather than something to work
around with PATH tricks.

Cursor currently has inconsistent names: the image installs and setup probes
`cursor-agent`, while `t3-login` invokes `agent`. Audit whether the upstream
installer still supplies that alias, choose one canonical managed executable,
and preserve an alias only if current behavior demonstrably depends on it.

During transition, baked and managed harnesses coexist. Status must distinguish
them, and Uninstall must not claim the provider is absent while a baked fallback
still exists. Baked harnesses are removed only in the final product switch.

### Offline Contract

Offline-safe means:

- T3 and setup become healthy without external network access;
- local project registration, pairing/session inspection, and cached status
  remain responsive;
- provider catalogue and status endpoints return cached or bundled fallback
  data without waiting on external fetches;
- startup and status polling do not install or update tools.

External provider sign-in, first-time tool downloads, tunnels, and remote API
checks are not expected to work offline. Tests must distinguish those operations
from local health instead of treating "offline" as one broad guarantee.

Under `--network none`, authenticated `/status` and `/providers` requests should
each complete within five seconds on CI hardware. If current probes cannot meet
that budget, serve cached/bundled state first and refresh asynchronously when
network access is available.

### Version Policy

| Scope | Policy |
| --- | --- |
| mise | Exact version and verified release artifact |
| T3 and image infrastructure | Existing image policy, documented honestly where the Node base tag, apt packages, and `gh` float |
| Project tools | Project declarations; lockfile recommended for reproducibility |
| Personal tools | Resolve and record an exact version on explicit install |
| Harnesses | Resolve and record an exact version on explicit Install/Update |

A lockfile improves resolution and verification but is not an offline artifact
store. Do not claim fully reproducible installation for backends that lack
checksums, stable artifacts, or locked dependencies.

The transitional old targets also contain an unversioned Cursor installer,
rolling Rust `stable`, and unpinned Bun, Deno, and uv installers. Baseline
measurements and release notes must not describe those targets as reproducible.

For personal global tools, documentation must resolve `latest` to a concrete
version before writing the global selection, using the pinned mise release's
supported pinning mechanism. If that mechanism cannot be verified, narrow the
promise to "no automatic update is initiated by this image."

## Fork Implementation Milestones

These are implementation milestones on one fork feature branch, not separate
upstream pull requests. Keep each milestone as one or more focused commits so
the final change remains reviewable and bisectable. Keep unrelated cleanup out
of the branch.

### Milestone 1: Mise Foundation

Add mise without removing tools or changing published targets.

- Pin and verify one mise release.
- Separate immutable T3 infrastructure from mutable user package locations.
- Launch T3 and setup through the absolute image Node path.
- Update smoke-test minimum-version inspection so it discovers the immutable T3
  bundle path instead of assuming `/opt/npm-global`.
- Add the persistent mise directories and interactive shell activation.
- Document explicit `mise exec` for noninteractive project commands.
- Add one locked dual-architecture project fixture.
- Test fresh-home installation, missing-version failure through mise, offline
  recreation with the same volume, root isolation, and interrupted ownership
  migration recovery.
- Extend `t3-doctor` with mise paths, active configuration, installed tools, and
  observed persistence information.
- Record baseline compressed size, unpacked size, and startup timing.

Acceptance criteria:

- Current `slim` and `full` behavior remains intact.
- T3 and setup always use the image Node, even inside a project selecting another
  Node version.
- Project npm cannot modify the T3 installation.
- Root commands do not resolve user mise shims or create root-owned mise state.
- Native amd64 CI passes; arm64 builds but is not smoke-tested.

### Milestone 2: Idiomatic Project Detection

Enable the complete generated idiomatic-file allowlist from the pinned mise
registry.

- Commit the generated allowlist and its generation/update procedure.
- Enable project auto-install on explicit mise execution paths.
- Set `not_found_system_fallback = false`.
- Add representative precedence, malformed-manifest, unsupported-version, and
  offline tests.
- Document how a project overrides or disables an idiomatic detector.

Acceptance criteria:

- Existing standard project version files select the expected tool.
- Explicit `mise.toml` or `.tool-versions` wins according to mise precedence.
- Direct commands that bypass mise are not documented as guaranteed.

### Milestone 3: Harness Management

Add the shared harness module, setup UI actions, and CLI while keeping baked
harnesses as transition fallbacks.

- Complete the T3 provider discovery/update audit first.
- Install mise-managed harnesses into persistent user storage.
- Resolve and record exact versions.
- Add Install, Update, and Uninstall to the existing Agents card.
- Add equivalent noninteractive CLI commands.
- Preserve credentials on Uninstall.
- Resolve the current Cursor `cursor-agent`/`agent` inconsistency.
- Test actual T3 discovery and session launch, not only setup status.

Acceptance criteria:

- Setup and T3 resolve the same managed executable.
- Polling never installs or updates a harness.
- Managed versions survive container recreation.
- Transitional baked fallback state is represented honestly.
- If T3 cannot support explicit managed paths or coherent updates, stop and take
  the required change upstream before continuing.

### Milestone 4: Add `core` And `browser`

Add the new targets alongside `slim` and `full`.

- `core` follows the authoritative package table and omits baked runtimes and
  harnesses.
- `browser` adds Chromium, fonts, and both MCP servers.
- Validate Go, Rust, Bun, Deno, uv, and representative Node/Python versions
  through mise on native amd64.
- Verify Rust includes the currently promised `clippy` and `rustfmt` components.
- Update smoke tests to select capabilities explicitly rather than inferring
  them from the presence of Chromium.
- Measure image and persistent tool installation sizes.
- Fix release artifact promotion so the digest receiving release tags is the
  digest that passed smoke tests, or smoke-test the pushed digest before tagging.

Acceptance criteria:

- New targets pass their complete contracts while old targets remain unchanged.
- Browser probes drive real pages.
- `t3-browser-mcp` registers the installed MCP server with managed Claude,
  Codex, and OpenCode harnesses and produces valid configuration.
- Published-artifact identity is proven.

### Milestone 5: Product Switch

Perform the breaking product change atomically.

- Point `latest` and Compose defaults at `core`.
- Publish `core` and `browser` only.
- Stop updating `slim` and `full`; leave historical artifacts available.
- Remove baked language runtimes and harnesses with the old target definitions.
- Update build scripts, CI matrices, release tags, documentation, examples, and
  smoke tests in the same PR.
- Publish migration notes covering `/home/t3` persistence, explicit project
  execution, harness installation, and the new tags.

Acceptance criteria:

- A fresh `core` install can install and launch every supported harness.
- The documented representative runtime set installs and runs without an image
  rebuild on amd64; other mise-supported tools remain best-effort according to
  their backend and system dependency requirements.
- No documentation claims removed tools are preinstalled.
- Release CI reports compressed and unpacked size changes against the old
  `slim` and `full` baselines.

## Test Scope

Keep integration tests focused on behavior owned by this repository:

- infrastructure Node/T3 isolation;
- explicit project execution through mise;
- whole-home persistence and UID/GID ownership recovery;
- representative built-in, registry, npm, and language-package backends actually
  used by migrated tools;
- managed harness lifecycle and actual T3 provider launch;
- offline local health and bounded status responses;
- native amd64 builds (arm64 is built for publication but not smoke-tested);
- exact release artifact promotion;
- real Chromium and MCP operation in `browser`.

Do not reproduce mise's complete backend test suite or require benchmarks for
every possible tool.

## Upstream Delivery

Repository setup:

1. Create or select a GitHub fork.
2. Configure the fork as writable `origin`.
3. Configure `https://github.com/dizys/t3code-docker` as read-only `upstream`.
4. Create one feature branch from the latest upstream default branch.
5. Synchronize with upstream before final verification and again before opening
   the ready-for-review PR.

Upstream strategy:

1. Implement and verify the complete suite on the fork.
2. Optionally open a draft PR early, after Milestone 1 or 2, to make the
   direction visible and collect maintainer constraints. Do not ask for merge
   while the product contract is incomplete.
3. Present one ready-for-review PR containing the complete `core`/`browser`,
   mise, harness-management, persistence, CI, documentation, and migration
   change.
4. Keep commits organized by the milestones above so the maintainer can review
   the architecture incrementally or request a split without losing the
   end-to-end demonstration.
5. Offer to split or squash only if the upstream maintainer requests it.
6. If upstream declines the product direction, continue maintaining the fork
   rather than carrying a partial upstream integration.

The upstream PR description should include:

- the user-visible problem it solves;
- what intentionally remains unchanged;
- architecture and persistence implications;
- verification performed on amd64 (arm64 remains supported and published, but is
  not separately tested);
- measured image-size impact where relevant;
- migration or rollback considerations.

Lead with the visible outcome: materially smaller default image, installable
project toolchains and harnesses, persistent versions, and a tested browser
variant. Include before/after size and workflow evidence so the benefit does not
depend on the maintainer mentally composing several future changes.

Do not commit or push directly to upstream.
