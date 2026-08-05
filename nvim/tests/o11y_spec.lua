-- Observability + cursor-restore regression. Builds a real reviewer, drives a
-- range comment through the popup (marks set the way interactive visual mode
-- sets them), and asserts both the cursor lands on the first line AND the log
-- captured the decision points. Headless cannot drive real visual mode, so we
-- set '< / '> directly -- this is exactly what Neovim provides to the mapping.
local log = require("review-loop.log")
local eq = assert.are.same

local function make_repo()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local function sh(cmd) vim.system({ "sh", "-c", "cd " .. repo .. " && " .. cmd }):wait() end
  sh("git init -q && git config user.email t@t.t && git config user.name t")
  local function write(p, b) local f = assert(io.open(repo .. "/" .. p, "w")); f:write(b); f:close() end
  write("a.txt", "l1\n")
  sh("git add -A && git commit -q -m init")
  write("a.txt", "l1\nl2\nl3\nl4\nl5\nl6\n") -- dirty vs HEAD
  return repo
end

describe("range comment o11y + cursor restore", function()
  local repo, ctrl, dir

  before_each(function()
    repo = make_repo()
    dir = vim.fn.tempname() .. "-rl-o11y"
    log.data_dir = dir
    log.set_enabled(true)
    vim.cmd("cd " .. repo)
    require("review-loop").setup({})
    ctrl = require("review-loop").open()
    -- Diffview auto-selects the most recent file and fires on_file_open
    -- asynchronously with its real diff windows; wait for it, then the comment
    -- flow drives against those windows.
    assert(vim.wait(2000, function() return ctrl.current_path ~= nil end), "diffview should auto-open a file")
    assert(ctrl.current_path == "a.txt", "diffview should have auto-opened a.txt")
    log.clear() -- drop any events from open()/refresh so assertions are scoped
  end)

  after_each(function()
    if ctrl and not ctrl.closed then ctrl:close() end
    log.set_enabled(false)
    log.data_dir = nil
    log._enabled = nil
    vim.cmd("cd " .. repo:gsub("%s", "\\ "))
    pcall(vim.fn.delete, repo, "rf")
    pcall(vim.fn.delete, dir, "rf")
  end)

  local function log_text()
    return table.concat(vim.fn.readfile(log.path()), "\n")
  end

  -- find the first log line for an event, then check it carries whole tokens
  local function line_for(txt, event)
    for line in txt:gmatch("[^\n]+") do
      if line:find(event, 1, true) then return line end
    end
    return ""
  end
  local function has_token(line, kv)
    -- kv like "s=2"; must be a whole space-delimited token (not a prefix of another)
    return line:find(" " .. kv .. " ", 1, true) ~= nil
        or line:sub(-#kv - 1) == " " .. kv
  end

  it("logs selection.read -> comment.open -> restore.set and lands on the first line", function()
    vim.api.nvim_set_current_win(ctrl.modified_win)
    vim.api.nvim_buf_set_mark(ctrl.modified_buf, "<", 2, 0, {})
    vim.api.nvim_buf_set_mark(ctrl.modified_buf, ">", 5, 0, {})

    ctrl:_comment_on_selection()

    -- popup is current; type a body, close (save) -> on_save -> scheduled restore
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "range body" })
    pcall(vim.api.nvim_win_close, 0, true)
    vim.wait(80)

    -- restore brought us back to the modified pane with the cursor on the
    -- FIRST line of the range
    eq(ctrl.modified_win, vim.api.nvim_get_current_win())
    eq(2, vim.api.nvim_win_get_cursor(ctrl.modified_win)[1])

    local txt = log_text()
    local sel = line_for(txt, "selection.read")
    local opened = line_for(txt, "comment.open")
    local restored = line_for(txt, "restore.set")
    assert.truthy(sel ~= "", "missing selection.read\n" .. txt)
    assert.is_true(has_token(sel, "mark_lo=2"), "raw low mark:\n" .. sel)
    assert.is_true(has_token(sel, "mark_hi=5"), "raw high mark:\n" .. sel)
    assert.is_true(has_token(sel, "s=2"), "resolved start:\n" .. sel)
    assert.is_true(has_token(sel, "e=5"), "resolved end:\n" .. sel)
    assert.truthy(opened ~= "", "missing comment.open\n" .. txt)
    assert.is_true(has_token(opened, "line_start=2"), "open line_start:\n" .. opened)
    assert.is_true(has_token(opened, "line_end=5"), "open line_end:\n" .. opened)
    assert.is_true(has_token(opened, "target_line=2"), "open target_line:\n" .. opened)
    assert.truthy(restored ~= "", "missing restore.set\n" .. txt)
    assert.is_true(has_token(restored, "target_line=2"), "restore target_line:\n" .. restored)
    assert.is_true(has_token(restored, "actual=2"), "restore actual landing:\n" .. restored)
  end)

  it("logs restore.skip when the reviewer is closed before the popup saves", function()
    vim.api.nvim_set_current_win(ctrl.modified_win)
    vim.api.nvim_buf_set_mark(ctrl.modified_buf, "<", 3, 0, {})
    vim.api.nvim_buf_set_mark(ctrl.modified_buf, ">", 3, 0, {})
    ctrl:_comment_on_selection()
    -- close the whole reviewer while the popup is open, then save the popup.
    ctrl:close()
    pcall(vim.api.nvim_win_close, 0, true)
    vim.wait(80)
    assert.truthy(log_text():find("restore%.skip"), "expected restore.skip after close\n" .. log_text())
  end)
end)
