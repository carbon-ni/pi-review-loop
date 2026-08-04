# review-loop.nvim

A Neovim frontend for the `pi-review-loop` workflow: a persistent, incremental
diff reviewer that keeps a **review checkpoint** so each review shows only what
changed since the last one.

This is the standalone Lua port. Its data layer is small and the checkpoint
format is **byte-compatible with the TypeScript extension** — a checkpoint
written in Neovim is readable by pi (and vice versa).

---

## What you get

- **Diffview file panel** for tree/list navigation, file status, folds, and layout controls;
  the newest changed file is selected initially
- **Two-pane Diffview** (`baseline | current`) with review-loop winbar labels
- **Inline comments** as `+` sign glyphs with the comment as virtual text
- **Live refresh** — a recursive repo watcher picks up the agent's writes; a
  `BufWritePost` autocmd catches your own saves (recursive on macOS; top-level
  only on Linux)
- **Two modes**: `checkpoint` (since last review) and `head` (vs current `HEAD`)
- **Submit** composes feedback (byte-identical to the extension), checkpoints the
  workspace, and **writes the feedback to a file** whose path is shown

---

## Prerequisites

| Need | Why | Check |
| --- | --- | --- |
| Neovim ≥ 0.10 | `vim.system`, extmark `sign_text`, `vim.base64` | `nvim --version` |
| `git` | diffing, checkpointing | `git --version` |
| `gzip` + `base64` | checkpoint content codec | `command -v gzip base64` |
| `sindrets/diffview.nvim` | Runtime file panel and diff view | `:DiffviewOpen` |
| `plenary.nvim` | **tests only** — not required at runtime | `:messages` after install |

---

## Install

> The plugin code lives in the **`nvim/`** subdirectory of this repo (it shares
> the repo with the TypeScript extension). Point your manager at `nvim/` and set
> `main = "review-loop"`.

### lazy.nvim — recommended

**Minimal runtime setup:**

```lua
{
  "earendil-works/pi-review-loop",
  dir = "~/code/pi-review-loop/nvim", -- path to the nvim/ subdirectory
  main = "review-loop",                -- require("review-loop")
  opts = {},                           -- calls require("review-loop").setup({})
  cmd = "ReviewLoop",                  -- load when you run :ReviewLoop
  dependencies = {
    { "sindrets/diffview.nvim" },
    { "nvim-tree/nvim-web-devicons" }, -- optional Diffview icons
  },
  keys = {
    { "<leader>dr", "<cmd>ReviewLoop<cr>", desc = "Open review loop" },
  },
}
```

**With plenary as a dependency (enables the test suite):**

`dependencies` is where any requirement goes. `plenary.nvim` is only needed to
run `scripts/test` — but once it's a lazy dependency, the test script finds it
automatically (it defaults to lazy's install path):

```lua
{
  "earendil-works/pi-review-loop",
  dir = "~/code/pi-review-loop/nvim",
  main = "review-loop",
  opts = {},
  cmd = "ReviewLoop",
  dependencies = {
    { "sindrets/diffview.nvim" },
    { "nvim-tree/nvim-web-devicons" }, -- optional Diffview icons
    { "nvim-lua/plenary.nvim" },       -- test suite only
  },
  -- Optional: run the suite after install/update (build runs inside dir = nvim/).
  build = "./scripts/test",
}
```

Want another dependency later (a UI lib, a git wrapper)? Just add it to
`dependencies` — that's the whole point of declaring it here.

> **Local dev:** add `dev = true` so lazy loads straight from `dir` and your
> edits apply without reinstall. Point `dir` at an absolute path to the `nvim/`
> folder, e.g. `dir = vim.fn.stdpath("config") .. "/lua/local/pi-review-loop/nvim"`.

### packer.nvim

```lua
use {
  "earendil-works/pi-review-loop",
  -- packer adds the repo root to rtp; expose the nvim/ subdir:
  rtp = "nvim",
  requires = {
    "sindrets/diffview.nvim",
    "nvim-tree/nvim-web-devicons", -- optional Diffview icons
    "nvim-lua/plenary.nvim",       -- tests only
  },
  config = function()
    require("review-loop").setup({})
  end,
}
```

### Manual (pack `start`)

```sh
ln -s "$PWD/nvim" ~/.local/share/nvim/site/pack/review-loop/start/review-loop.nvim
# Install sindrets/diffview.nvim under pack/*/start as well.
```

`plugin/review-loop.lua` is sourced at startup, so `:ReviewLoop` is available
with **zero config**. To customize, add to your `init.lua`:

```lua
require("review-loop").setup({ auto_refresh = true })
```

---

## First run

1. `cd` into a Git repository with uncommitted changes.
2. `:ReviewLoop` — opens a Diffview tab with file panel | reviewed | current.
3. `<CR>` on a file in Diffview's panel to load its diff.
4. `c` on a line in either pane to add an inline comment, or select lines
   (`V`) and press `c` to comment the whole range.
5. `<leader>rs` to submit: the composed feedback is written to a file (path
   shown in the notification) and the workspace is checkpointed.

That's it. Keep the tab open; the watcher picks up the agent's next changes.

---

## Configuration

All fields optional — defaults shown:

```lua
require("review-loop").setup({
  auto_refresh = true,   -- BufWritePost autocmd + repo file watcher

  -- Where composed feedback is written on submit and :ReviewLoopSend.
  -- nil -> stdpath("data")/review-loop/feedback.md (outside the worktree).
  feedback_file = nil,

  keymaps = {
    add_comment    = "c",
    add_file_note  = "<leader>rn",
    delete_comment = "x",
    submit         = "<leader>rs",
    toggle_mode    = "<leader>rm",
    refresh        = "<leader>rr",
    close          = "q",
  },
})
```

---

## Workflow & keymaps

| Action | Default | Where |
| --- | --- | --- |
| Open file under cursor | `<CR>` | Diffview file panel |
| Add / edit inline comment | `c` | diff pane |
| Comment a line range | `c` (visual) | diff pane |
| Delete comment on this line | `x` | diff pane |
| Add file-level note | `<leader>rn` | Diffview file panel |
| **Submit review** | `<leader>rs` | anywhere |
| Toggle `checkpoint` ↔ `head` mode | `<leader>rm` | anywhere |
| Force refresh | `<leader>rr` | anywhere |
| Close | `q` | Diffview file panel |

Submitting marks all currently-changed paths reviewed, snapshots the working
tree as the new checkpoint, composes feedback, and clears comments. Submitting
with no comments just marks the workspace reviewed.

Comment editor: a normal vim buffer — motions, operators, and `:w` / `:x` / `:q`
all work. It opens in **normal mode** (press `i`/`a`/`o` to insert, `<Esc>` to
leave insert). `<CR>` or `q` saves & closes; `:w` saves without closing.
Clear the text and close to discard the comment.

---

## Commands

Everything is also a command (scriptable / mappable) in addition to the keys:

| Command | Action |
| --- | --- |
| `:ReviewLoop` | open the reviewer |
| `:ReviewLoopRefresh` | re-scan now (same as `<leader>rr`) |
| `:ReviewLoopWatch` | toggle the repo file watcher |
| `:ReviewLoopMode` | toggle `checkpoint` ↔ `head` (same as `<leader>rm`) |
| `:ReviewLoopFeedback` | preview composed feedback in a split |
| `:ReviewLoopYank` | yank composed feedback to `+` |
| `:ReviewLoopSend` | submit, checkpoint, and copy feedback file path to `+` |
| `:ReviewLoopClose` | close the reviewer |

Map any of them, e.g. `vim.keymap.set("n", "<leader>ds", "<cmd>ReviewLoopSend<cr>")`.

---

## Delivering feedback to pi (file)

The TypeScript extension calls `ctx.ui.pasteToEditor(feedback)` because it runs
*inside* pi. This plugin is a separate process, so on submit it writes the
composed feedback to a file and shows the path. `:ReviewLoopSend` also copies
that file path to the `+` register. You then forward it however you like:

- paste the file's contents into pi, or
- tell the agent to read the path (e.g. `read <path>`).

The default path is `stdpath("data")/review-loop/feedback.md` (outside the
worktree, so it never shows up in the diff). Override it with `feedback_file`:

```lua
feedback_file = "/tmp/review-loop.md",       -- any absolute path
-- feedback_file = "./.review-feedback.md",  -- repo-local (gitignore it)
```

`:ReviewLoopSend` submits the current comments, checkpoints the workspace, and
yanks the feedback file path to the `+` register. `:ReviewLoopYank` instead
yanks composed feedback itself without submitting.

---

## Checkpoint format & interop

One JSON file per repo under `stdpath("data")/review-loop/<sanitized-root>.json`,
mirroring the extension's `ReviewCheckpoint` (version 1). File overrides are
`gzip+base64` and sha256-fingerprinted exactly like `src/git.ts`, so the two
implementations read each other's checkpoints.

---

## Tests

```sh
cd nvim
./scripts/test     # plenary unit suite (47 tests): Diffview adapter, feedback, checkpoint, git, state, comments, UI
./scripts/lint     # luacheck over lua/ and tests/
./scripts/smoke    # headless end-to-end: open → comment → submit → checkpoint
```

If `plenary.nvim` is installed by lazy (see the lazy example above), `scripts/test`
finds it with no extra configuration. The unit suite covers the pure layer; the
smoke test covers the window/UI wiring that headless unit tests can't reliably
exercise.

---

## Development (Nix)

A `flake.nix` provides a reproducible dev shell with pinned **neovim**,
**Diffview**, **plenary**, and **luacheck** — no local setup or lazy install required:

```sh
cd nvim
nix develop            # enter the shell
./scripts/test         # plenary is pinned via PLENARY_PATH
./scripts/lint
```

`PLENARY_PATH` and `DIFFVIEW_PATH` point at flake-pinned sources, so tests are
deterministic. `nix fmt` formats Nix files; `nix flake lock --update-input
nixpkgs` bumps Neovim while plugin inputs remain pinned.

> **Why plenary, not standalone `busted`?** Every module touches the `vim.*`
> API at load time (`vim.system`, `vim.uv`, `vim.fn`), so the test runner must
> live **inside Neovim**. plenary provides the same `describe`/`it`/`assert`
> API as `busted` but runs in-process. The standalone `busted` binary can't
> load these modules. `luacheck` is included because it's pure static analysis
> and needs no Neovim.
