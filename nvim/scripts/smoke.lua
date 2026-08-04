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

require("diffview").setup({ use_icons = false })
local rl = require("review-loop")
rl.setup({})
local ctrl = rl.open()
if ctrl == nil then fail("open() returned nil") end

local state = ctrl.model:state()
if #state.files == 0 then fail("no changed files after open") end
if not ctrl.view then fail("Diffview custom view was not created") end
if not vim.wait(1000, function()
  return ctrl.current_path == "a.txt"
    and ctrl.original_win and vim.api.nvim_win_is_valid(ctrl.original_win)
    and ctrl.modified_win and vim.api.nvim_win_is_valid(ctrl.modified_win)
end, 10) then
  fail("Diffview did not open the selected file")
end
if not (ctrl.view.panel and ctrl.view.panel:is_open()) then fail("Diffview file panel is not open") end
if not (vim.wo[ctrl.original_win].scrollbind and vim.wo[ctrl.modified_win].scrollbind) then
  fail("Diffview panes do not have scrollbind set")
end
ok(#state.files .. " changed file(s) rendered by Diffview; mode=" .. state.mode)

-- External writes must reload an already-open LOCAL buffer.
write("a.txt", "line1\nline2\nline3\n")
ctrl:refresh()
if not vim.wait(1000, function()
  return ctrl.modified_buf and vim.api.nvim_buf_is_valid(ctrl.modified_buf)
    and vim.api.nvim_buf_line_count(ctrl.modified_buf) == 3
end, 10) then
  fail("Diffview did not reload an external write")
end
ok("external write refreshed in Diffview")

ctrl:toggle_mode()
if ctrl.model:current_mode() ~= "head" then fail("mode did not toggle to head") end
ctrl:toggle_mode()
if ctrl.model:current_mode() ~= "checkpoint" then fail("mode did not toggle back to checkpoint") end
ok("Diffview follows checkpoint/head mode toggles")

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
write("a.txt", "line1\nline2\nline3\nline4\n")
ctrl:refresh()
if not vim.wait(1000, function()
  return ctrl.original_buf and vim.api.nvim_buf_is_valid(ctrl.original_buf)
    and ctrl.modified_buf and vim.api.nvim_buf_is_valid(ctrl.modified_buf)
    and vim.api.nvim_buf_line_count(ctrl.original_buf) == 3
    and vim.api.nvim_buf_line_count(ctrl.modified_buf) == 4
end, 10) then
  local original_count = ctrl.original_buf and vim.api.nvim_buf_is_valid(ctrl.original_buf)
    and vim.api.nvim_buf_line_count(ctrl.original_buf) or -1
  local modified_count = ctrl.modified_buf and vim.api.nvim_buf_is_valid(ctrl.modified_buf)
    and vim.api.nvim_buf_line_count(ctrl.modified_buf) or -1
  local model_file = ctrl.model:get_file("a.txt", "checkpoint")
  fail(string.format("checkpoint/current lines were %d/%d, expected 3/4; model baseline=%q",
    original_count, modified_count, model_file.originalContent))
end
ok("checkpoint snapshot rendered as Diffview baseline")
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
