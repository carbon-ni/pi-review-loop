-- Regression: commenting a visual range must never store a phantom comment at
-- line 0 when the '< / '> marks are not yet committed (the "can't see it / can't
-- remove it" bug). See .tmp/reports/05-08-26/range-comment-invisible.md.
local ui = require("review-loop.ui")
local comments = require("review-loop.ui.comments")
local eq = assert.are.same

describe("comment_on_selection stale-mark handling", function()
  local ctrl, captured, original_win, modified_win, original_buf, modified_buf

  before_each(function()
    vim.cmd("tabnew")
    original_buf = vim.api.nvim_create_buf(false, true)
    modified_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(original_buf)
    original_win = vim.api.nvim_get_current_win()
    vim.cmd("vnew")
    modified_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_buf(modified_buf)
    vim.api.nvim_buf_set_lines(modified_buf, 0, -1, false,
      { "l1", "l2", "l3", "l4", "l5", "l6", "l7", "l8", "l9", "l10" })

    captured = nil
    ctrl = setmetatable({
      current_path = "a.txt",
      original_win = original_win,
      modified_win = modified_win,
      original_buf = original_buf,
      modified_buf = modified_buf,
      comments = comments.new(),
      _open_comment = function(_, side, s, e)
        captured = { side = side, s = s, e = e }
      end,
    }, { __index = ui })
  end)

  after_each(function()
    pcall(vim.cmd, "tabclose!")
  end)

  it("comments the full range when '< / '> are committed", function()
    vim.api.nvim_set_current_win(modified_win)
    vim.api.nvim_buf_set_mark(modified_buf, "<", 2, 0, {})
    vim.api.nvim_buf_set_mark(modified_buf, ">", 4, 0, {})

    ctrl:_comment_on_selection()

    assert.is_not_nil(captured)
    eq("modified", captured.side)
    eq(2, captured.s)
    eq(4, captured.e)
  end)

  it("falls back to the cursor line when '< / '> are stale (not committed)", function()
    vim.api.nvim_set_current_win(modified_win)
    vim.api.nvim_win_set_cursor(modified_win, { 5, 0 })
    -- Precondition: no selection recorded for this fresh buffer.
    eq(0, vim.fn.line("'<"))
    eq(0, vim.fn.line("'>"))

    ctrl:_comment_on_selection()

    assert.is_not_nil(captured, "_open_comment was not called")
    eq("modified", captured.side)
    eq(5, captured.s, "stale marks must fall back to the cursor line, not line 0")
    eq(5, captured.e)
  end)

  it("never renders a phantom comment that reached the store at line 0", function()
    comments.add(ctrl.comments, { path = "a.txt", side = "modified", line = 0, body = "phantom" })
    vim.api.nvim_buf_set_lines(modified_buf, 0, -1, false, { "a", "b", "c" })

    ctrl:_apply_extmarks()

    local ns = vim.api.nvim_get_namespaces()["review-loop"]
    local ms = vim.api.nvim_buf_get_extmarks(modified_buf, ns, 0, -1, {})
    eq(0, #ms, "a line-0 comment must not clamp onto line 1")
  end)
end)
