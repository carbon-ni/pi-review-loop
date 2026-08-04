-- review-loop.nvim entry point.
local M = {}

function M.setup(opts)
  require("review-loop.config").setup(opts)
end

-- open() builds and shows the reviewer in a new tab. Returns the controller.
function M.open()
  return require("review-loop.ui").open()
end

return M
