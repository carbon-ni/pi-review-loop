-- User configuration for review-loop.nvim.
local M = {}

M.defaults = {
  -- Sidebar width in columns.
  width = 34,
  -- Re-scan the workspace on BufWritePost (file watcher fallback).
  auto_refresh = true,
  -- Called after a submit with the composed feedback and the saved checkpoint.
  -- Default: yank feedback to the * clipboard/registers and notify.
  on_submit = function(feedback, _checkpoint)
    if feedback == "" then
      vim.notify("Review checkpoint saved (no comments).", vim.log.levels.INFO)
      return
    end
    vim.fn.setreg("+", feedback)
    vim.notify("Feedback yanked to \"+. Paste it into the agent.", vim.log.levels.INFO)
  end,
  keymaps = {
    open_file = "<CR>",
    add_comment = "c",
    add_file_note = "n",
    delete_comment = "x",
    submit = "<leader>rs",
    toggle_mode = "<leader>rm",
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
