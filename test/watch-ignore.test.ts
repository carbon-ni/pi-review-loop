import assert from "node:assert/strict";
import test from "node:test";
import { isWatchIgnored } from "../src/controller.js";

const ROOT = "/repo";

test("ignores vcs, dependency and pi runtime state directories", () => {
  for (const ignored of [
    ".git",
    ".git/refs",
    ".git/config",
    "node_modules",
    "node_modules/chokidar/index.js",
    ".pi",
    ".pi/intray",
    ".pi/intray/019e.sock",
    ".pi/intray/intra-aerospace.alias",
    ".pi/lsp-db.sqlite",
  ]) {
    assert.equal(isWatchIgnored(ROOT, `${ROOT}/${ignored}`), true, `expected ${ignored} to be ignored`);
  }
});

test("keeps watching source and reviewable files", () => {
  for (const kept of [
    "src/controller.ts",
    "README.md",
    ".github/workflows/ci.yml",
    ".gitconfig",
    "node_module.ts",
    "package.json",
  ]) {
    assert.equal(isWatchIgnored(ROOT, `${ROOT}/${kept}`), false, `expected ${kept} to be watched`);
  }
});

test("never ignores the repo root or paths outside it", () => {
  assert.equal(isWatchIgnored(ROOT, ROOT), false);
  assert.equal(isWatchIgnored(ROOT, `${ROOT}/..`), false);
  assert.equal(isWatchIgnored(ROOT, "/elsewhere/.pi"), false);
});
