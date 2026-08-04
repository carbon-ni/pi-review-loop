-- Sourced at startup (plugin on runtimepath): registers :ReviewLoop* commands.
if vim.g.loaded_review_loop == 1 then
  return
end
vim.g.loaded_review_loop = 1

require("review-loop.commands").setup()
