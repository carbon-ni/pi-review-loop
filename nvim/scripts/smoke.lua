-- End-to-end smoke test for review-loop.nvim, run headless.
-- Builds a throwaway git repo, opens the reviewer, simulates a comment, submits,
-- and asserts the checkpoint was persisted with the composed feedback.
local function fail(msg)
  print("SMOKE FAIL: " .. msg)
  vim.cmd("cquit 1")
end

local function ok(msg)
  print("SMOKE OK: " .. msg)
end

local repo = vim.fn.tempname()
vim.fn.mkdir(repo, "p")
vim.system({ "sh", "-c", "cd " .. repo .. " && git init -q && git config user.email t@t.t && git config user.name t" }):wait()
local function write(path, content)
  local f = assert(io.open(repo .. "/" .. path, "w")); f:write(content); f:close()
end
write("a.txt", "line1\n")
vim.system({ "sh", "-c", "cd " .. repo .. " && git add -A && git commit -q -m init" }):wait()
write("a.txt", "line1\nline2\n")   -- now dirty vs HEAD

vim.cmd("cd " .. repo)

local rl = require("review-loop")
rl.setup({})
local ctrl = rl.open()
if ctrl == nil then fail("open() returned nil") end

local state = ctrl.model:state()
if #state.files == 0 then fail("no changed files after open") end
ok(#state.files .. " changed file(s); mode=" .. state.mode)

-- Simulate adding an inline comment on the modified pane, line 2.
ctrl:_upsert("a.txt", "modified", 2, "new line needs a test")
ctrl:_apply_extmarks()

-- Submit and verify persistence.
ctrl:submit()
-- Submit must write the composed feedback to the feedback file (no tmux/clipboard).
local fb_path = ctrl:_feedback_path()
local f = io.open(fb_path, "r")
if f == nil then fail("feedback file not written: " .. fb_path) end
local written = f:read("*a"); f:close()
if not written:find("a.txt:2 %(current%)") then fail("feedback file missing comment: " .. written) end
ok("feedback written to " .. fb_path)
local cp = require("review-loop.checkpoint").load(ctrl.repo_root)
if cp == nil then fail("checkpoint not persisted") end
if cp.feedback == "" then fail("checkpoint feedback empty") end
if not cp.feedback:find("a.txt:2 %(current%)") then fail("feedback missing comment: " .. tostring(cp.feedback)) end
if cp.headSha == nil or cp.headSha == "" then fail("checkpoint headSha missing") end
ok("checkpoint saved; headSha=" .. cp.headSha:sub(1, 8))
ok("feedback:\n" .. cp.feedback)

-- After submit, the checkpoint baseline equals current -> nothing pending.
ctrl:refresh()
if #ctrl.model:checkpoint_changed_paths() ~= 0 then
  fail("expected no pending changes right after submit")
end

-- Layout: sidebar 20%, original 40%; both diff panes scroll together.
local cols = vim.o.columns
local sw = vim.api.nvim_win_get_width(ctrl.sidebar_win)
local ow = vim.api.nvim_win_get_width(ctrl.original_win)
if math.abs(sw - math.floor(0.2 * cols)) > 2 then
  fail(string.format("sidebar width %d ~= 20%% of %d", sw, cols))
end
if math.abs(ow - math.floor(0.4 * cols)) > 2 then
  fail(string.format("original width %d ~= 40%% of %d", ow, cols))
end
if not (vim.wo[ctrl.original_win].scrollbind and vim.wo[ctrl.modified_win].scrollbind) then
  fail("diff panes do not have scrollbind set")
end
ok(string.format("layout 20/40/40 + scrollbind (cols=%d)", cols))

-- Regression: comment editor must save on close (closing via any means).
local captured = nil
ctrl.current_path = "a.txt"
ctrl:_edit("t", "", function(b) captured = b end)
-- _edit opened a floating win (now current); simulate typing then close it.
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "hello comment" })
pcall(vim.api.nvim_win_close, 0, true)
vim.cmd("redraw") -- let BufWipeout autocmd flush
if captured ~= "hello comment" then
  fail("comment editor did not save on close: " .. tostring(captured))
end
ok("comment editor saves on close")

ctrl:close()
ok("all good")
print("SMOKE DONE")
