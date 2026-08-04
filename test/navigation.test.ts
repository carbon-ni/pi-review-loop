import assert from "node:assert/strict";
import test from "node:test";
import {
  focusNeighbor,
  moveCursor,
  resolveBufferAction,
  isDiffWindow,
  nextPath,
  previousPath,
  firstPath,
  lastPath,
  type KeyContext,
  type WindowId,
} from "../web/src/navigation.js";

const ctx = (key: string, overrides: Partial<KeyContext> = {}): KeyContext => ({
  key,
  isTyping: false,
  hasModifier: false,
  ...overrides,
});

test("focusNeighbor moves spatially between windows and never wraps unexpectedly", () => {
  assert.equal(focusNeighbor("sidebar", "l"), "original");
  assert.equal(focusNeighbor("original", "l"), "modified");
  assert.equal(focusNeighbor("modified", "h"), "original");
  assert.equal(focusNeighbor("original", "h"), "sidebar");
  assert.equal(focusNeighbor("original", "j"), "feedback");
  assert.equal(focusNeighbor("modified", "j"), "feedback");
  assert.equal(focusNeighbor("feedback", "k"), "modified");
  // no neighbour in that direction stays put
  assert.equal(focusNeighbor("sidebar", "h"), "sidebar");
  assert.equal(focusNeighbor("sidebar", "k"), "sidebar");
  assert.equal(focusNeighbor("feedback", "j"), "feedback");
});

test("focusNeighbor cycles windows with next/prev", () => {
  assert.equal(focusNeighbor("sidebar", "next"), "original");
  assert.equal(focusNeighbor("original", "next"), "modified");
  assert.equal(focusNeighbor("modified", "next"), "feedback");
  assert.equal(focusNeighbor("feedback", "next"), "sidebar");
  assert.equal(focusNeighbor("sidebar", "prev"), "feedback");
});

test("moveCursor moves one line and clamps at the ends", () => {
  assert.equal(moveCursor(10, 5, "down", 0), 6);
  assert.equal(moveCursor(10, 5, "up", 0), 4);
  assert.equal(moveCursor(10, 10, "down", 0), 10, "clamps at last line");
  assert.equal(moveCursor(10, 1, "up", 0), 1, "clamps at first line");
});

test("moveCursor hits first/last and pages by pageSize", () => {
  assert.equal(moveCursor(10, 5, "first", 0), 1);
  assert.equal(moveCursor(10, 5, "last", 0), 10);
  assert.equal(moveCursor(10, 5, "pageDown", 3), 8);
  assert.equal(moveCursor(10, 9, "pageDown", 5), 10, "page clamps at last line");
  assert.equal(moveCursor(10, 2, "pageUp", 5), 1, "page clamps at first line");
});

test("moveCursor is safe on an empty or single-line buffer", () => {
  assert.equal(moveCursor(0, 5, "down", 0), 1);
  assert.equal(moveCursor(1, 1, "down", 0), 1);
  assert.equal(moveCursor(0, 1, "last", 0), 1);
});

test("isDiffWindow distinguishes the two diff panes", () => {
  assert.equal(isDiffWindow("original"), true);
  assert.equal(isDiffWindow("modified"), true);
  assert.equal(isDiffWindow("sidebar"), false);
  assert.equal(isDiffWindow("feedback"), false);
});

test("resolveBufferAction maps hjkl to cursor motion inside the focused window", () => {
  for (const window of ["original", "modified"] as WindowId[]) {
    assert.equal(resolveBufferAction(window, ctx("j")), "cursor-down");
    assert.equal(resolveBufferAction(window, ctx("k")), "cursor-up");
    assert.equal(resolveBufferAction(window, ctx("g")), "cursor-first");
    assert.equal(resolveBufferAction(window, ctx("G")), "cursor-last");
  }
  // sidebar cursor motions walk the file list instead
  assert.equal(resolveBufferAction("sidebar", ctx("j")), "cursor-down");
  assert.equal(resolveBufferAction("sidebar", ctx("G")), "cursor-last");
});

test("resolveBufferAction: c comments the cursor line only in a diff pane", () => {
  assert.equal(resolveBufferAction("modified", ctx("c")), "comment-line");
  assert.equal(resolveBufferAction("original", ctx("c")), "comment-line");
  assert.equal(resolveBufferAction("sidebar", ctx("c")), "none");
  assert.equal(resolveBufferAction("feedback", ctx("c")), "none");
});

test("resolveBufferAction: / searches files in sidebar, the diff in a pane", () => {
  assert.equal(resolveBufferAction("sidebar", ctx("/")), "focus-search");
  assert.equal(resolveBufferAction("modified", ctx("/")), "find-in-diff");
});

test("resolveBufferAction: Enter/o opens only from the sidebar", () => {
  assert.equal(resolveBufferAction("sidebar", ctx("Enter")), "open");
  assert.equal(resolveBufferAction("sidebar", ctx("o")), "open");
  assert.equal(resolveBufferAction("modified", ctx("o")), "none");
});

test("resolveBufferAction: global keys work from any window", () => {
  for (const window of ["sidebar", "original", "modified", "feedback"] as WindowId[]) {
    assert.equal(resolveBufferAction(window, ctx("?")), "help", `? in ${window}`);
    assert.equal(resolveBufferAction(window, ctx("s")), "submit", `s in ${window}`);
    assert.equal(resolveBufferAction(window, ctx("m")), "toggle-mode", `m in ${window}`);
    assert.equal(resolveBufferAction(window, ctx("f")), "file-note", `f in ${window}`);
  }
});

test("resolveBufferAction is inert while typing", () => {
  assert.equal(resolveBufferAction("modified", ctx("c", { isTyping: true })), "none");
  assert.equal(resolveBufferAction("sidebar", ctx("j", { isTyping: true })), "none");
});

test("resolveBufferAction: Ctrl+d/Ctrl+u half-page the diff cursor", () => {
  assert.equal(resolveBufferAction("modified", ctx("d", { hasModifier: true })), "cursor-page-down");
  assert.equal(resolveBufferAction("original", ctx("u", { hasModifier: true })), "cursor-page-up");
  // page motions are meaningless in the sidebar / feedback
  assert.equal(resolveBufferAction("sidebar", ctx("d", { hasModifier: true })), "none");
  assert.equal(resolveBufferAction("feedback", ctx("u", { hasModifier: true })), "none");
});

test("resolveBufferAction: other modifier combos are inert (window nav owns them)", () => {
  assert.equal(resolveBufferAction("modified", ctx("h", { hasModifier: true })), "none");
  assert.equal(resolveBufferAction("sidebar", ctx("l", { hasModifier: true })), "none");
});

test("resolveBufferAction: unmapped keys are none", () => {
  assert.equal(resolveBufferAction("modified", ctx("x")), "none");
  assert.equal(resolveBufferAction("sidebar", ctx("z")), "none");
});

test("file-list cursor helpers clamp without wrapping and recover from stale selection", () => {
  const paths = ["a.ts", "b.ts", "c.ts"];
  assert.equal(nextPath(paths, "a.ts"), "b.ts");
  assert.equal(nextPath(paths, "c.ts"), "c.ts");
  assert.equal(nextPath(paths, "gone.ts"), "a.ts");
  assert.equal(previousPath(paths, "a.ts"), "a.ts");
  assert.equal(firstPath(paths), "a.ts");
  assert.equal(lastPath(paths), "c.ts");
  assert.equal(nextPath([], null), null);
});
