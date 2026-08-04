# review-loop.nvim

A Neovim frontend for the `pi-review-loop` workflow: a persistent, incremental
diff reviewer that keeps a **review checkpoint** so each review shows only what
changed since the last one.

This is the standalone Lua port. Its data layer is small and the checkpoint
format is **byte-compatible with the TypeScript extension** — a checkpoint
written in Neovim is readable by pi (and vice versa).

---

## What you get

- **Sidebar** with two sections, both following the active diff mode:
  - **Recently Changed** — flat list, newest mtime first, with comment-count badges
  - **Files** — directory tree of the same paths
- **Two-pane diff** (`baseline | current`) on Neovim's built-in diff engine
- **Inline comments** as `+` sign glyphs with the comment as virtual text
- **Two modes**: `checkpoint` (since last review) and `head` (vs current `HEAD`)
- **Submit** composes feedback (byte-identical to the extension) and checkpoints
  the workspace

---

## Prerequisites

| Need | Why | Check |
| --- | --- | --- |
| Neovim ≥ 0.10 | `vim.system`, extmark `sign_text`, `vim.base64` | `nvim --version` |
| `git` | diffing, checkpointing | `git --version` |
| `gzip` + `base64` | checkpoint content codec | `command -v gzip base64` |
| `plenary.nvim` | **tests only** — not required to use the plugin | `:messages` after install |

---

## Install

> The plugin code lives in the **`nvim/`** subdirectory of this repo (it shares
> the repo with the TypeScript extension). Point your manager at `nvim/` and set
> `main = "review-loop"`.

### lazy.nvim — recommended

**Minimal (runtime only, no dependencies):**

```lua
{
  "earendil-works/pi-review-loop",
  dir = "~/code/pi-review-loop/nvim", -- path to the nvim/ subdirectory
  main = "review-loop",                -- require("review-loop")
  opts = {},                           -- calls require("review-loop").setup({})
  cmd = "ReviewLoop",                  -- load when you run :ReviewLoop
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
    -- Powers the test suite only; safe to remove if you never run tests.
    { "nvim-lua/plenary.nvim" },
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
  requires = { "nvim-lua/plenary.nvim" }, -- optional, tests only
  config = function()
    require("review-loop").setup({})
  end,
}
```

### Manual (pack `start`)

```sh
ln -s "$PWD/nvim" ~/.local/share/nvim/site/pack/review-loop/start/review-loop.nvim
```

`plugin/review-loop.lua` is sourced at startup, so `:ReviewLoop` is available
with **zero config**. To customize, add to your `init.lua`:

```lua
require("review-loop").setup({ width = 40 })
```

---

## First run

1. `cd` into a Git repository with uncommitted changes.
2. `:ReviewLoop` — opens a new tab with sidebar | original | modified.
3. `<CR>` on a file in the sidebar to load its diff.
4. `c` on a line in either pane to add an inline comment.
5. `<leader>rs` to submit (feedback yanked to `+` by default; workspace checkpointed).

That's it. Keep the tab open; subsequent changes show up as the next batch.

---

## Configuration

All fields optional — defaults shown:

```lua
require("review-loop").setup({
  width = 34,            -- sidebar width in columns
  auto_refresh = true,   -- re-scan on BufWritePost
  on_submit = function(feedback, _checkpoint)
    -- Default: yank feedback to the * register and notify.
    -- Reassign to integrate with your agent however you like.
    if feedback ~= "" then
      vim.fn.setreg("+", feedback)
      vim.notify("Feedback yanked to \"+. Paste it into the agent.", vim.log.levels.INFO)
    end
  end,
  keymaps = {
    open_file      = "<CR>",
    add_comment    = "c",
    add_file_note  = "n",
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
| Open file under cursor | `<CR>` | sidebar |
| Add / edit inline comment | `c` | diff pane |
| Delete comment on this line | `x` | diff pane |
| Add file-level note | `n` | sidebar |
| **Submit review** | `<leader>rs` | anywhere |
| Toggle `checkpoint` ↔ `head` mode | `<leader>rm` | anywhere |
| Force refresh | `<leader>rr` | anywhere |
| Close | `q` | sidebar |

Submitting marks all currently-changed paths reviewed, snapshots the working
tree as the new checkpoint, composes feedback, and clears comments. Submitting
with no comments just marks the workspace reviewed.

Comment editor (the floating window): `<CR>` to save, `<Esc>` to cancel,
`<C-Cr>` to save from insert mode.

---

## The pi feedback loop (the one gap)

The TypeScript extension calls `ctx.ui.pasteToEditor(feedback)` to drop the
composed text straight into pi's editor. A standalone Neovim process can't reach
that API, so the default `on_submit` yanks feedback to `+` for you to paste.

Reassign `on_submit` to integrate however you prefer — e.g. write to a file the
agent watches, or shell out to a pi command if one exists:

```lua
on_submit = function(feedback, checkpoint)
  if feedback == "" then return end
  io.open(vim.fn.getcwd() .. "/.review-feedback.md", "w"):write(feedback):close()
  vim.notify("Feedback written to .review-feedback.md", vim.log.levels.INFO)
end,
```

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
./scripts/test     # plenary unit suite (37 tests): feedback, checkpoint, git, state, comments
./scripts/lint     # luacheck over lua/ and tests/
./scripts/smoke    # headless end-to-end: open → comment → submit → checkpoint
```

If `plenary.nvim` is installed by lazy (see the lazy example above), `scripts/test`
finds it with no extra configuration. The unit suite covers the pure layer; the
smoke test covers the window/UI wiring that headless unit tests can't reliably
exercise.

---

## Development (Nix)

A `flake.nix` provides a reproducible dev shell with a pinned **neovim**,
**plenary**, and **luacheck** — no local setup or lazy install required:

```sh
cd nvim
nix develop            # enter the shell
./scripts/test         # plenary is pinned via PLENARY_PATH
./scripts/lint
```

`PLENARY_PATH` is exported by the shell to the flake-pinned plenary source, so
`scripts/test` is fully deterministic. `nix fmt` formats Nix files; `nix flake
lock --update-input nixpkgs` bumps Neovim/plenary.

> **Why plenary, not standalone `busted`?** Every module touches the `vim.*`
> API at load time (`vim.system`, `vim.uv`, `vim.fn`), so the test runner must
> live **inside Neovim**. plenary provides the same `describe`/`it`/`assert`
> API as `busted` but runs in-process. The standalone `busted` binary can't
> load these modules. `luacheck` is included because it's pure static analysis
> and needs no Neovim.
