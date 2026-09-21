// The five supported agent harnesses. This file is data only: every executable
// name, architecture, credential surface, and minimum version the manager
// enforces comes from here, so the module, the setup console, and the CLI all
// describe the same harnesses.

/**
 * T3 refuses to serve OpenCode below this version, so a managed install must
 * not select one. T3's provider contract requires this minimum version.
 */
export const MINIMUM_OPENCODE_VERSION = "1.14.19";

/**
 * Canonical Cursor executable. `agent` is an alias only the vendor installer
 * creates; mise's `http:cursor-agent` backend recreates `cursor-agent` alone,
 * and an `agent` binary on PATH collides with Grok's aqua package, so nothing
 * here ever names it.
 */
export const CURSOR_EXECUTABLE = "cursor-agent";

/**
 * `executable` is the path relative to the mise install directory. `versionArgs`
 * is the bounded probe the
 * manager runs to turn "a file exists" into "this exact version runs".
 */
export const CATALOGUE = Object.freeze([
  {
    id: "claude",
    name: "Claude Code",
    miseTool: "claude",
    executable: "claude",
    versionArgs: ["--version"],
    versionPattern: "(\\d+\\.\\d+\\.\\d+)",
    minimumVersion: null,
    // Both release assets exist for x64 and arm64.
    architectures: ["x64", "arm64"],
    credentials: {
      env: ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"],
      paths: [".claude/.credentials.json"],
    },
    auth: "claude",
  },
  {
    id: "codex",
    name: "Codex",
    miseTool: "codex",
    executable: "bin/codex",
    versionArgs: ["--version"],
    versionPattern: "(\\d+\\.\\d+\\.\\d+)",
    minimumVersion: null,
    architectures: ["x64", "arm64"],
    credentials: {
      env: [],
      paths: [".codex/auth.json"],
    },
    auth: "codex",
  },
  {
    id: "opencode",
    name: "OpenCode",
    miseTool: "opencode",
    executable: "opencode",
    versionArgs: ["--version"],
    versionPattern: "(\\d+\\.\\d+\\.\\d+)",
    minimumVersion: MINIMUM_OPENCODE_VERSION,
    architectures: ["x64", "arm64"],
    credentials: {
      env: [],
      paths: [".local/share/opencode/auth.json"],
    },
    auth: "opencode",
  },
  {
    id: "grok",
    name: "Grok Build",
    miseTool: "grok",
    executable: "grok",
    versionArgs: ["--version"],
    versionPattern: "(\\d+\\.\\d+\\.\\d+)",
    minimumVersion: null,
    architectures: ["x64", "arm64"],
    credentials: {
      env: ["XAI_API_KEY"],
      paths: [".grok/auth.json"],
    },
    auth: "grok",
  },
  {
    id: "cursor",
    name: "Cursor",
    miseTool: CURSOR_EXECUTABLE,
    executable: `dist-package/${CURSOR_EXECUTABLE}`,
    versionArgs: ["--version"],
    // Cursor versions are date-hash pins, not semver; 2026.09.15-d2fe57e.
    versionPattern: "(\\d{4}\\.\\d{2}\\.\\d{2}-[0-9a-f]+)",
    minimumVersion: null,
    architectures: ["x64", "arm64"],
    credentials: {
      env: [],
      paths: [".cursor/cli-config.json"],
    },
    auth: "cursor",
  },
]);

/** Look up one catalogue entry by its stable id. */
export function getHarness(id) {
  return CATALOGUE.find((entry) => entry.id === id) ?? null;
}

/** Map `dpkg --print-architecture`/uname spellings onto node's arch names. */
export function normalizeArch(arch) {
  switch (String(arch ?? "")) {
    case "amd64":
    case "x86_64":
    case "x64":
      return "x64";
    case "arm64":
    case "aarch64":
      return "arm64";
    default:
      return String(arch ?? "") || null;
  }
}

/** Whether this catalogue entry publishes an artifact for the host arch. */
export function supportsArch(entry, arch) {
  const normalized = normalizeArch(arch);
  return normalized !== null && entry.architectures.includes(normalized);
}
