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

-- Simulate comments: a single line and a visual line-range.
ctrl:_upsert("a.txt", "modified", 2, nil, "new line needs a test")
ctrl:_upsert("a.txt", "modified", 1, 2, "watch the range")
ctrl:_apply_extmarks()

-- Send and verify checkpoint persistence, feedback delivery, and copied path.
ctrl:send_feedback()
local fb_path = ctrl:_feedback_path()
if vim.fn.getreg("+") ~= fb_path then fail("send did not copy feedback path to + register") end
-- Send must write the composed feedback to the feedback file.

local f = io.open(fb_path, "r")
if f == nil then fail("feedback file not written: " .. fb_path) end
local written = f:read("*a"); f:close()
if not written:find("a.txt:2 %(current%)") then fail("feedback file missing single-line comment: " .. written) end
if not written:find("a%.txt:1%-2 %(current%)") then fail("feedback file missing range comment: " .. written) end
ok("feedback written to " .. fb_path)
local cp = require("review-loop.checkpoint").load(ctrl.repo_root)
if cp == nil then fail("checkpoint not persisted") end
if cp.feedback == "" then fail("checkpoint feedback empty") end
if not cp.feedback:find("a.txt:2 %(current%)") then fail("feedback missing single-line comment: " .. tostring(cp.feedback)) end
if not cp.feedback:find("a%.txt:1%-2 %(current%)") then fail("feedback missing range comment: " .. tostring(cp.feedback)) end
if cp.headSha == nil or cp.headSha == "" then fail("checkpoint headSha missing") end
ok("checkpoint saved; headSha=" .. cp.headSha:sub(1, 8))
ok("feedback:\n" .. cp.feedback)

-- After submit, the checkpoint baseline equals current -> nothing pending.
ctrl:refresh()
if #ctrl.model:checkpoint_changed_paths() ~= 0 then
  fail("expected no pending changes right after submit")
end

-- Layout: sidebar (nav) 16%, original 42%; both diff panes scroll together.
local cols = vim.o.columns
local sw = vim.api.nvim_win_get_width(ctrl.sidebar_win)
local ow = vim.api.nvim_win_get_width(ctrl.original_win)
if math.abs(sw - math.floor(0.16 * cols)) > 2 then
  fail(string.format("sidebar width %d ~= 16%% of %d", sw, cols))
end
if math.abs(ow - math.floor(0.42 * cols)) > 2 then
  fail(string.format("original width %d ~= 42%% of %d", ow, cols))
end
if not (vim.wo[ctrl.original_win].scrollbind and vim.wo[ctrl.modified_win].scrollbind) then
  fail("diff panes do not have scrollbind set")
end
ok(string.format("layout 16/42/42 + scrollbind (cols=%d)", cols))

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

-- next_comment / prev_comment jump between comments and wrap.
-- Re-dirty a.txt so the diff buffer has lines to jump within (submit cleared it).
write("a.txt", "line1\nline2\nline3\n")
ctrl:refresh()
do
  local cs = require("review-loop.ui.comments")
  ctrl.current_path = "a.txt"
  cs.add(ctrl.comments, { path = "a.txt", mode = "checkpoint", side = "modified", line = 1, body = "one" })
  cs.add(ctrl.comments, { path = "a.txt", mode = "checkpoint", side = "modified", line = 2, body = "two" })
  ctrl:_apply_extmarks()
  vim.api.nvim_set_current_win(ctrl.modified_win)
  vim.api.nvim_win_set_cursor(ctrl.modified_win, { 1, 0 })
  ctrl:next_comment()
  local l1 = vim.api.nvim_win_get_cursor(ctrl.modified_win)[1]
  if l1 ~= 2 then fail("next_comment expected line 2 got " .. l1) end
  ctrl:next_comment() -- wraps to first
  local l2 = vim.api.nvim_win_get_cursor(ctrl.modified_win)[1]
  if l2 ~= 1 then fail("next_comment wrap expected line 1 got " .. l2) end
  ok("next_comment jumps + wraps")
end

-- Closing the comment popup returns the cursor to the commented line.
do
  ctrl.current_path = "a.txt"
  vim.api.nvim_set_current_win(ctrl.modified_win)
  vim.api.nvim_win_set_cursor(ctrl.modified_win, { 1, 0 })
  ctrl:_open_comment("modified", 2, 2)
  pcall(vim.api.nvim_win_close, 0, true) -- close the popup (saves)
  vim.wait(50) -- let the scheduled cursor restore run
  local l = vim.api.nvim_win_get_cursor(ctrl.modified_win)[1]
  if l ~= 2 then
    fail("comment popup should return cursor to line 2, got " .. l)
  end
  ok("comment popup returns to commented line")
end

ctrl:close()
ok("all good")
print("SMOKE DONE")
