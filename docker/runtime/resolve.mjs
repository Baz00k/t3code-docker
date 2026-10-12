import { runtimePaths, selectedRuntime, readJson, databaseBusy } from "./state.mjs";
try {
  const paths = runtimePaths();
  if (databaseBusy(await readJson(paths.operation))) throw new Error("T3 Code is applying an update. Retry this command when it is ready.");
  console.log((await selectedRuntime(paths)).binary);
}
catch (error) { console.error(`t3-admin: ${error.message}`); process.exitCode = 1; }
