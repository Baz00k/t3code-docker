#!/usr/bin/env node
// Audit the pinned T3 Code release for how each supported harness is
// discovered, launched, probed, and updated.
//
// The audit reads the published `t3` npm package (no network for the core
// pass). Modern T3 bundles its server, but ships the original TypeScript in
// `dist/bin.mjs.map`; this script extracts those sources and reads the facts
// that decide the harness-management design:
//
//   * the per-provider `binaryPath` setting and its default;
//   * the executable T3 actually spawns (the supported override seam);
//   * the status/version probe and any minimum version it enforces;
//   * the updater T3 derives from where the executable lives;
//   * whether discovery/probing can install or update anything.
//
// The matrix it prints is the evidence behind
// `docs/toolchain/provider-audit.md`.
//
// Usage:
//   node scripts/audit-t3-providers.mjs --package /path/to/node_modules/t3
//   node scripts/audit-t3-providers.mjs                 # auto-detect an installed t3
//   node scripts/audit-t3-providers.mjs --json          # machine-readable matrix
//   node scripts/audit-t3-providers.mjs --mise          # add local mise install sources
//   node scripts/audit-t3-providers.mjs --mise --mise-versions
//   node scripts/audit-t3-providers.mjs --expect-version 0.0.40
//
// Exit status is 0 only when every provider has complete evidence tied to the
// inspected package. `--expect-version` turns a version mismatch into an error.

import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";

const MISE_TIMEOUT_MS = 60_000;

/** The complete supported catalogue, in T3's presentation order. */
const PROVIDERS = [
  {
    id: "claude",
    label: "Claude",
    driverKind: "claudeAgent",
    settingsExport: "ClaudeSettings",
    driverSource: "src/provider/Drivers/ClaudeDriver.ts",
    probeSource: "src/provider/Layers/ClaudeProvider.ts",
    launchSources: [
      "src/provider/Layers/ClaudeAdapter.ts",
      "src/provider/Drivers/ClaudeExecutable.ts",
    ],
    probeTokens: ['"--version"'],
    launchTokens: ["pathToClaudeCodeExecutable"],
    miseTool: "claude",
  },
  {
    id: "codex",
    label: "Codex",
    driverKind: "codex",
    settingsExport: "CodexSettings",
    driverSource: "src/provider/Drivers/CodexDriver.ts",
    probeSource: "src/provider/Layers/CodexProvider.ts",
    launchSources: ["src/provider/Layers/CodexSessionRuntime.ts"],
    probeTokens: ["app-server"],
    launchTokens: ["app-server"],
    miseTool: "codex",
  },
  {
    id: "opencode",
    label: "OpenCode",
    driverKind: "opencode",
    settingsExport: "OpenCodeSettings",
    driverSource: "src/provider/Drivers/OpenCodeDriver.ts",
    probeSource: "src/provider/Layers/OpenCodeProvider.ts",
    launchSources: ["src/provider/opencodeRuntime.ts"],
    probeTokens: ['"--version"'],
    launchTokens: ['"serve"'],
    miseTool: "opencode",
  },
  {
    id: "grok",
    label: "Grok",
    driverKind: "grok",
    settingsExport: "GrokSettings",
    driverSource: "src/provider/Drivers/GrokDriver.ts",
    probeSource: "src/provider/Layers/GrokProvider.ts",
    launchSources: ["src/provider/acp/GrokAcpSupport.ts"],
    probeTokens: ['"--version"', '"models"'],
    launchTokens: ["buildGrokAcpSpawnInput"],
    miseTool: "grok",
  },
  {
    id: "cursor",
    label: "Cursor",
    driverKind: "cursor",
    settingsExport: "CursorSettings",
    driverSource: "src/provider/Drivers/CursorDriver.ts",
    probeSource: "src/provider/Layers/CursorProvider.ts",
    launchSources: ["src/provider/acp/CursorAcpSupport.ts"],
    probeTokens: ['"about", "--format", "json"'],
    launchTokens: ["buildCursorAcpSpawnInput"],
    miseTool: "cursor-agent",
  },
];

const SETTINGS_SOURCE = "packages/contracts/src/settings.ts";
const MAINTENANCE_SOURCE = "src/provider/providerMaintenance.ts";
const RUNTIME_SOURCES = ["src/provider/opencodeRuntime.ts"];
const ENTRY_SOURCE = "src/bin.ts";

class AuditError extends Error {}

function parseArgs(argv) {
  const options = {
    package: null,
    json: false,
    mise: false,
    miseVersions: false,
    expectVersion: null,
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "--package":
      case "-p":
        options.package = argv[++i] ?? null;
        if (!options.package) throw new AuditError("--package needs a path");
        break;
      case "--json":
        options.json = true;
        break;
      case "--mise":
        options.mise = true;
        break;
      case "--mise-versions":
        options.miseVersions = true;
        options.mise = true;
        break;
      case "--expect-version":
        options.expectVersion = argv[++i] ?? null;
        if (!options.expectVersion) throw new AuditError("--expect-version needs a value");
        break;
      case "--help":
      case "-h":
        options.help = true;
        break;
      default:
        throw new AuditError(`unknown argument: ${arg}`);
    }
  }
  return options;
}

const usage = () => {
  process.stdout.write(
    [
      "Audit the pinned T3 release's provider execution and update seams.",
      "",
      "  --package, -p <dir>     Path to an installed `t3` package directory",
      "  --json                  Emit the matrix as JSON",
      "  --mise                  Add local mise install-source metadata",
      "  --mise-versions         Also query mise for available versions (network)",
      "  --expect-version <v>    Fail when the package version differs",
      "  --help, -h              Show this help",
      "",
    ].join("\n"),
  );
};

function isT3PackageDir(dir) {
  try {
    const pkg = JSON.parse(NodeFS.readFileSync(NodePath.join(dir, "package.json"), "utf8"));
    return pkg.name === "t3";
  } catch {
    return false;
  }
}

function candidateGlobalRoots() {
  const roots = [];
  const env = process.env.T3_PACKAGE_DIR;
  if (env) roots.push(env);
  roots.push(NodePath.join(process.cwd(), "node_modules", "t3"));
  try {
    const npmRoot = NodeChildProcess.execFileSync("npm", ["root", "-g"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 15_000,
    }).trim();
    if (npmRoot) roots.push(NodePath.join(npmRoot, "t3"));
  } catch {
    // npm may be absent in a minimal runtime; the fixed roots below still apply.
  }
  roots.push(
    "/opt/npm-global/lib/node_modules/t3",
    "/usr/local/lib/node_modules/t3",
    "/usr/lib/node_modules/t3",
  );
  return roots;
}

function resolvePackageRoot(explicit) {
  if (explicit) {
    const dir = NodePath.resolve(explicit);
    if (!isT3PackageDir(dir)) throw new AuditError(`${dir} is not an installed t3 package`);
    return dir;
  }
  for (const candidate of candidateGlobalRoots()) {
    if (candidate && isT3PackageDir(candidate)) return NodePath.resolve(candidate);
  }
  throw new AuditError("no t3 package found; pass --package <dir>");
}

function normalizeSourcePath(source) {
  return source.replace(/^(?:\.\.\/)+/, "");
}

function loadSources(mapPath) {
  const map = JSON.parse(NodeFS.readFileSync(mapPath, "utf8"));
  const sources = new Map();
  if (!Array.isArray(map.sources) || !Array.isArray(map.sourcesContent)) {
    throw new AuditError("bin.mjs.map has no sourcesContent; cannot audit statically");
  }
  map.sources.forEach((source, index) => {
    const content = map.sourcesContent[index];
    if (typeof content === "string") {
      sources.set(normalizeSourcePath(source), content);
    }
  });
  return sources;
}

function requireSource(sources, fragment) {
  for (const [key, value] of sources) {
    if (key === fragment || key.endsWith(`/${fragment}`)) return { path: key, content: value };
  }
  throw new AuditError(`source not found in bundle: ${fragment}`);
}

function firstMatch(text, pattern) {
  const match = pattern.exec(text);
  return match ? match[1] ?? match[0] : null;
}

function extractSettingsBlock(sources, exportName) {
  const file = requireSource(sources, SETTINGS_SOURCE);
  const pattern = new RegExp(
    `export const ${exportName} = makeProviderSettingsSchema\\(([\\s\\S]*?)\\n\\s*\\);`,
  );
  const match = pattern.exec(file.content);
  if (!match) throw new AuditError(`${exportName} block not found in ${file.path}`);
  return { file, block: match[1] };
}

function classifyUpdate(driverFile) {
  const npmPackageName = firstMatch(driverFile.content, /npmPackageName:\s*"([^"]+)"/);
  const nativeArgs = firstMatch(
    driverFile.content,
    /nativeUpdate:\s*\{[\s\S]*?args:\s*\[([^\]]*)\]/,
  );
  const manualOnly = driverFile.content.includes("makeManualOnlyProviderMaintenanceCapabilities");
  const selfUpdating =
    /updateExecutable:\s*context\.resolvedCommandPath/.test(driverFile.content) &&
    /updateArgs:\s*\["update"\]/.test(driverFile.content);

  if (npmPackageName) {
    const args = nativeArgs
      ? nativeArgs
          .split(",")
          .map((part) => part.trim().replace(/^"|"$/g, ""))
          .filter(Boolean)
      : [];
    return {
      kind: "package-managed",
      packageName: npmPackageName,
      nativeCommand: args.length ? args.join(" ") : null,
      note: "npm/Homebrew/bun/pnpm ownership is re-derived from the executable's real path; a mise-owned path resolves to manual-only.",
    };
  }
  if (selfUpdating) {
    return {
      kind: "self-updating",
      packageName: null,
      nativeCommand: "update",
      note: "The resolved executable is its own updater; it offers the command whenever the binary resolves, regardless of location.",
    };
  }
  if (manualOnly) {
    return {
      kind: "manual-only",
      packageName: null,
      nativeCommand: null,
      note: "No updater channel; T3 reports the installed version and never offers an update command.",
    };
  }
  return { kind: "unknown", packageName: null, nativeCommand: null, note: "" };
}

function auditProvider(sources, spec) {
  const driverFile = requireSource(sources, spec.driverSource);
  const probeFile = requireSource(sources, spec.probeSource);
  const { block } = extractSettingsBlock(sources, spec.settingsExport);

  const checks = [];
  const note = (label, value, found) => {
    const entry = { label, value, found: found === true };
    checks.push(entry);
    return entry;
  };
  const record = (label, value, found) => note(label, value, found).value;

  const driverKind = record(
    "driver kind",
    firstMatch(driverFile.content, /const DRIVER_KIND = ProviderDriverKind\.make\("([^"]+)"\)/),
    new RegExp(`ProviderDriverKind\\.make\\("${spec.driverKind}"\\)`).test(driverFile.content),
  );

  const binaryPathDefault = record(
    "default binaryPath",
    firstMatch(block, /makeBinaryPathSetting\("([^"]+)"\)/),
    /makeBinaryPathSetting\("/.test(block),
  );

  const enabledByDefault = record(
    "enabled by default",
    firstMatch(block, /enabled:\s*Schema\.Boolean\.pipe\(\s*Schema\.withDecodingDefault\(Effect\.succeed\((true|false)\)\)/),
    /enabled:/.test(block),
  );

  record(
    "binaryPath is the launch seam",
    `settings.binaryPath -> ${spec.label} spawn`,
    spec.launchSources.some((source) =>
      requireSource(sources, source).content.includes("binaryPath"),
    ),
  );

  const probeEvidence = spec.probeTokens.map((token) =>
    note(`probe ${token}`, token, probeFile.content.includes(token)),
  );

  const launchEvidence = spec.launchSources.flatMap((source) => {
    const file = requireSource(sources, source);
    return spec.launchTokens.map((token) =>
      note(`launch ${token}`, file.path, file.content.includes(token)),
    );
  });

  const versionSources = [spec.probeSource, spec.driverSource];
  if (spec.id === "opencode") versionSources.push(...RUNTIME_SOURCES);
  let minVersion = null;
  for (const source of versionSources) {
    const file = sources.get(source);
    if (!file) continue;
    const match = firstMatch(file, /MINIMUM_[A-Z_]*VERSION\s*=\s*"([^"]+)"/);
    if (match) {
      minVersion = match;
      note("minimum version", match, true);
      break;
    }
  }
  if (minVersion === null) note("minimum version", "none enforced", true);

  const update = classifyUpdate(driverFile);

  return {
    id: spec.id,
    label: spec.label,
    driverKind,
    settings: { binaryPathDefault, enabledByDefault },
    probe: probeEvidence,
    launch: launchEvidence,
    minVersion,
    update,
    checks,
  };
}

function auditMaintenanceSeam(sources) {
  const file = requireSource(sources, MAINTENANCE_SOURCE);
  const checks = [
    {
      label: "mise-owned path is manual-only",
      found: /mise[\\/]+installs/.test(file.content),
      snippet: firstMatch(file.content, /(\/mise[\\/]+installs[^\n]*)/) ?? null,
    },
    {
      label: "npm ownership needs a proven prefix",
      found: /lib\/node_modules/.test(file.content),
    },
    {
      label: "homebrew ownership needs a matching keg",
      found: /cellar\|caskroom/.test(file.content),
    },
  ];
  return { file: file.path, checks };
}

function auditEntrySeam(sources, pkg) {
  const entry = requireSource(sources, ENTRY_SOURCE);
  const subcommandBlock = firstMatch(entry.content, /withSubcommands\(\[([\s\S]*?)\]\)/);
  const subcommands = subcommandBlock
    ? [...subcommandBlock.matchAll(/([A-Za-z]+Command)/g)].map((match) => match[1])
    : [];
  const binPath = typeof pkg.bin === "string" ? pkg.bin : pkg.bin?.t3 ?? null;
  return {
    bin: binPath,
    entryModule: binPath ? `dist/${NodePath.basename(binPath)}` : null,
    subcommands,
  };
}

function runMise(args) {
  try {
    return {
      ok: true,
      stdout: NodeChildProcess.execFileSync("mise", args, {
        encoding: "utf8",
        timeout: MISE_TIMEOUT_MS,
        stdio: ["ignore", "pipe", "pipe"],
      }),
    };
  } catch (error) {
    return { ok: false, error: String(error.message ?? error) };
  }
}

function auditMiseTools(options) {
  const tools = {};
  for (const spec of PROVIDERS) {
    const result = runMise(["tool", "-J", spec.miseTool]);
    if (!result.ok) {
      tools[spec.miseTool] = { error: result.error };
      continue;
    }
    let parsed;
    try {
      parsed = JSON.parse(result.stdout);
    } catch (error) {
      tools[spec.miseTool] = { error: `unparseable mise output: ${String(error.message)}` };
      continue;
    }
    const toolOptions = parsed.tool_options ?? {};
    const entry = {
      backend: parsed.backend,
      bin: toolOptions.bin ?? null,
      binPath: toolOptions.bin_path ?? null,
      url: toolOptions.url ?? null,
      versionListUrl: toolOptions.version_list_url ?? null,
      versionRegex: toolOptions.version_regex ?? null,
      platforms: toolOptions.platforms ?? null,
      postinstall: toolOptions.postinstall ?? null,
      security: parsed.security ?? [],
    };
    if (options.miseVersions) {
      const versions = runMise(["ls-remote", spec.miseTool]);
      if (versions.ok) {
        entry.versions = versions.stdout
          .split("\n")
          .map((line) => line.trim())
          .filter((line) => /^[0-9]/.test(line));
      } else {
        entry.versionsError = versions.error;
      }
    }
    tools[spec.miseTool] = entry;
  }
  return tools;
}

function collectFailures(report) {
  const failures = [];
  for (const provider of report.providers) {
    for (const check of provider.checks) {
      if (!check.found) failures.push(`${provider.id}: missing ${check.label}`);
    }
  }
  for (const check of report.maintenance.checks) {
    if (!check.found) failures.push(`maintenance: ${check.label}`);
  }
  return failures;
}

function printMatrix(report) {
  const lines = [];
  lines.push(`t3 ${report.version}  (${report.packageRoot})`);
  lines.push(`entry module: ${report.entry.entryModule ?? "unknown"}`);
  lines.push("");
  const header = [
    "provider".padEnd(9),
    "driver".padEnd(11),
    "default bin".padEnd(13),
    "enabled".padEnd(8),
    "min ver".padEnd(9),
    "updater".padEnd(15),
    "launch".padEnd(9),
  ].join(" ");
  lines.push(header);
  lines.push("-".repeat(header.length));
  for (const provider of report.providers) {
    lines.push(
      [
        provider.id.padEnd(9),
        String(provider.driverKind).padEnd(11),
        String(provider.settings.binaryPathDefault).padEnd(13),
        String(provider.settings.enabledByDefault).padEnd(8),
        String(provider.minVersion ?? "-").padEnd(9),
        String(provider.update.kind).padEnd(15),
        provider.launch.every((entry) => entry.found) ? "ok" : "missing",
      ].join(" "),
    );
  }
  lines.push("");
  lines.push("updater detail:");
  for (const provider of report.providers) {
    const { update } = provider;
    const native = update.nativeCommand ? `${update.packageName ?? "(self)"} :: ${update.nativeCommand}` : "none";
    lines.push(`  ${provider.id.padEnd(9)} ${native}`);
  }
  lines.push("");
  lines.push(`maintenance seam: ${report.maintenance.file}`);
  for (const check of report.maintenance.checks) {
    lines.push(`  [${check.found ? "x" : " "}] ${check.label}`);
  }
  lines.push("");
  lines.push(`T3 CLI subcommands: ${report.entry.subcommands.join(", ") || "unknown"}`);
  if (report.mise) {
    lines.push("");
    lines.push("mise install sources:");
    for (const [tool, entry] of Object.entries(report.mise)) {
      if (entry.error) {
        lines.push(`  ${tool.padEnd(13)} ERROR ${entry.error}`);
        continue;
      }
      const versions = entry.versions
        ? `${entry.versions.length} available (latest ${entry.versions.at(-1)})`
        : "not queried";
      lines.push(`  ${tool.padEnd(13)} ${entry.backend}`);
      lines.push(`  ${"".padEnd(13)} url: ${entry.url ?? "-"}`);
      lines.push(`  ${"".padEnd(13)} versions: ${versions}`);
    }
  }
  lines.push("");
  if (report.failures.length === 0) {
    lines.push("evidence complete: every provider is tied to the inspected package.");
  } else {
    lines.push("evidence INCOMPLETE:");
    for (const failure of report.failures) lines.push(`  - ${failure}`);
  }
  return lines.join("\n");
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    usage();
    return 0;
  }

  const packageRoot = resolvePackageRoot(options.package);
  const pkg = JSON.parse(NodeFS.readFileSync(NodePath.join(packageRoot, "package.json"), "utf8"));
  const binPath = typeof pkg.bin === "string" ? pkg.bin : pkg.bin?.t3 ?? null;
  if (!binPath) throw new AuditError("package.json has no `t3` bin entry");

  const bundlePath = NodePath.join(packageRoot, binPath);
  const mapPath = `${bundlePath}.map`;
  if (!NodeFS.existsSync(mapPath)) {
    throw new AuditError(`no source map at ${mapPath}; cannot audit ${pkg.version} statically`);
  }
  const sources = loadSources(mapPath);

  const report = {
    version: pkg.version,
    integrity: pkg.dist?.integrity ?? null,
    packageRoot,
    entry: auditEntrySeam(sources, pkg),
    maintenance: auditMaintenanceSeam(sources),
    providers: PROVIDERS.map((spec) => auditProvider(sources, spec)),
    mise: options.mise ? auditMiseTools(options) : null,
    failures: [],
  };
  report.failures = collectFailures(report);

  if (options.expectVersion && pkg.version !== options.expectVersion) {
    report.failures.push(`package version ${pkg.version} != expected ${options.expectVersion}`);
  }

  if (options.json) {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  } else {
    process.stdout.write(`${printMatrix(report)}\n`);
  }
  return report.failures.length === 0 ? 0 : 1;
}

try {
  process.exitCode = main();
} catch (error) {
  if (error instanceof AuditError) {
    process.stderr.write(`audit-t3-providers: ${error.message}\n`);
    process.exitCode = 2;
  } else {
    process.stderr.write(`audit-t3-providers: unexpected error\n${error.stack}\n`);
    process.exitCode = 2;
  }
}
