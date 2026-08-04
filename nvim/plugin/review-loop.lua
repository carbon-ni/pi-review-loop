-- Defines the :ReviewLoop user command. Sourced automatically when the plugin
-- is on runtimepath during startup.
if vim.g.loaded_review_loop == 1 then
  return
end
vim.g.loaded_review_loop = 1

vim.api.nvim_create_user_command("ReviewLoop", function()
  require("review-loop").open()
end, { desc = "Open the persistent incremental diff reviewer" })
