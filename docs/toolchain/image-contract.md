# Image Contract: `core` And `browser`

`core` and `browser` are the final product targets; the historical
`slim`/`full` targets are no longer built. This is the authoritative
package contract for what the image contains and what it deliberately does not.

Migration from `slim`/`full` is in [`migration.md`](./migration.md).

## Target profiles

Two targets build from one `Dockerfile`. `core` is the default and backs
`:latest`; `browser` adds eyes.

| Capability | `core` (default) | `browser` |
| --- | :---: | :---: |
| T3 platform binary, setup UI/image Node, Python, Git/SSH, `gh`, `cloudflared` | Yes | Yes |
| mise and project toolchain support | Yes | Yes |
| Agent harness installer/catalogue (`t3-harness`, `/opt/t3-harness`, `/opt/t3-provider`) | Yes | Yes |
| Agent harness executables (baked) | No | No |
| Existing base utilities and diagnostics | Yes | Yes |
| `build-essential` (base) + `clang`, `lld`, `cmake`, `pkg-config`, `gdb` | Yes | Yes |
| `ffmpeg`, ImageMagick, PostgreSQL client, Redis tools | Yes | Yes |
| Go, Rust, Bun, Deno, uv (baked) | No (via mise) | No (via mise) |
| Project Node/Python/Java/Ruby/.NET/Elixir/PHP/Zig via mise | Via mise | Via mise |
| Chromium, fonts, browser MCP servers | No | Yes |

"Preserve the existing OS package set" for `core` means the union of the old
base packages and the old `full` non-browser packages. Chromium, fonts, and
browser MCP packages move only to `browser`. `ninja-build`, MySQL/MariaDB
clients, and extra headers remain possible additions, not part of this
inventory.

Build:

```sh
scripts/build.sh                      # t3code:core (default)
scripts/build.sh --target browser     # t3code:browser
```

## Package locations

| What | Where | Which targets |
| --- | --- | --- |
| Base OS (`git`, `python3`, `build-essential`, `gh`, `cloudflared`, `mise`, user hook) | apt + `/usr/local/bin/mise` + `/etc/mise/config.toml` + `/etc/profile.d/t3-user-env.sh` | both |
| Non-browser union (`clang`, `lld`, `cmake`, `pkg-config`, `gdb`, `ffmpeg`, `imagemagick`, `postgresql-client`, `redis-tools`) | apt (`dpkg -l`) | both |
| T3 infrastructure | `/opt/t3` (`root:root`, `go-w`), `/usr/local/bin/t3-admin`, `/opt/t3-setup`, `/opt/t3-provider`, `/opt/t3-harness` | both |
| Browser (`chromium`, `fonts-*`) | apt + `/usr/bin/chromium`, `CHROME_PATH`/`CHROME_BIN` et al. | `browser` only |
| Browser MCP (`playwright-mcp`, `chrome-devtools-mcp`) | `/opt/npm-global/bin` (`t3:t3`) | `browser` only |
| Managed harnesses/runtimes | `/home/t3/.local/share/mise/installs/*` + `/home/t3/.cargo`, `/home/t3/.rustup` (persistent home) | installed at runtime on both |
| User npm globals | `/opt/npm-global` via `/home/t3/.npmrc` (`prefix=/opt/npm-global`) | both (empty except MCP on `browser`) |

Neither target bakes a harness: there is no
`/opt/npm-global/bin/{claude,codex,opencode,grok}`, no
`/opt/cursor/.local/bin/cursor-agent`, and no such binary on root `PATH` (root
has no mise shims by design, so a bare lookup only finds a bake). `browser`
adds only browser capability on top of `core`.

Stages: `core` builds `FROM base`; `browser` builds `FROM core`. There is no
transitional stage above `base` to leak tools, and the removed `slim`/`full`
definitions no longer exist in the `Dockerfile`.

MCP relocation does not break Node resolution: `browser` installs the two MCP
pins into the same mutable prefix (`/opt/npm-global`) with the
`CHROME_*`/`PLAYWRIGHT_*` env, and `t3-browser-mcp --print` produces the server
commands. The registration path with managed harnesses is proven by
`scripts/test-provider-integration.sh` on the browser image.

## Runtime backends

Both targets provide Go/Rust/Bun/Deno/uv and project Node/Python via mise, not
baked. `scripts/test-runtime-matrix.sh` installs one representative selector per
runtime through an explicit `mise exec` boundary on native amd64 and proves each
runs a minimal program. Rust must include the currently promised `clippy` and
`rustfmt` components.

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

| Runtime | mise backend | Probe |
| --- | --- | --- |
| Node | `node` (core) | `node --version` + `node -e` |
| Python | `python` (core, `python-build-standalone`) | `python --version` + `python -c` + file |
| Go | `go` (core) | `go version` + `go run main.go` |
| Rust | `rust` (core, via `rustup`) | `rustc --version`, `cargo --version`, `cargo clippy --version`, `cargo fmt --version`, `cargo clippy` + `cargo fmt` on a new crate |
| Bun | `bun` (core) | `bun --version` |
| Deno | `deno` (core) | `deno --version` |
| uv | `uv` (aqua `astral-sh/uv`) | `uv --version` |

```sh
scripts/test-runtime-matrix.sh t3code:core    # 19 assertions, amd64 only
```

This does not duplicate mise's backend suite: it proves the image's mise can
provide the toolchains the old `full` target used to bake, with the promised
Rust components, through the documented explicit boundary.

## Browser probes

`browser` must drive real pages, not just carry a binary.
`scripts/browser-probe.py` starts the MCP server over stdio, does the
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
Codex, and OpenCode harnesses and produces valid configuration. That path with
managed installs is proven by `scripts/test-provider-integration.sh` on the
browser image, not by smoke alone:

```sh
scripts/test-provider-integration.sh t3code:core t3code:browser
# browser image sync applied three harnesses,
# each registers "via /home/t3/.local/share/mise/installs/...",
# codex/opencode configs record the mcp server
```

## Size evidence

Measured on native amd64 via `scripts/measure-image.sh`; compressed is a gzipped
`docker save`, unpacked is the sum of uncompressed layers, and startup is
`docker run` to the first `/.well-known/t3/environment` response:

| Target | Compressed | Unpacked | Startup |
| --- | ---: | ---: | ---: |
| `slim` (historical baseline, published `v0.4.5`) | 1.10 GiB | 2.94 GiB | ~3.2 s |
| `full` (historical baseline, published `v0.4.5`) | 1.95 GiB | 5.19 GiB | ~3.2 s |
| `core` | 0.69 GiB (745,217,028 B) | 2.03 GiB (2,179,749,376 B) | 3.66 s |
| `browser` | 0.97 GiB (1,043,181,614 B) | 2.63 GiB (2,825,801,216 B) | 3.65 s |

`core` is ~36% smaller compressed than the historical `slim` while carrying
the non-browser union; `browser` is ~50% smaller compressed than the historical
`full` while carrying Chromium/fonts/MCP. Startup stays around 3-4 s on both.
The release artifact identity and promotion contract are documented in
[`ci-evidence.md`](./ci-evidence.md).

Example persistent-install sizes from the same native amd64 measurement:

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
```

`core`/`browser` pin T3 and both MCP servers (`bump-versions.sh` keeps the pins
in sync); harnesses and project/personal tools resolve exact versions at
install time but are not offline artifact stores. The images must not be
described as fully reproducible: the Node base tag, apt packages, and `gh`
float.

## Verification

```sh
scripts/build.sh --target core --tag t3code:core
scripts/build.sh --target browser --tag t3code:browser

scripts/test-image-inventory.sh --variant core t3code:core
scripts/test-image-inventory.sh --variant browser t3code:browser

scripts/smoke-test.sh --variant core t3code:core
scripts/smoke-test.sh --variant browser t3code:browser
# digest refs require an explicit variant:
#   scripts/smoke-test.sh --variant core t3code@sha256:<digest>
#   scripts/test-image-inventory.sh --variant browser t3code@sha256:<digest>

scripts/test-runtime-matrix.sh t3code:core
scripts/test-provider-integration.sh t3code:core t3code:browser
scripts/test-toolchain-e2e.sh --variant core t3code:core
scripts/test-toolchain-e2e.sh --variant browser t3code:browser
scripts/measure-image.sh core browser
```

Capability selection is explicit (`--variant`), never inferred from the
presence of Chromium. `test-image-inventory.sh` asserts the package union and
the absence of baked tools; `smoke-test.sh` boots each variant and asserts its
profile (installer + mise everywhere, browser probes on `browser`);
`test-runtime-matrix.sh` proves mise provides the seven runtimes with
`clippy`/`rustfmt`; `test-toolchain-e2e.sh` proves the assembled product end to
end (harness install/launch/recreate including offline, project toolchain vs
image infrastructure, managed browser MCP).

Fresh images honestly report harness `signedIn: null` (unknown) when no
executable is installed to probe — even with an env-var credential or a stored
OpenCode key on disk. The file writes themselves are smoke-proven; the True
flip with a managed install and the managed browser-MCP registration are E2E.
