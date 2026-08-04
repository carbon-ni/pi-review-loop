-- luacheck config for review-loop.nvim (this file is evaluated as Lua).
-- `vim` is the only global the runtime introduces; everything else is std lua.
std = "luajit"
globals = { "vim" }

-- Unused arguments are common in nvim callbacks / method receivers.
ignore = { "212" }

-- Test files use plenary's busted-style globals (describe/it/before_each/assert).
files["tests/*.lua"] = {
  std = "luajit+busted", -- keep lua stdlib, add describe/it/assert
  globals = { "vim" },
}
