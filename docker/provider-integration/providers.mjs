// The bridge between the harness catalogue and T3 Code's provider settings.
//
// The harness manager identifies harnesses by a stable `id` (`claude`,
// `codex`, ...). T3 Code keys its settings by provider *driver kind*, and the
// two do not line up: Claude's driver kind is `claudeAgent`, and Cursor's
// executable is `cursor-agent` while its driver kind is `cursor`. This mapping
// is data only, so the module, the CLI and the tests all speak the same names.
export const PROVIDERS = Object.freeze([
  { id: "claude", driver: "claudeAgent", name: "Claude Code" },
  { id: "codex", driver: "codex", name: "Codex" },
  { id: "opencode", driver: "opencode", name: "OpenCode" },
  { id: "grok", driver: "grok", name: "Grok Build" },
  { id: "cursor", driver: "cursor", name: "Cursor" },
]);

/** The T3 driver kind for a harness id, or null when the id is unknown. */
export function driverFor(id) {
  return PROVIDERS.find((provider) => provider.id === id)?.driver ?? null;
}

/** The harness id for a T3 driver kind, or null when the kind is unknown. */
export function idFor(driver) {
  return PROVIDERS.find((provider) => provider.driver === driver)?.id ?? null;
}
