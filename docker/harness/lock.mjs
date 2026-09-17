// One lock for the whole harness manager.
//
// mise writes a single user-wide config and one installs tree, so two installs
// racing each other can half-write configuration or report a harness runnable
// while its files are still being extracted. The lock is a file created with
// O_EXCL, which is atomic on every filesystem the image supports.
//
// A lock left behind by a killed process is detectable, not permanent: the
// recorded pid must still exist and the lock must be younger than `staleMs`.
// The reader (including status) never writes, so a stuck lock cannot be
// "cleaned up" into a silent concurrent install.
import crypto from "node:crypto";
import path from "node:path";
import { processAlive as defaultProcessAlive } from "./io.mjs";

export function lockPath(stateDir) {
  return path.join(stateDir, "harness.lock");
}

/** Parse a lock file; malformed content is treated as stale, never trusted. */
export async function readLock(ctx) {
  try {
    const raw = await ctx.fs.readFile(ctx.lockPath, "utf8");
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object") return null;
    return parsed;
  } catch {
    return null;
  }
}

/** A lock is stale when its owner is gone or it is older than the ceiling. */
export function lockIsStale(holder, ctx) {
  if (!holder) return true;
  const alive = ctx.isAlive ?? defaultProcessAlive;
  if (!alive(holder.pid)) return true;
  if (!Number.isFinite(holder.startedAt)) return true;
  return ctx.now() - holder.startedAt > ctx.lockStaleMs;
}

/** Read-only view used by status: is a live operation holding the lock? */
export async function liveHolder(ctx) {
  const holder = await readLock(ctx);
  if (!holder) return null;
  return lockIsStale(holder, ctx) ? null : holder;
}

/**
 * Acquire the global lock, or report the live holder. Stale locks are removed
 * and retried, so an interrupted install heals on the next operation.
 */
export async function acquireLock(ctx, { id, operation }) {
  await ctx.fs.mkdir(path.dirname(ctx.lockPath), { recursive: true });

  for (let attempt = 0; attempt < 4; attempt += 1) {
    const token = crypto.randomBytes(12).toString("hex");
    const body = JSON.stringify({
      pid: ctx.pid,
      host: ctx.host,
      token,
      id,
      operation,
      startedAt: ctx.now(),
    });

    try {
      await ctx.fs.writeFile(ctx.lockPath, body, { encoding: "utf8", flag: "wx" });
    } catch (error) {
      if (error?.code !== "EEXIST") {
        return { acquired: false, holder: null, error: String(error?.message ?? error) };
      }
      const holder = await readLock(ctx);
      if (!lockIsStale(holder, ctx)) {
        return { acquired: false, holder, error: null };
      }
      // The owner is gone. Remove its lock and race for ours; another process
      // may win the next `wx`, in which case the loop re-reads and reports.
      try { await ctx.fs.unlink(ctx.lockPath); } catch { /* someone else won */ }
      continue;
    }

    return {
      acquired: true,
      holder: { pid: ctx.pid, host: ctx.host, token, id, operation, startedAt: ctx.now() },
      release: async () => {
        const current = await readLock(ctx);
        if (current?.token !== token) return;
        try { await ctx.fs.unlink(ctx.lockPath); } catch { /* already gone */ }
      },
    };
  }

  return { acquired: false, holder: await readLock(ctx), error: null };
}
