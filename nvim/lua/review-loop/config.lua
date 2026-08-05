-- User configuration for review-loop.nvim.
local M = {}

M.defaults = {
  -- Re-scan on BufWritePost (nvim saves) and via the repo file watcher.
  auto_refresh = true,

  -- Where composed feedback is written on submit and :ReviewLoopSend.
  -- nil -> a stable path under stdpath("data")/review-loop/feedback.md
  -- (outside the worktree, so it never pollutes the diff).
  feedback_file = nil,

  -- Emit structured debug logs to stdpath("data")/review-loop/review-loop.log.
  -- Off by default; toggle at runtime with :ReviewLoopDebug.
  debug = false,

  keymaps = {
    add_comment = "c",
    add_file_note = "<leader>rn",
    delete_comment = "x",
    next_comment = "]r",
    prev_comment = "[r",
    submit = "<leader>rs",
    toggle_mode = "<leader>rm",
    mark_viewed = "<leader>rv",
    refresh = "<leader>rr",
    close = "q",
  },
}

M.config = nil

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.config
end

function M.get()
  return M.config or M.defaults
end

return M
