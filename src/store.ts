import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { ReviewCheckpoint, ReviewSession } from "./types.js";

const CHECKPOINT_FILE = "checkpoint.json";
const SESSION_FILE = "session.json";

/**
 * Disk-based persistence for the review loop, decoupled from pi.
 *
 * Files live under `.review-loop/` in the repository root:
 *   checkpoint.json  — latest immutable checkpoint (content baseline)
 *   session.json     — mutable work-in-progress (comments, viewed, mode, active file)
 *
 * Both the TypeScript extension and the Neovim Lua plugin read and write the
 * same files so the review state is shared across both frontends.
 */
export class ReviewStore {
  readonly dir: string;

  constructor(readonly repoRoot: string) {
    this.dir = join(repoRoot, ".review-loop");
  }

  /** Load both checkpoint and session (returns null when missing). */
  async load(): Promise<{ checkpoint: ReviewCheckpoint | null; session: ReviewSession | null }> {
    await mkdir(this.dir, { recursive: true });
    const [checkpoint, session] = await Promise.all([
      readJSON<ReviewCheckpoint>(join(this.dir, CHECKPOINT_FILE)).catch(() => null),
      readJSON<ReviewSession>(join(this.dir, SESSION_FILE)).catch(() => null),
    ]);
    return { checkpoint, session };
  }

  /** Persist a checkpoint (overwrites). */
  async saveCheckpoint(checkpoint: ReviewCheckpoint): Promise<void> {
    await mkdir(this.dir, { recursive: true });
    await writeJSON(join(this.dir, CHECKPOINT_FILE), checkpoint);
  }

  /** Persist the session (bumps updatedAt, overwrites). */
  async saveSession(session: ReviewSession): Promise<void> {
    session.updatedAt = Date.now();
    await mkdir(this.dir, { recursive: true });
    await writeJSON(join(this.dir, SESSION_FILE), session);
  }

  /** Remove the entire `.review-loop/` directory. */
  async clear(): Promise<void> {
    await rm(this.dir, { recursive: true, force: true });
  }
}

async function readJSON<T>(filePath: string): Promise<T> {
  const content = await readFile(filePath, "utf-8");
  return JSON.parse(content) as T;
}

async function writeJSON(filePath: string, data: unknown): Promise<void> {
  await writeFile(filePath, JSON.stringify(data, null, 2) + "\n", "utf-8");
}
