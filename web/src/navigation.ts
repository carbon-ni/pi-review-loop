/**
 * Vim-style window + buffer navigation for the Review Loop web view.
 *
 * The UI is treated as four "windows" (panes). `Ctrl+w` followed by a motion
 * (or the direct `Ctrl+h/j/k/l` shortcut) moves focus between windows. Inside
 * the focused window, `hjkl` moves a cursor and `c` acts on it.
 *
 *   sidebar  |  original (Reviewed/HEAD) | modified (Current)
 *                              feedback
 *
 * This module is DOM-free so the focus transitions and cursor math stay
 * deterministic and unit-testable. `app.ts` owns the rendering side effects.
 */

export type WindowId = "sidebar" | "original" | "modified" | "feedback";
export type Direction = "h" | "j" | "k" | "l" | "next" | "prev";

export type CursorMotion = "down" | "up" | "first" | "last" | "pageDown" | "pageUp";

export interface KeyContext {
  key: string;
  isTyping: boolean;
  hasModifier: boolean;
}

export type BufferAction =
  | "none"
  | "cursor-down"
  | "cursor-up"
  | "cursor-first"
  | "cursor-last"
  | "cursor-page-down"
  | "cursor-page-up"
  | "open"
  | "comment-line"
  | "file-note"
  | "submit"
  | "toggle-mode"
  | "focus-search"
  | "find-in-diff"
  | "help"
  | "engage-files";

// Spatial neighbours. Feedback sits below the diff row, so "up" from feedback
// lands on the modified (Current) pane; the diff panes share a row.
const NEIGHBORS: Record<WindowId, Record<Direction, WindowId>> = {
  sidebar: { h: "sidebar", l: "original", j: "sidebar", k: "sidebar", next: "original", prev: "feedback" },
  original: { h: "sidebar", l: "modified", j: "feedback", k: "original", next: "modified", prev: "sidebar" },
  modified: { h: "original", l: "modified", j: "feedback", k: "modified", next: "feedback", prev: "original" },
  feedback: { h: "feedback", l: "feedback", j: "feedback", k: "modified", next: "sidebar", prev: "modified" },
};

export function focusNeighbor(current: WindowId, direction: Direction): WindowId {
  return NEIGHBORS[current][direction];
}

/** Moves a 1-based line cursor, clamped to [1, lineCount]. */
export function moveCursor(lineCount: number, current: number, motion: CursorMotion, pageSize: number): number {
  const last = Math.max(1, lineCount);
  const clamp = (line: number): number => Math.min(Math.max(1, line), last);
  const step = Math.max(1, pageSize);
  switch (motion) {
    case "down": return clamp(current + 1);
    case "up": return clamp(current - 1);
    case "first": return 1;
    case "last": return last;
    case "pageDown": return clamp(current + step);
    case "pageUp": return clamp(current - step);
  }
}

const GLOBAL_KEYS: Readonly<Record<string, BufferAction>> = {
  "?": "help",
  s: "submit",
  m: "toggle-mode",
  f: "file-note",
  v: "engage-files",
};

const WINDOW_KEYS: Record<WindowId, Readonly<Record<string, BufferAction>>> = {
  sidebar: {
    j: "cursor-down", k: "cursor-up", g: "cursor-first", G: "cursor-last",
    Enter: "open", o: "open", "/": "focus-search",
  },
  original: {
    j: "cursor-down", k: "cursor-up", g: "cursor-first", G: "cursor-last",
    c: "comment-line", "/": "find-in-diff",
  },
  modified: {
    j: "cursor-down", k: "cursor-up", g: "cursor-first", G: "cursor-last",
    c: "comment-line", "/": "find-in-diff",
  },
  feedback: {},
};

export function isDiffWindow(window: WindowId): boolean {
  return window === "original" || window === "modified";
}

/**
 * Resolves a plain (non-prefix) key press within the focused window. Modifier
 * combos handled here: `Ctrl+d`/`Ctrl+u` half-page the diff cursor; everything
 * else with a modifier is inert (window switching is handled by the caller).
 */
export function resolveBufferAction(window: WindowId, ctx: KeyContext): BufferAction {
  if (ctx.isTyping) return "none";
  if (ctx.hasModifier) {
    if (isDiffWindow(window)) {
      if (ctx.key === "d") return "cursor-page-down";
      if (ctx.key === "u") return "cursor-page-up";
    }
    return "none";
  }
  const global = GLOBAL_KEYS[ctx.key];
  if (global != null) return global;
  return WINDOW_KEYS[window][ctx.key] ?? "none";
}

// --- File-list cursor helpers (the sidebar buffer walks these paths) ---------

export function nextPath(paths: string[], current: string | null): string | null {
  if (paths.length === 0) return null;
  const index = current == null ? -1 : paths.indexOf(current);
  if (index < 0) return paths[0];
  return paths[Math.min(index + 1, paths.length - 1)];
}

export function previousPath(paths: string[], current: string | null): string | null {
  if (paths.length === 0) return null;
  const index = current == null ? -1 : paths.indexOf(current);
  if (index < 0) return paths[0];
  return paths[Math.max(index - 1, 0)];
}

export function firstPath(paths: string[]): string | null {
  return paths[0] ?? null;
}

export function lastPath(paths: string[]): string | null {
  return paths.length === 0 ? null : paths[paths.length - 1] ?? null;
}
