# Image Contract: `core` And `browser`

TM-10 deliverable. Additive `core` and `browser` targets satisfy the final
package contract while transitional `slim`/`full` remain unchanged.

The canonical product contract is
[`TOOLCHAIN-MANAGEMENT-PLAN.md`](../../TOOLCHAIN-MANAGEMENT-PLAN.md). The
transitional baseline is [`baseline.md`](./baseline.md).

## Target profiles

Four targets build from one `Dockerfile`. `slim`/`full` are transitional and
stop receiving updates after the product switch (TM-13). `core`/`browser` are
final. `latest` and Compose defaults still point at `full`; changing them is
TM-13, not here.

| Capability | `slim` (transitional) | `full` (transitional) | `core` (final) | `browser` (final) |
| --- | :---: | :---: | :---: | :---: |
| T3, setup UI, image Node, Python, Git/SSH, `gh`, `cloudflared` | Yes | Yes | Yes | Yes |
| mise and project toolchain support | Yes | Yes | Yes | Yes |
| Agent harness installer/catalogue (`t3-harness`, `/opt/t3-harness`, `/opt/t3-provider`) | Yes | Yes | Yes | Yes |
| Agent harness executables (baked) | Yes | Yes | No | No |
| Existing base utilities and diagnostics | Yes | Yes | Yes | Yes |
| `build-essential` (base) + `clang`, `lld`, `cmake`, `pkg-config`, `gdb` | `build-essential` only | Yes | Yes | Yes |
| `ffmpeg`, ImageMagick, PostgreSQL client, Redis tools | No | Yes | Yes | Yes |
| Go, Rust, Bun, Deno, uv (baked) | No | Yes | No (via mise) | No (via mise) |
| Project Node/Python/Java/Ruby/.NET/Elixir/PHP/Zig via mise | Via mise | Via mise | Via mise | Via mise |
| Chromium, fonts, browser MCP servers | No | Yes | No | Yes |

For `core`, "preserve the existing OS package set" means the union of the
current base packages and current `full` non-browser packages. Chromium,
fonts, and browser MCP packages move only to `browser`. `ninja-build`,
MySQL/MariaDB clients, and extra headers are possible additions, not part of
this inventory.

Build:

```sh
scripts/build.sh --target slim     # t3code:slim
scripts/build.sh --target full     # t3code:full (still the default)
scripts/build.sh --target core     # t3code:core
scripts/build.sh --target browser  # t3code:browser
```

## Package locations

| What | Where | Which targets |
| --- | --- | --- |
| Base OS (`git`, `python3`, `build-essential`, `gh`, `cloudflared`, `mise`, user hook) | apt + `/usr/local/bin/mise` + `/etc/mise/config.toml` + `/etc/profile.d/t3-user-env.sh` | all four |
| Non-browser union (`clang`, `lld`, `cmake`, `pkg-config`, `gdb`, `ffmpeg`, `imagemagick`, `postgresql-client`, `redis-tools`) | apt (`dpkg -l`) | `full`, `core`, `browser` only |
| T3 infrastructure | `/opt/t3` (`root:root`, `go-w`), `/usr/local/bin/t3-admin`, `/opt/t3-setup`, `/opt/t3-provider`, `/opt/t3-harness` | all four |
| Baked harnesses (`claude`, `codex`, `opencode`, `grok`) | `/opt/npm-global/bin` (`t3:t3`) | `slim`, `full` only |
| Baked Cursor (`cursor-agent`) | `/opt/cursor/.local/bin` (`t3:t3`) | `slim`, `full` only |
| Baked Go | `/usr/local/go` + `PATH` | `full` only |
| Baked Rust (+`clippy`, `rustfmt`) | `/usr/local/rustup`, `/usr/local/cargo` + `PATH` | `full` only |
| Baked Bun/Deno | `/usr/local/bun`, `/usr/local/deno` + `PATH` | `full` only |
| Baked uv | `/usr/local/bin/uv` | `full` only |
| Browser (`chromium`, `fonts-*`) | apt + `/usr/bin/chromium`, `CHROME_PATH`/`CHROME_BIN` et al. | `full`, `browser` only |
| Browser MCP (`playwright-mcp`, `chrome-devtools-mcp`) | `/opt/npm-global/bin` (`t3:t3`) | `full`, `browser` only |
| Managed harnesses/runtimes | `/home/t3/.local/share/mise/installs/*` + `/home/t3/.cargo`, `/home/t3/.rustup` (persistent home) | installed at runtime on `core`/`browser` (and usable on `slim`/`full`) |
| User npm globals | `/opt/npm-global` via `/home/t3/.npmrc` (`prefix=/opt/npm-global`) | all four (empty on fresh `core`/`browser` except MCP on `browser`) |

`core`/`browser` contain no baked harness: no
`/opt/npm-global/bin/{claude,codex,opencode,grok}`, no
`/opt/cursor/.local/bin/cursor-agent`, and no such binary on root `PATH`
(root has no mise shims by design, so a bare lookup only finds a bake).
`browser` adds only browser capability on top of `core`: Chromium/fonts/MCP,
no baked runtimes or harnesses.

Stage inheritance cannot leak baked tools: `core` builds `FROM base`, not
`FROM slim`; `browser` builds `FROM core`. `slim`/`full` are preserved above
unchanged so the old chain stays byte-identical in behavior while the new
chain evolves independently. TM-13 removes `slim`/`full` and deduplicates.

MCP relocation does not break Node resolution: both `full` and `browser`
install the same two MCP pins into the same mutable prefix
(`/opt/npm-global`) with the same `CHROME_*`/`PLAYWRIGHT_*` env, and
`t3-browser-mcp --print` produces the same server commands on both. The
registration path with managed harnesses is proven by
`scripts/test-provider-integration.sh` on the browser image.

## Runtime backends

`core`/`browser` provide Go/Rust/Bun/Deno/uv and project Node/Python via
mise, not baked. `scripts/test-runtime-matrix.sh` installs one representative
selector per runtime through an explicit `mise exec` boundary on native amd64
and proves each runs a minimal program. Rust must include the currently
promised `clippy` and `rustfmt` components.

Representative selectors (in the script; exact patches float and are recorded
per run):

```toml
[tools]
node = "22"
python = "3.12"
go = "1.27"
rust = "1.82"
bun = "1.2"
deno = "2"
uv = "latest"
```

Verified 2026-09-17 on `t3code:core` (native amd64, `mise 2026.9.10`):

| Runtime | mise backend | Resolved | Probe |
| --- | --- | --- | --- |
| Node | `node` (core) | `22.23.2` | `node --version` + `node -e` |
| Python | `python` (core, `python-build-standalone`) | `3.12.14` | `python --version` + `python -c` + file |
| Go | `go` (core) | `1.27.1` (matches baked `GO_VERSION`) | `go version` + `go run main.go` |
| Rust | `rust` (core, via `rustup`) | `1.82.0` | `rustc --version`, `cargo --version`, `cargo clippy --version`, `cargo fmt --version`, `cargo clippy` + `cargo fmt` on a new crate |
| Bun | `bun` (core) | `1.2.23` | `bun --version` |
| Deno | `deno` (core) | `2.9.6` | `deno --version` |
| uv | `uv` (aqua `astral-sh/uv`) | `0.12.15` | `uv --version` |

```sh
scripts/test-runtime-matrix.sh t3code:core    # 19 assertions, amd64 only
```

This does not duplicate mise's backend suite: it proves the image's mise can
provide the toolchains `full` used to bake, with the promised Rust
components, through the documented explicit boundary.

## Browser probes

`browser` (and transitional `full`) must drive real pages, not just carry a
binary. `scripts/browser-probe.py` starts the MCP server over stdio, does the
`initialize` handshake, lists tools, serves a local page, and navigates to it
via `browser_navigate` (playwright) or `new_page` (chrome-devtools). Chromium
itself is proven by rendering real markup to DOM and by screenshotting to a
non-trivial PNG.

```sh
scripts/smoke-test.sh --variant browser t3code:browser
# chromium renders a page, screenshots a page,
# browser MCP drives a real page (playwright),
# browser MCP drives a real page (chrome-devtools),
# t3-browser-mcp prints both servers
```

`t3-browser-mcp` registers the installed MCP server with managed Claude,
Codex, and OpenCode harnesses and produces valid configuration. That path
with managed installs is proven by `scripts/test-provider-integration.sh`
(browser image + managed installs), not by smoke alone:

```sh
scripts/test-provider-integration.sh t3code:slim t3code:browser
# browser image sync applied three harnesses,
# each registers "via /home/t3/.local/share/mise/installs/...",
# codex/opencode configs record the mcp server
```

## Size evidence

Measured 2026-09-17 on native amd64 via `scripts/measure-image.sh`
(compressed = gzipped `docker save`, unpacked = sum of uncompressed layers,
startup = `docker run` to first `/.well-known/t3/environment`):

| Target | Compressed | Unpacked | Startup | Digest (local, amd64) |
| --- | ---: | ---: | ---: | --- |
| `slim` (baseline `v0.4.5` rebuilt) | 1.10 GiB | 2.98 GiB | ~3.2 s | — (see `baseline.md`) |
| `full` (baseline `v0.4.5` rebuilt) | 1.97 GiB | 5.25 GiB | ~3.2 s | — |
| `core` | 720 MiB (0.70 GiB) | 2.03 GiB | 3.86 s | `sha256:8cbea366345dca53e128c8c08c5ca68a226173a6991c89453a342affe742a056` (`t3code:core`) |
| `browser` | 1005 MiB (0.98 GiB) | 2.63 GiB | 3.74 s | `sha256:c171832969d1f1cec6af8387de853f53a24190836eb343ea678adb0ef1f17da9` (`t3code:browser`) |

`core` is ~35% smaller compressed than `slim` (no baked harnesses) while
carrying the non-browser union; `browser` is ~50% smaller compressed than
`full` (no baked runtimes/harnesses) while carrying Chromium/fonts/MCP.
Startup stays ~3-4 s on all four. Unpacked totals match the registry method in
`baseline.md` to within re-compression noise.

Persistent installs (from the runtime matrix above, same run):

| Location | Size |
| --- | ---: |
| `/home/t3/.local/share/mise` | 819 MiB (`node` 199, `python` 107, `go` 275, `bun` 100, `deno` 92, `uv` 48, `rust` shim 20K) |
| `/home/t3/.cargo` | 21 MiB |
| `/home/t3/.rustup` (1.82.0 + `clippy`/`rustfmt`) | 1.3 GiB |

All seven representative runtimes together cost ~2.1 GiB in the persistent
home, surviving recreation via the whole-`/home/t3` mount. A single toolchain
costs what its backend needs (e.g. Go 275 MiB, Node 199 MiB).

```sh
scripts/measure-image.sh core browser
scripts/measure-image.sh --no-startup slim full core browser
```

Do not describe transitional `slim`/`full` as reproducible (see
[`baseline.md`](./baseline.md) floating inputs). `core`/`browser` pin `T3`
and both MCP servers like `slim`/`full` (`bump-versions.sh` keeps all four
pins in sync); project/personal tools resolve exact versions at install time
but are not offline artifact stores.

## Verification

```sh
scripts/build.sh --target slim --tag t3code:slim
scripts/build.sh --target full --tag t3code:full
scripts/build.sh --target core --tag t3code:core
scripts/build.sh --target browser --tag t3code:browser

scripts/test-image-inventory.sh --variant slim t3code:slim
scripts/test-image-inventory.sh --variant full t3code:full
scripts/test-image-inventory.sh --variant core t3code:core
scripts/test-image-inventory.sh --variant browser t3code:browser

scripts/smoke-test.sh --variant slim t3code:slim
scripts/smoke-test.sh --variant full t3code:full
scripts/smoke-test.sh --variant core t3code:core
scripts/smoke-test.sh --variant browser t3code:browser
# digest refs require an explicit variant:
#   scripts/smoke-test.sh --variant core t3code@sha256:<digest>
#   scripts/test-image-inventory.sh --variant browser t3code@sha256:<digest>

scripts/test-runtime-matrix.sh t3code:core
scripts/test-provider-integration.sh t3code:slim t3code:browser
scripts/measure-image.sh core browser
```

Capability selection is explicit (`--variant`), never inferred from the
presence of Chromium. `test-image-inventory.sh` asserts the package union and
the absence of baked tools; `smoke-test.sh` boots each variant and asserts its
profile (baked harnesses only on `slim`/`full`, baked runtimes only on `full`,
browser only on `full`/`browser`, installer + mise everywhere, real browser
probes on `full`/`browser`); `test-runtime-matrix.sh` proves mise provides the
seven runtimes with `clippy`/`rustfmt`.

Known drift at verification (2026-09-17, `bump-versions.sh --check`):
`T3 0.0.40→0.0.42`, `claude-code 2.1.270→2.1.274`,
`opencode-ai 1.18.30→1.18.31`, `grok 1.0.30→1.0.34`,
`@playwright/mcp 0.0.80→0.0.81`. Smoke's pin-current check fails for all four
targets until the pins are refreshed; this is upstream drift, not a TM-10
regression. Refreshing pins is separate maintenance, not this ticket.

Fresh `core`/`browser` honestly report harness `signedIn: null` (unknown)
when no executable is installed to probe — even with an env-var credential or
a stored OpenCode key on disk. The file writes themselves are smoke-proven;
the True flip with a managed install and the managed browser-MCP registration
are E2E (TM-12), not smoke.

## Handoff

- **TM-11 (native CI and tested-digest promotion):** wire all four targets
  for amd64/arm64 builds with native amd64 smoke/inventory/runtime/browser
  checks by capability; gate promotion on exact-reference (`--variant` +
  digest) smoke; keep official `slim`/`full`/`latest` tags unchanged.
- **TM-12 (transitional verification E2E):** fresh `core` installs all five
  harnesses, launches each through T3, survives recreation, uninstalls
  cleanly; managed browser-MCP registration drives real pages; record Cursor
  self-update drift separately.
- **TM-13 (atomic switch):** point `latest`/Compose at `core`, publish
  `core`/`browser` only, remove baked runtimes/harnesses with old targets,
  update build/CI/docs/examples/smoke in one PR with migration notes and
  size deltas against the baselines above.

Risks carried forward: stage inheritance (mitigated by `FROM base`/`FROM
core`, proven by inventory); MCP relocation (same prefix/pins/env on
`full`/`browser`, proven by probes + provider-integration); floating pins
(recorded above, owned by maintenance, not TM-10).
