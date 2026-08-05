import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { ReviewStore } from "../src/store.js";
import type { ReviewCheckpoint, ReviewComment, ReviewSession } from "../src/types.js";

function checkpoint(over?: Partial<ReviewCheckpoint>): ReviewCheckpoint {
  return {
    version: 1,
    id: "cp-1",
    repoRoot: "/repo",
    createdAt: 1000,
    headSha: "sha1",
    overrides: {},
    reviewedPaths: ["a.ts"],
    feedback: "looks good",
    ...over,
  };
}

function session(over?: Partial<ReviewSession>): ReviewSession {
  return {
    version: 1,
    repoRoot: "/repo",
    checkpointId: null,
    mode: "checkpoint",
    comments: [],
    viewedPaths: [],
    activePath: null,
    createdAt: 500,
    updatedAt: 500,
    ...over,
  };
}

function comment(over?: Partial<ReviewComment>): ReviewComment {
  return {
    id: "c1",
    path: "a.ts",
    side: "modified",
    line: 10,
    body: "nit",
    ...over,
  };
}

test("ReviewStore", async (t) => {
  const tmp = await mkdtemp(join(tmpdir(), "rl-store-"));

  await t.test("load returns null when no files exist", async () => {
    const store = new ReviewStore(tmp);
    const { checkpoint: cp, session: sess } = await store.load();
    assert.strictEqual(cp, null);
    assert.strictEqual(sess, null);
  });

  await t.test("save and load checkpoint round-trips", async () => {
    const store = new ReviewStore(tmp);
    const cp = checkpoint({ id: "abc", createdAt: 42 });
    await store.saveCheckpoint(cp);
    const { checkpoint: loaded } = await store.load();
    assert.deepStrictEqual(loaded, cp);
  });

  await t.test("save and load session round-trips", async () => {
    const store = new ReviewStore(tmp);
    const sess = session({
      comments: [comment({ id: "c1", body: "looks good" }), comment({ id: "c2", path: "b.ts", side: "file", line: null, body: "file-level note" })],
      viewedPaths: ["a.ts", "b.ts"],
      activePath: "a.ts",
      mode: "head",
    });
    await store.saveSession(sess);
    const { session: loaded } = await store.load();
    assert.deepStrictEqual(loaded, sess);
  });

  await t.test("session updatedAt is bumped on save", async () => {
    const store = new ReviewStore(tmp);
    const before = Date.now();
    const sess = session({ updatedAt: 1 });
    await store.saveSession(sess);
    const { session: loaded } = await store.load();
    assert.ok(loaded != null);
    assert.ok(loaded!.updatedAt >= before);
  });

  await t.test("save overwrites previous", async () => {
    const store = new ReviewStore(tmp);
    await store.saveCheckpoint(checkpoint({ id: "first" }));
    await store.saveCheckpoint(checkpoint({ id: "second" }));
    const { checkpoint: loaded } = await store.load();
    assert.strictEqual(loaded!.id, "second");
  });

  await t.test("clear removes all files", async () => {
    const store = new ReviewStore(tmp);
    await store.saveCheckpoint(checkpoint());
    await store.saveSession(session());
    await store.clear();
    const { checkpoint: cp, session: sess } = await store.load();
    assert.strictEqual(cp, null);
    assert.strictEqual(sess, null);
  });

  await t.test("checkpoint and session coexist in the same directory", async () => {
    const store = new ReviewStore(tmp);
    const cp = checkpoint({ id: "cp-x" });
    const sess = session({ checkpointId: "cp-x" });
    await store.saveCheckpoint(cp);
    await store.saveSession(sess);
    const state = await store.load();
    assert.deepStrictEqual(state.checkpoint, cp);
    assert.deepStrictEqual(state.session, sess);
  });

  await rm(tmp, { recursive: true, force: true });
});
