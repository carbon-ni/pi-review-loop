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

ctrl:close()
ok("all good")
print("SMOKE DONE")
