# syntax=docker/dockerfile:1

# T3 Code, packaged as a headless server.
#
# Four targets (two transitional, two final):
#   slim    - TRANSITIONAL. T3 Code + baked agent harnesses + git/python.
#             Enough to drive a repo. Historical artifacts remain, but the tag
#             stops receiving updates after the product switch.
#   full    - TRANSITIONAL. slim + baked Go/Rust/C++/Bun/Deno toolchains,
#             ffmpeg, and a headless Chromium with browser-automation MCP
#             servers. The current default.
#   core    - FINAL. Base + full non-browser OS packages, image infrastructure,
#             mise, and the harness installer. No baked harness executables, no
#             baked language runtimes (Go/Rust/Bun/Deno/uv via mise), no browser.
#   browser - FINAL. core + Chromium, fonts, and both MCP servers.
#
# Build:  docker build --target browser -t t3code:browser .
# See README.md for the runtime contract and docs/toolchain/image-contract.md
# for the authoritative target profiles.

ARG NODE_IMAGE=node:24-trixie-slim

# ---------------------------------------------------------------------------
# base - OS packages, trust anchors, the unprivileged user
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS base

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Extra trust anchors. Drop PEM/CRT files into ca-certs/ to build behind a
# TLS-intercepting proxy; the directory ships empty and this is a no-op.
COPY ca-certs/ /usr/local/share/ca-certificates/extra/

# Debian's mirrors are reached over plain HTTP by default. Some proxies only
# relay CONNECT, so allow switching the sources to HTTPS at build time.
ARG APT_HTTPS=false

RUN set -eux; \
    find /usr/local/share/ca-certificates/extra -maxdepth 1 -type f \
         \( -name '*.crt' -o -name '*.pem' \) -exec cat {} + \
         > /usr/local/share/ca-certificates/extra-bundle.pem; \
    if [ -s /usr/local/share/ca-certificates/extra-bundle.pem ]; then \
      echo 'Acquire::https::CaInfo "/usr/local/share/ca-certificates/extra-bundle.pem";' \
          > /etc/apt/apt.conf.d/99-t3code-extra-ca; \
    else \
      rm -f /usr/local/share/ca-certificates/extra-bundle.pem; \
    fi; \
    if [ "$APT_HTTPS" = "true" ]; then \
      sed -i 's|http://deb.debian.org|https://deb.debian.org|g' \
          /etc/apt/sources.list.d/debian.sources; \
    fi

RUN set -eux; \
    apt-get -o Acquire::Retries=8 update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg \
        git git-lfs openssh-client \
        build-essential python3 python3-dev python3-venv pipx \
        tini gosu \
        jq ripgrep fd-find bat sqlite3 \
        unzip zip xz-utils \
        less nano vim-tiny \
        procps psmisc htop file tzdata \
        qrencode iproute2 iputils-ping dnsutils; \
    update-ca-certificates; \
    # Re-point apt at the merged store so later stages trust both the system
    # roots and any extra anchors, whatever the supplied bundle contained.
    if [ -f /etc/apt/apt.conf.d/99-t3code-extra-ca ]; then \
      echo 'Acquire::https::CaInfo "/etc/ssl/certs/ca-certificates.crt";' \
          > /etc/apt/apt.conf.d/99-t3code-extra-ca; \
    fi; \
    ln -sf "$(command -v fdfind)" /usr/local/bin/fd; \
    ln -sf "$(command -v batcat)" /usr/local/bin/bat; \
    git lfs install --system; \
    rm -rf /var/lib/apt/lists/*

# GitHub CLI from GitHub's own apt repository rather than Debian's. Debian
# trixie ships 2.46, and T3 Code refuses to read sign-in status from anything
# older than 2.81 - "GitHub CLI is too old to report sign-in status" - which
# makes the distro package useless for the one job it has here. This is the
# install method GitHub documents, and it carries both architectures.
#
# Deliberately unpinned: the repo keeps only the current version, so a pin
# would break the build the day it moves. The floor below is what actually
# matters, and it is asserted rather than assumed.
ARG GH_MIN_VERSION=2.81.0
RUN set -eux; \
    mkdir -p -m 755 /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get -o Acquire::Retries=8 update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*; \
    installed="$(gh --version | head -1 | awk '{print $3}')"; \
    if [ "$(printf '%s\n%s\n' "$GH_MIN_VERSION" "$installed" | sort -V | head -1)" != "$GH_MIN_VERSION" ]; then \
      echo "gh $installed is below the $GH_MIN_VERSION T3 Code requires" >&2; exit 1; \
    fi; \
    echo "gh $installed"

# Cloudflare Tunnel. T3 Code has managed-tunnel support built in and fetches
# this binary at runtime when it is missing - which needs working egress at
# exactly the moment someone is trying to get connected, and writes into the
# state volume on first use. Ship it instead, pinned to the release T3 Code
# asks for, and point T3 Code at it so it never downloads its own. It is also
# what `t3-expose` and the setup page's Ports panel use to publish a dev server.
ARG CLOUDFLARED_VERSION=2026.5.2
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) cfarch=amd64 ;; \
      arm64) cfarch=arm64 ;; \
      *) echo "no cloudflared build for $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${cfarch}"; \
    chmod 0755 /usr/local/bin/cloudflared; \
    cloudflared --version
ENV T3CODE_CLOUDFLARED_PATH=/usr/local/bin/cloudflared

ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

# The base image ships a `node` user on uid 1000. Reclaim it for `t3` so the
# common case (host uid 1000) needs no remapping at all.
ARG T3_UID=1000
ARG T3_GID=1000
RUN set -eux; \
    userdel -r node 2>/dev/null || true; \
    groupdel node 2>/dev/null || true; \
    groupadd -g "$T3_GID" t3; \
    useradd -m -u "$T3_UID" -g "$T3_GID" -s /bin/bash t3

# Mutable npm location. The baked harnesses and the browser MCP servers live
# here so T3 Code's own "update provider" button and plain `npm i -g` keep
# working at runtime. This is deliberately not T3 Code's own prefix: the server
# is image infrastructure (T3_INFRA_PREFIX below) and a writable prefix it
# shared with user packages could be used to rewrite the server itself.
ENV PATH=/opt/npm-global/bin:$PATH
RUN mkdir -p /opt/npm-global && chown -R t3:t3 /opt/npm-global

# `npm i -g` as the unprivileged user has nowhere to write by default - npm's
# system prefix (/usr/local) is root-owned. Point npm at the mutable prefix
# through the user's own config instead of a process-wide NPM_CONFIG_PREFIX:
# root's npm keeps using its root-owned prefix and creates no user-owned global
# state, while a plain `docker exec -u t3 npm i -g ...` still works. A project
# changing its own ~/.npmrc only redirects its own installs.
RUN printf 'prefix=/opt/npm-global\n' > /home/t3/.npmrc \
    && chown t3:t3 /home/t3/.npmrc

# User-only tool environment (Go's GOPATH/bin and mise's shims, set by
# /etc/profile.d/t3-user-env.sh). Kept out of the image environment so root
# never has a user-controlled directory on PATH.
COPY docker/user-env.sh /etc/profile.d/t3-user-env.sh
RUN chmod 0644 /etc/profile.d/t3-user-env.sh

# mise - persistent, project-aware toolchains.
#
# Pinned to an exact release and verified against a committed checksum (both
# architectures) before the binary is installed. mise itself is image
# infrastructure: root-owned, not group/other writable, and launched by absolute
# path. Everything it manages - installed tools, the global config, its cache -
# lives in the unprivileged user's persistent home, so toolchains survive
# recreation without widening root's environment. docker/mise/config.toml lands
# at /etc/mise/config.toml: the lowest-precedence config every user and every
# `docker exec` reads, carrying the execution policy and the generated
# idiomatic allowlist. See docs/toolchain/project-execution.md.
ARG MISE_VERSION=2026.9.10
COPY docker/mise/ /opt/mise/
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) mise_arch=x64 ;; \
      arm64) mise_arch=arm64 ;; \
      *) echo "no mise build for $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    asset="mise-v${MISE_VERSION}-linux-${mise_arch}"; \
    curl -fsSL -o /tmp/mise \
      "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/${asset}"; \
    checksum="$(awk -v asset="$asset" '$2 == asset { print $1 }' /opt/mise/SHA256SUMS)"; \
    if [ -z "$checksum" ]; then \
      echo "no checksum for ${asset} in docker/mise/SHA256SUMS" >&2; exit 1; \
    fi; \
    echo "${checksum}  /tmp/mise" | sha256sum -c -; \
    install -m 0755 /tmp/mise /usr/local/bin/mise; \
    rm -f /tmp/mise; \
    install -D -m 0644 /opt/mise/config.toml /etc/mise/config.toml; \
    mise --version; \
    # The user-owned trees mise writes to, ready before the first tool install. A
    # persistent volume mounted at /home/t3 hides these image defaults but keeps
    # its own contents; mise recreates whatever it needs.
    mkdir -p \
      /home/t3/.config/mise \
      /home/t3/.local/share/mise \
      /home/t3/.local/state/mise \
      /home/t3/.cache/mise; \
    chown -R t3:t3 /home/t3/.config /home/t3/.local /home/t3/.cache

# ---------------------------------------------------------------------------
# slim - T3 Code and the harnesses
# ---------------------------------------------------------------------------
FROM base AS slim

# Pinned so a rebuild is reproducible; `scripts/bump-versions.sh` refreshes them
# against the registries, and CI opens a PR when one falls behind. Any of these
# also accepts `latest` as a build arg when you want the newest at build time.
ARG T3_VERSION=0.0.40
ARG CLAUDE_CODE_VERSION=2.1.270
ARG CODEX_VERSION=0.154.0
ARG OPENCODE_VERSION=1.18.30
ARG GROK_VERSION=1.0.30

# T3 Code is image infrastructure. It installs into its own root-owned prefix
# and is launched only through absolute paths - docker/bin/t3-admin passes the
# entry module to the image Node - so nothing under a project, a mise shim, or
# a user npm prefix can change which runtime the server runs.
ENV T3_INFRA_PREFIX=/opt/t3 \
    T3_INFRA_NODE=/usr/local/bin/node \
    T3_INFRA_LAUNCHER=/usr/local/bin/t3-admin

# node-pty has no Linux prebuilds and compiles here; build-essential and
# python3 (installed above) are what make that work.
RUN set -eux; \
    mkdir -p "$T3_INFRA_PREFIX"; \
    npm install -g --no-audit --no-fund --prefix "$T3_INFRA_PREFIX" \
        "t3@${T3_VERSION}"; \
    npm cache clean --force; \
    # Source maps are dead weight here (~140 MB across the image).
    find "$T3_INFRA_PREFIX" -type f -name '*.map' -delete; \
    # Root-owned and not group/other writable: the t3 user runs the server and
    # must never be able to modify it.
    chown -R root:root "$T3_INFRA_PREFIX"; \
    chmod -R go-w "$T3_INFRA_PREFIX"

# Harnesses stay in the mutable prefix, exactly as before. T3 Code's "update
# provider" button installs into the prefix it discovers from each harness's
# real path, so baked harnesses keep updating until the product switch.
RUN set -eux; \
    npm install -g --no-audit --no-fund --prefix /opt/npm-global \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
        "opencode-ai@${OPENCODE_VERSION}" \
        "@xai-official/grok@${GROK_VERSION}"; \
    npm cache clean --force; \
    # Source maps and other platforms' prebuilt binaries are dead weight here
    # (~140 MB); the harnesses only ever load the Linux ones.
    find /opt/npm-global -type f -name '*.map' -delete; \
    find /opt/npm-global -type d \( -name 'win32-*' -o -name 'darwin-*' \) \
         -prune -exec rm -rf {} +; \
    chown -R t3:t3 /opt/npm-global

# Cursor ships no npm package; its installer writes into $HOME/.local/bin, so
# give it a home of its own rather than letting it land in /root.
ARG INSTALL_CURSOR=true
ENV CURSOR_HOME=/opt/cursor
ENV PATH=/opt/cursor/.local/bin:$PATH
# Downloaded to a file rather than piped: `curl ... | bash` reports bash's exit
# status, so a failed download installs nothing and still succeeds. The test at
# the end is the real guard - every other toolchain here proves itself by
# running --version, and this one silently did not.
RUN set -eux; \
    if [ "$INSTALL_CURSOR" = "true" ]; then \
      mkdir -p "$CURSOR_HOME"; \
      curl -fsSL https://cursor.com/install -o /tmp/cursor-install.sh; \
      HOME="$CURSOR_HOME" bash /tmp/cursor-install.sh; \
      rm -f /tmp/cursor-install.sh; \
      test -x "$CURSOR_HOME/.local/bin/cursor-agent"; \
      chown -R t3:t3 "$CURSOR_HOME"; \
    fi

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/bin/ /usr/local/bin/
# Plain ESM modules shared by the setup service, the entrypoint and the shell
# helpers: the harness manager owns install/resolve, and the provider
# integration turns its selection into T3's per-provider `binaryPath`.
COPY docker/harness/ /opt/t3-harness/
COPY docker/provider-integration/ /opt/t3-provider/
COPY docker/setup/ /opt/t3-setup/
COPY examples/ /opt/examples/
# T3 Code's client has no link to the setup console, so a fresh install that
# lands on the pairing screen has nowhere to go. The pill is injected into the
# static shell - it probes for the console and hides itself when absent - and
# patch.mjs fails the build if upstream moves the layout it relies on.
COPY docker/t3-client/ /usr/local/share/t3-client/
RUN "$T3_INFRA_NODE" /usr/local/share/t3-client/patch.mjs
# `t3` is the same immutable launcher under its user-facing name. /usr/local/bin
# precedes the npm prefixes on PATH, so it always wins over a project shim.
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/t3-* \
    && ln -sfn t3-admin /usr/local/bin/t3

ENV T3CODE_HOME=/home/t3/.t3 \
    T3CODE_HOST=0.0.0.0 \
    T3CODE_PORT=3773 \
    T3_WORKSPACE=/workspace \
    T3_AUTO_ADD_PROJECTS=1 \
    T3_PRINT_PAIRING_ON_START=0 \
    T3_SETUP_ENABLED=1 \
    T3_SETUP_PORT=3774 \
    T3_SETUP_BASE_PATH= \
    PUID=1000 \
    PGID=1000

RUN mkdir -p /workspace /home/t3/.t3 && chown -R t3:t3 /workspace /home/t3

VOLUME ["/home/t3", "/workspace"]
WORKDIR /workspace
EXPOSE 3773 3774

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -fsS --max-time 4 "http://127.0.0.1:${T3CODE_PORT}/.well-known/t3/environment" >/dev/null || exit 1

# Stamped last so a version change reuses every layer above it. IMAGE_VERSION is
# the release tag in CI and "dev" for a local build; the setup page shows both so
# you can tell at a glance which image is actually running.
ARG IMAGE_VERSION=dev
ARG IMAGE_VARIANT=slim
ENV T3_IMAGE_VERSION=${IMAGE_VERSION} \
    T3_IMAGE_VARIANT=${IMAGE_VARIANT}
LABEL org.opencontainers.image.version="${IMAGE_VERSION}"

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["t3-serve"]

# ---------------------------------------------------------------------------
# full - language toolchains, media tools, and a headless browser
# ---------------------------------------------------------------------------
FROM slim AS full

USER root

RUN set -eux; \
    apt-get -o Acquire::Retries=8 update; \
    apt-get install -y --no-install-recommends \
        clang lld cmake pkg-config gdb \
        ffmpeg imagemagick \
        postgresql-client redis-tools \
        chromium \
        fonts-liberation fonts-dejavu-core fonts-noto-core \
        fonts-noto-color-emoji fonts-noto-cjk; \
    rm -rf /var/lib/apt/lists/*

# Go - Debian's golang-go trails upstream, so take the official tarball.
# GOPATH (and its bin directory) is user state, so it is set only for the t3
# user by /etc/profile.d/t3-user-env.sh - never image-wide. Root's `go install`
# then lands in /root/go rather than writing into the user's home.
ARG GO_VERSION=1.27.1
ENV GOROOT=/usr/local/go
ENV PATH=/usr/local/go/bin:$PATH
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) goarch=amd64 ;; \
      arm64) goarch=arm64 ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${goarch}.tar.gz" -o /tmp/go.tgz; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz; \
    go version

# Rust
ARG RUST_VERSION=stable
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:$PATH
RUN set -eux; \
    curl -fsSL https://sh.rustup.rs | \
      sh -s -- -y --no-modify-path --profile minimal \
        --default-toolchain "$RUST_VERSION" \
        --component clippy --component rustfmt; \
    chmod -R a+w "$RUSTUP_HOME" "$CARGO_HOME"; \
    rustc --version

# Bun and Deno
ENV BUN_INSTALL=/usr/local/bun
ENV DENO_INSTALL=/usr/local/deno
ENV PATH=/usr/local/bun/bin:/usr/local/deno/bin:$PATH
RUN set -eux; \
    curl -fsSL https://bun.sh/install | bash; \
    curl -fsSL https://deno.land/install.sh | sh -s -- --yes; \
    bun --version; \
    deno --version

# uv, for Python projects that expect it
RUN set -eux; \
    curl -fsSL https://astral.sh/uv/install.sh | \
      env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh; \
    uv --version

# Browser automation over MCP. T3 Code's own preview tools are hosted by the
# web/desktop client, so a phone-only setup has no eyes without this.
ARG CHROME_DEVTOOLS_MCP_VERSION=1.9.0
ARG PLAYWRIGHT_MCP_VERSION=0.0.80
ENV CHROME_PATH=/usr/bin/chromium \
    CHROME_BIN=/usr/bin/chromium \
    PUPPETEER_SKIP_DOWNLOAD=1 \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium
RUN set -eux; \
    npm install -g --no-audit --no-fund --prefix /opt/npm-global \
        "chrome-devtools-mcp@${CHROME_DEVTOOLS_MCP_VERSION}" \
        "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}"; \
    npm cache clean --force; \
    chown -R t3:t3 /opt/npm-global

RUN mkdir -p /home/t3/go && chown -R t3:t3 /home/t3

# Stamped last so a version change reuses every layer above it. IMAGE_VERSION is
# the release tag in CI and "dev" for a local build; the setup page shows both so
# you can tell at a glance which image is actually running.
ARG IMAGE_VERSION=dev
ARG IMAGE_VARIANT=full
ENV T3_IMAGE_VERSION=${IMAGE_VERSION} \
    T3_IMAGE_VARIANT=${IMAGE_VARIANT}
LABEL org.opencontainers.image.version="${IMAGE_VERSION}"

# ---------------------------------------------------------------------------
# core - the final default: base + full non-browser OS packages, T3 infra,
# mise (from base), and the harness installer. No baked harness executables,
# no baked language runtimes, no browser.
#
# Transitional slim/full are preserved above unchanged. core duplicates slim's
# T3/entrypoint wiring (minus baked harnesses) and full's non-browser apt set
# so the old targets stay byte-identical in behavior while the new chain can
# evolve independently. TM-13 removes slim/full and deduplicates.
# ---------------------------------------------------------------------------
FROM base AS core

USER root

# The non-browser union: everything full installs via apt except Chromium,
# fonts, and (implicitly) the baked toolchains below it. Keep this list in
# sync with full's non-browser subset; browser-only packages live in the
# browser stage.
RUN set -eux; \
    apt-get -o Acquire::Retries=8 update; \
    apt-get install -y --no-install-recommends \
        clang lld cmake pkg-config gdb \
        ffmpeg imagemagick \
        postgresql-client redis-tools; \
    rm -rf /var/lib/apt/lists/*

# Pinned so a rebuild is reproducible; `scripts/bump-versions.sh` refreshes
# every `ARG T3_VERSION=` line in this file, so slim and core stay in sync.
# Baked harness pins (CLAUDE/CODEX/OPENCODE/GROK) intentionally do not appear
# here: core ships the installer, never the executables.
ARG T3_VERSION=0.0.40

# T3 Code is image infrastructure. Identical to slim: root-owned prefix,
# launched only through absolute paths.
ENV T3_INFRA_PREFIX=/opt/t3 \
    T3_INFRA_NODE=/usr/local/bin/node \
    T3_INFRA_LAUNCHER=/usr/local/bin/t3-admin

# node-pty has no Linux prebuilds and compiles here; build-essential and
# python3 (in base above) are what make that work.
RUN set -eux; \
    mkdir -p "$T3_INFRA_PREFIX"; \
    npm install -g --no-audit --no-fund --prefix "$T3_INFRA_PREFIX" \
        "t3@${T3_VERSION}"; \
    npm cache clean --force; \
    # Source maps are dead weight here (~140 MB across the image).
    find "$T3_INFRA_PREFIX" -type f -name '*.map' -delete; \
    # Root-owned and not group/other writable: the t3 user runs the server and
    # must never be able to modify it.
    chown -R root:root "$T3_INFRA_PREFIX"; \
    chmod -R go-w "$T3_INFRA_PREFIX"

# No baked harnesses, no Cursor installer. The harness installer (manager +
# provider integration + t3-harness CLI) arrives with the COPYs below and
# installs mise-managed executables into the persistent home at runtime.

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/bin/ /usr/local/bin/
# Plain ESM modules shared by the setup service, the entrypoint and the shell
# helpers: the harness manager owns install/resolve, and the provider
# integration turns its selection into T3's per-provider `binaryPath`.
COPY docker/harness/ /opt/t3-harness/
COPY docker/provider-integration/ /opt/t3-provider/
COPY docker/setup/ /opt/t3-setup/
COPY examples/ /opt/examples/
# T3 Code's client has no link to the setup console, so a fresh install that
# lands on the pairing screen has nowhere to go. The pill is injected into the
# static shell - it probes for the console and hides itself when absent - and
# patch.mjs fails the build if upstream moves the layout it relies on.
COPY docker/t3-client/ /usr/local/share/t3-client/
RUN "$T3_INFRA_NODE" /usr/local/share/t3-client/patch.mjs
# `t3` is the same immutable launcher under its user-facing name. /usr/local/bin
# precedes the npm prefixes on PATH, so it always wins over a project shim.
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/t3-* \
    && ln -sfn t3-admin /usr/local/bin/t3

ENV T3CODE_HOME=/home/t3/.t3 \
    T3CODE_HOST=0.0.0.0 \
    T3CODE_PORT=3773 \
    T3_WORKSPACE=/workspace \
    T3_AUTO_ADD_PROJECTS=1 \
    T3_PRINT_PAIRING_ON_START=0 \
    T3_SETUP_ENABLED=1 \
    T3_SETUP_PORT=3774 \
    T3_SETUP_BASE_PATH= \
    PUID=1000 \
    PGID=1000

RUN mkdir -p /workspace /home/t3/.t3 /home/t3/go && chown -R t3:t3 /workspace /home/t3

VOLUME ["/home/t3", "/workspace"]
WORKDIR /workspace
EXPOSE 3773 3774

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -fsS --max-time 4 "http://127.0.0.1:${T3CODE_PORT}/.well-known/t3/environment" >/dev/null || exit 1

# Stamped last so a version change reuses every layer above it. IMAGE_VERSION is
# the release tag in CI and "dev" for a local build; the setup page shows both so
# you can tell at a glance which image is actually running.
ARG IMAGE_VERSION=dev
ARG IMAGE_VARIANT=core
ENV T3_IMAGE_VERSION=${IMAGE_VERSION} \
    T3_IMAGE_VARIANT=${IMAGE_VARIANT}
LABEL org.opencontainers.image.version="${IMAGE_VERSION}"

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["t3-serve"]

# ---------------------------------------------------------------------------
# browser - core + Chromium, fonts, and both MCP servers. No baked harnesses,
# no baked language runtimes.
# ---------------------------------------------------------------------------
FROM core AS browser

USER root

RUN set -eux; \
    apt-get -o Acquire::Retries=8 update; \
    apt-get install -y --no-install-recommends \
        chromium \
        fonts-liberation fonts-dejavu-core fonts-noto-core \
        fonts-noto-color-emoji fonts-noto-cjk; \
    rm -rf /var/lib/apt/lists/*

# Browser automation over MCP. Identical to full: T3 Code's own preview tools
# are hosted by the web/desktop client, so a phone-only setup has no eyes
# without this. `scripts/bump-versions.sh` keeps both full and browser pins in
# sync.
ARG CHROME_DEVTOOLS_MCP_VERSION=1.9.0
ARG PLAYWRIGHT_MCP_VERSION=0.0.80
ENV CHROME_PATH=/usr/bin/chromium \
    CHROME_BIN=/usr/bin/chromium \
    PUPPETEER_SKIP_DOWNLOAD=1 \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium
RUN set -eux; \
    npm install -g --no-audit --no-fund --prefix /opt/npm-global \
        "chrome-devtools-mcp@${CHROME_DEVTOOLS_MCP_VERSION}" \
        "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}"; \
    npm cache clean --force; \
    chown -R t3:t3 /opt/npm-global

# Stamped last so a version change reuses every layer above it. IMAGE_VERSION is
# the release tag in CI and "dev" for a local build; the setup page shows both so
# you can tell at a glance which image is actually running.
ARG IMAGE_VERSION=dev
ARG IMAGE_VARIANT=browser
ENV T3_IMAGE_VERSION=${IMAGE_VERSION} \
    T3_IMAGE_VARIANT=${IMAGE_VARIANT}
LABEL org.opencontainers.image.version="${IMAGE_VERSION}"
