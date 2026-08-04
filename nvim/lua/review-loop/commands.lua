-- Auxiliary user commands (:ReviewLoop*). Each acts on the active reviewer.
local ui = require("review-loop.ui")

local M = {}
M.defined = false

local function with_active(fn, name)
  return function()
    local ctrl = ui.active
    if not ctrl or ctrl.closed then
      vim.notify(name .. ": open the reviewer first (:ReviewLoop)", vim.log.levels.WARN)
      return
    end
    fn(ctrl)
  end
end

function M.setup()
  if M.defined then
    return
  end
  M.defined = true

  vim.api.nvim_create_user_command("ReviewLoop", function()
    require("review-loop").open()
  end, { desc = "Open the persistent incremental diff reviewer" })

  local cmds = {
    ReviewLoopRefresh = { fn = function(c) c:refresh() end, desc = "Re-scan the workspace now" },
    ReviewLoopWatch = { fn = function(c) c:toggle_watch() end, desc = "Toggle the repo file watcher" },
    ReviewLoopMode = { fn = function(c) c:toggle_mode() end, desc = "Toggle checkpoint/head diff mode" },
    ReviewLoopFeedback = { fn = function(c) c:open_feedback() end, desc = "Preview composed feedback in a split" },
    ReviewLoopYank = { fn = function(c) c:yank_feedback() end, desc = "Yank composed feedback to the + register" },
    ReviewLoopSend = {
      fn = function(c) c:send_feedback() end,
      desc = "Write composed feedback to the feedback file (no checkpoint)",
    },
    ReviewLoopClose = { fn = function(c) c:close() end, desc = "Close the reviewer" },
    ReviewLoopNextComment = { fn = function(c) c:next_comment() end, desc = "Jump to next comment" },
    ReviewLoopPrevComment = { fn = function(c) c:prev_comment() end, desc = "Jump to previous comment" },
  }
  for name, spec in pairs(cmds) do
    vim.api.nvim_create_user_command(name, with_active(spec.fn, name), { desc = spec.desc })
  end
end

return M
