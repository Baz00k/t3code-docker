# Project Execution Through mise

The image ships one pinned mise release as immutable
infrastructure, keeps every tool it manages in the unprivileged user's
persistent home, and enables project-aware execution without widening root's
environment. This note records the pin and its provenance, the persistent paths
and activation interface, the execution policy, the generated idiomatic
allowlist, and the limits of the "install or fail" promise.

The immutable infrastructure this builds on is
[`infrastructure.md`](./infrastructure.md).

## Pinned release

| | |
| --- | --- |
| Version | `2026.9.10`, `ARG MISE_VERSION` in the `Dockerfile` |
| Binary | `mise-v2026.9.10-linux-{x64,arm64}` (raw release asset) |
| Install path | `/usr/local/bin/mise`, `root:root`, mode `0755` |
| Checksums | [`docker/mise/SHA256SUMS`](../../docker/mise/SHA256SUMS) |
| Checksum source | `https://github.com/jdx/mise/releases/download/v2026.9.10/SHASUMS256.txt` |
| System config | [`docker/mise/config.toml`](../../docker/mise/config.toml) → `/etc/mise/config.toml` |

The Dockerfile selects the `x64`/`arm64` asset from `dpkg --print-architecture`,
downloads it, and verifies it against the committed checksum before installing.
No installer script runs. `/opt/mise/SHA256SUMS` and `/opt/mise/config.toml` are
also left in the image as an auditable record of what was installed.

The release is pinned, not tracked: a bump is one `ARG MISE_VERSION` edit plus
`scripts/generate-mise-idiomatic.sh`, which refreshes the checksums and the
generated allowlist from that exact release. CI runs the script with `--check`.

## Persistent paths

`docker/user-env.sh`, installed as `/etc/profile.d/t3-user-env.sh`, sets these
for the unprivileged user only:

| Role | Path |
| --- | --- |
| Config | `/home/t3/.config/mise` |
| Data (installs, shims, downloads) | `/home/t3/.local/share/mise` |
| State (trust) | `/home/t3/.local/state/mise` |
| Cache | `/home/t3/.cache/mise` |
| Shims | `/home/t3/.local/share/mise/shims` |
| Installed tools | `/home/t3/.local/share/mise/installs` |

The paths are explicit rather than left to mise's `XDG_*` defaults, so they do
not move when a user sets those variables, and they match what this note
documents. They are exported only from the user hook: root's `HOME` and `PATH`
never include them, and a root `mise` invocation uses `/root` and cannot read
the user's toolchains.

The supported durable mount is all of `/home/t3`. Mounting only
`/home/t3/.t3` preserves T3 state and credentials but not installed tools,
global selections, or the trust store. See
[`persistence.md`](./persistence.md) for the diagnostics that report this.

## Execution policy

`/etc/mise/config.toml` is the lowest-precedence config every user and every
`docker exec` reads. Personal (`~/.config/mise/config.toml`) and project
(`mise.toml`) configs override it. It carries:

| Setting | Value | Why |
| --- | --- | --- |
| `auto_install` | `true` | An explicit mise execution installs a declared, missing tool instead of using a system one. |
| `not_found_system_fallback` | `false` | A missing tool fails rather than silently running something from `PATH`. |
| `pin` | `true` | `mise use` records the resolved exact version, so a personal tool never floats and never updates on its own. |
| `idiomatic_version_file_enable_tools` | generated | The exact allowlist for the pinned release (below). |

`not_found_system_fallback = false` is scoped honestly: it currently governs
execution that reaches mise - a shim invocation, `mise exec`, `mise run`. It
does **not** govern a command that resolves straight through `PATH` without mise
involved, because mise never sees it. That is why documentation uses
`mise exec` for noninteractive project commands.

## Activation

One rule: the user environment is never process-wide.

- The entrypoint sources the hook before it launches anything, so the server,
  the setup service, and the terminals T3 opens as its children all inherit the
  `MISE_*` paths and the shims directory on `PATH`.
- Login shells get the same hook from `/etc/profile.d`.
- Interactive bash additionally evaluates `mise activate bash`, which keeps the
  tool environment current as the shell changes directory. The hook detects
  bash with `$BASH_VERSION` and interactive mode with `$-`, so `sh` shells and
  non-interactive contexts are unaffected.
- A bare `docker exec -u t3` does not run the hook, but still reaches
  `/usr/local/bin/mise` and, because `HOME=/home/t3`, mise's defaults resolve to
  the same persistent paths. It does not, however, put the project's tools on
  `PATH` - use `mise exec` (or the login shell) for that.

The hook returns early for uid 0, which is what keeps root free of user
toolchains.

## Idiomatic version files

mise disables idiomatic version files by default and has no wildcard for the
setting, so the image generates the exact allowlist from the pinned release's
registry: every tool entry with an `idiomatic_files` key. For mise 2026.9.10
that is 34 tools, from `atmos` through `zig`, including `node`, `python`, `go`,
`rust`, `ruby`, `java`, `dotnet`, `bun`, `deno`, `terraform`, `task`, and the
package managers that read `package.json`.

`scripts/generate-mise-idiomatic.sh` fetches the pinned release's source,
extracts the registry, and writes `docker/mise/config.toml`; `--check` fails if
the committed file no longer matches the pin. Because the allowlist is per
release, it must be regenerated whenever `MISE_VERSION` moves.

Detectors can be narrowed per project or per personal config:

```toml
[settings]
idiomatic_version_file_disable_files = ["node:package.json"]
idiomatic_version_file_enable_tools = ["node"]
```

A project `[settings]` block is not in mise's "safe config" set, so mise
requires the project to be trusted (`mise trust`) before it is read. Commands
that execute project behavior - `mise exec`, `mise install`, `mise run` - trust
their active config automatically; inspection commands such as `mise config ls`
do not. `MISE_SAFE=1` remains available for inspection-only work.

For `package.json`, mise reads `devEngines.runtime` for runtimes and
`devEngines.packageManager`/`packageManager` for package managers. It
deliberately ignores `engines`, which is a compatibility range rather than a
development pin. In this release, `go.mod`'s `go X.Y` directive and
`CMakeLists.txt`'s `cmake_minimum_required` are still read as a version but
warn and are removed in mise 2026.11.0.

## Lockfiles

A project can commit `mise.lock` next to `mise.toml`. It records the concrete
resolved version plus, where the backend supports it, per-platform URLs,
checksums, and provenance. One lockfile holds many platforms; the fixture at
`tests/fixtures/mise/locked` is locked for both build architectures:

```sh
mise lock --platform linux-x64,linux-arm64
mise install --locked
```

Locked installation is reproducible metadata, not an offline artifact store:
uncached artifacts and verification can still need network. Once a tool is
installed in the persistent home, it runs with no network at all, which is what
`scripts/test-mise.sh` proves on a reused home under `--network none`.

## Direct-PATH limitations

The contract covers execution through mise; it does not promise transparent
tool selection anywhere else:

- `docker exec -u t3 <tool>` without a login shell or `mise exec` is not
  guaranteed to select a project toolchain, because mise is not consulted.
- Transparent selection inside T3 or a harness is only promised where the
  provider launcher accepts an executable override (see
  [`provider-contract.md`](./provider-contract.md)); opaque subprocesses are outside
  this boundary.
- No global command stubs ship. Commands that bypass mise are not intercepted.

## Verification

```sh
scripts/generate-mise-idiomatic.sh --check
scripts/build.sh --target core
scripts/test-mise.sh t3code:core
scripts/test-infrastructure.sh t3code:core
scripts/smoke-test.sh t3code:core
```

`test-mise.sh` builds a fresh named volume and one offline container from the
same volume, and covers: the pinned version and committed checksum; root
isolation; the user paths, shims, interactive activation, and server
environment; idiomatic detection across representative files and `package.json`;
detector overrides; explicit-config precedence; `mise exec`, `mise run`, and
auto-install; malformed and impossible versions; the shim fallback setting; and
cached execution offline. Verification is amd64-only; arm64 is
built and published but not separately smoked.

`t3-doctor` reports these mise paths, and the trust store lives in the state
directory. Managed harness installs use the same persistent data directory and
provider launchers receive executables resolved through mise rather than a PATH
search. T3 treats mise-owned paths for the four non-Cursor providers as
manual-only for updates; Cursor's self-updater is the documented exception.
