-- Reviewer controller: review-loop owns model/comments/feedback while
-- diffview.nvim owns the file panel, diff buffers, and window lifecycle.

local git = require("review-loop.git")
local checkpoint = require("review-loop.checkpoint")
local Store = require("review-loop.store")
local Model = require("review-loop.state").WorkspaceModel
local feedback = require("review-loop.feedback")
local config = require("review-loop.config")
local log = require("review-loop.log")
local comments_store = require("review-loop.ui.comments")
local diffview = require("review-loop.ui.diff")

local M = {}
local NS = vim.api.nvim_create_namespace("review-loop")
local AU_GROUP = "ReviewLoopRefresh"
-- How often the HEAD poll checks for a new commit / branch switch (ms).
local HEAD_POLL_MS = 3000

M.active = nil

function M.open()
  local cwd = vim.fn.getcwd()
  local repo_root = git.repo_root(cwd)
  if repo_root == nil or repo_root == "" then
    repo_root = cwd
  end

  -- Load from the shared .review-loop/ store; fall back to the legacy
  -- per-repo checkpoint under stdpath("data")/review-loop/.
  local s = Store.new(repo_root)
  local stored = s:load()
  local cp = stored.checkpoint or checkpoint.load(repo_root)
  local model = Model.new(git, repo_root, cp)
  local store = comments_store.new()

  local self = setmetatable({}, { __index = M })
  self.repo_root = repo_root
  self.model = model
  self.comments = store
  self.store = s
  self._session = stored.session or {
    version = 1,
    repoRoot = repo_root,
    checkpointId = cp and cp.id or nil,
    mode = "checkpoint",
    comments = {},
    viewedPaths = {},
    activePath = nil,
    createdAt = os.time() * 1000,
    updatedAt = os.time() * 1000,
  }

  -- Restore comments and active file from saved session.
  if stored.session and stored.session.comments then
    for _, c in ipairs(stored.session.comments) do
      comments_store.add(store, c)
    end
  end
  if stored.session and stored.session.activePath then
    self.current_path = stored.session.activePath
  else
    self.current_path = nil
  end
  self.augroup = nil
  self.closed = false
  self.fs = nil
  self._head_timer = nil
  self.watching = false
  self._debounce = nil
  self.model:refresh()
  M.active = self
  self._lastHead = self.model.initialHead

  self.view = diffview.open({
    repo_root = repo_root,
    model = self.model,
    head_sha = function() return git.head_sha(repo_root) end,
    on_file_open = function(context) self:_on_file_open(context) end,
    on_close = function() self:_deactivate() end,
  })
  self.tab = self.view.tabpage
  self:_bind_panel()
  self:_watch()
  self:_start_watcher()
  self:_set_labels()
  log.debug("open", {
    repo_root = repo_root,
    has_checkpoint = self.model:current_checkpoint() ~= nil,
    mode = self.model:current_mode(),
  })
  return self
end

local function map(buf, mode, lhs, fn, desc)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.keymap.set(mode, lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
end

function M:_bind_panel()
  local buf = self.view and self.view.panel and self.view.panel.bufid
  local km = config.get().keymaps
  map(buf, "n", km.add_file_note, function() self:_note_under_cursor() end, "Add file note")
  map(buf, "n", km.refresh, function() self:refresh() end, "Refresh review")
  map(buf, "n", km.submit, function() self:submit() end, "Submit review")
  map(buf, "n", km.toggle_mode, function() self:toggle_mode() end, "Toggle review mode")
  map(buf, "n", km.close, function() self:close() end, "Close review")
end

function M:_on_file_open(context)
  self.current_path = context.path
  self.original_buf = context.original_buf
  self.modified_buf = context.modified_buf
  self.original_win = context.original_win
  self.modified_win = context.modified_win
  self.original_nulled = context.original_nulled
  self.modified_nulled = context.modified_nulled

  local km = config.get().keymaps
  for _, target in ipairs({
    { buf = self.original_buf, nulled = context.original_nulled },
    { buf = self.modified_buf, nulled = context.modified_nulled },
  }) do
    if not target.nulled then
      map(target.buf, "n", km.add_comment, function() self:_comment_under_cursor() end, "Add/edit comment")
      map(target.buf, "v", km.add_comment, function() self:_comment_on_selection() end, "Comment selected lines")
      map(target.buf, "n", km.delete_comment, function() self:_delete_under_cursor() end, "Delete comment")
      map(target.buf, "n", km.next_comment, function() self:next_comment() end, "Next comment")
      map(target.buf, "n", km.prev_comment, function() self:prev_comment() end, "Previous comment")
      map(target.buf, "n", km.refresh, function() self:refresh() end, "Refresh review")
      map(target.buf, "n", km.submit, function() self:submit() end, "Submit review")
      map(target.buf, "n", km.toggle_mode, function() self:toggle_mode() end, "Toggle review mode")
    end
  end
  self:_apply_extmarks()
  self:_set_labels()
end

-- BufWritePost autocmd: catches nvim's own writes instantly.
function M:_watch()
  if not config.get().auto_refresh then
    return
  end
  self.augroup = vim.api.nvim_create_augroup(AU_GROUP, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = self.augroup,
    callback = function()
      vim.schedule(function()
        if not self.closed then
          self:refresh()
        end
      end)
    end,
  })
end

-- Repo file watcher: catches external writes (the agent editing files in its
-- own process). Recursive on macOS (FSEvents); top-level only on Linux.
local function ignored_path(path)
  if not path then
    return false
  end
  return path:find("[\\/]%.git[\\/]") ~= nil or path:find("[\\/]node_modules[\\/]") ~= nil
end

function M:_start_watcher()
  if not config.get().auto_refresh or self.watching then
    return
  end
  local uv = vim.uv or vim.loop
  local ok, fs = pcall(uv.new_fs_event)
  if not ok or not fs then
    return
  end
  local started = pcall(function()
    fs:start(self.repo_root, { recursive = true }, function(err, path)
      if ignored_path(path) then
        return
      end
      if err or self.closed or self._debounce then
        return
      end
      self._debounce = vim.defer_fn(function()
        self._debounce = nil
        if not self.closed then
          self:refresh()
        end
      end, 150)
    end)
  end)
  if not started then
    return
  end
  self.fs = fs
  self:_start_head_poll()
  self.watching = true
end

-- HEAD poll: the file watcher ignores .git and (on Linux) is not recursive into
-- .git, so a new commit or branch switch would otherwise leave head-mode stale.
-- Polling HEAD and refreshing on change makes "vs HEAD" reliably live on every
-- platform instead of relying on a .git watcher event leaking through.
function M:_start_head_poll()
  if self._head_timer then
    return
  end
  local uv = vim.uv or vim.loop
  local timer = uv.new_timer()
  if not timer then
    return
  end
  timer:start(HEAD_POLL_MS, HEAD_POLL_MS, function()
    vim.schedule(function()
      if not self.closed then
        self:_poll_head()
      end
    end)
  end)
  self._head_timer = timer
end

-- _poll_head refreshes when HEAD has moved since the last check. Reads through
-- the model's injected git so the detection is unit-testable with a fake.
function M:_poll_head()
  local cur = self.model.git.head_sha(self.repo_root)
  if cur == nil or cur == self._lastHead then
    return
  end
  self._lastHead = cur
  -- Only head mode is baseline-affected by a new commit; checkpoint mode's
  -- baseline is fixed, so a commit must not perturb it.
  if self.model:current_mode() == "head" then
    self:refresh()
  end
end

function M:_stop_watcher()
  if self.fs then
    pcall(function() self.fs:stop() end)
    self.fs = nil
  end
  if self._head_timer then
    pcall(function() self._head_timer:stop() end)
    pcall(function() self._head_timer:close() end)
    self._head_timer = nil
  end
  self.watching = false
end

function M:toggle_watch()
  if self.watching then
    self:_stop_watcher()
  else
    self:_start_watcher()
  end
  self:_set_labels()
  vim.notify("Review-loop watcher " .. (self.watching and "on" or "off"), vim.log.levels.INFO)
end

-- Re-scan review-loop's model, then let Diffview reconcile its file entries.
function M:refresh()
  -- Diffview uses real LOCAL buffers on the right; reload agent writes before
  -- reconciling entries so an open file never shows stale content.
  pcall(vim.cmd, "checktime")
  local state = self.model:refresh()
  if self.view and not self.closed then
    diffview.refresh(self.view, self.model, git.head_sha(self.repo_root))
  end
  self:_set_labels()
  -- Keep the HEAD poll baseline in sync so a watcher-triggered refresh (the
  -- macOS .git leak) does not cause a redundant poll refresh right after.
  if self.model and self.model.git then
    self._lastHead = self.model.git.head_sha(self.repo_root)
  end
  return state
end

function M:_set_labels()
  local mode = self.model:current_mode()
  local left = mode == "checkpoint" and "Reviewed (since review)" or "Reviewed (HEAD)"
  local watch = self.watching and " *watching" or ""
  local mode_label = mode == "checkpoint" and "since review" or "vs HEAD"
  pcall(function()
    local panel = self.view and self.view.panel
    if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
      vim.wo[panel.winid].winbar = ("%s  [%s]%s"):format(self.model:state().repoName, mode_label, watch)
    end
    if self.original_win and vim.api.nvim_win_is_valid(self.original_win) then
      vim.wo[self.original_win].winbar = left
    end
    if self.modified_win and vim.api.nvim_win_is_valid(self.modified_win) then
      vim.wo[self.modified_win].winbar = "Current"
    end
  end)
end

function M:_note_under_cursor()
  local panel = self.view and self.view.panel
  local entry = panel and panel:get_item_at_cursor()
  local path = entry and entry.layout and entry.path or nil
  if path == nil then return end

  self:_edit("File note: " .. path, self:_existing_body(path, "file", nil), function(body)
    self:_upsert(path, "file", nil, nil, body)
    self:_apply_extmarks()
  end)
end

function M:_comment_under_cursor()
  if self.current_path == nil then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local side = win == self.original_win and "original" or "modified"
  local line = vim.api.nvim_win_get_cursor(win)[1]
  log.debug("comment.cursor", { path = self.current_path, side = side, line = line, win = win })
  self:_open_comment(side, line, line)
end

-- Visual selection (V / char): comment the range path:start-end.
function M:_comment_on_selection()
  if self.current_path == nil then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local side = win == self.original_win and "original" or "modified"
  -- Capture the raw marks BEFORE swap; this is the crux of range-comment o11y;
  -- if '< / '> are stale here the recorded range (and restore target) is wrong.
  local raw_lo, raw_hi = vim.fn.line("'<"), vim.fn.line("'>")
  local s, e = raw_lo, raw_hi
  if s > e then
    s, e = e, s
  end
  -- Stale-mark guard: '< / '> are committed only AFTER visual mode exits. If
  -- either still reads 0 the selection range is unknown. Storing line 0 would
  -- clamp the extmark to line 1 (invisible at the selection, undeletable there)
  -- so fall back to the cursor line, which sits inside the intended selection
  -- once visual mode has exited.
  if s == 0 or e == 0 then
    log.debug("selection.stale_marks", { mark_lo = raw_lo, mark_hi = raw_hi })
    local cur = vim.api.nvim_win_get_cursor(win)[1]
    s, e = cur, cur
  end
  log.debug("selection.read", {
    path = self.current_path, side = side, mode = vim.fn.mode(), win = win,
    mark_lo = raw_lo, mark_hi = raw_hi, s = s, e = e,
  })
  self:_open_comment(side, s, e)
end

function M:_open_comment(side, line_start, line_end)
  local le = (line_end and line_end > line_start) and line_end or nil
  local where = tostring(line_start)
  if le then
    where = line_start .. "-" .. le
  end
  local target_win = side == "original" and self.original_win or self.modified_win
  local target_line = line_start
  log.debug("comment.open", {
    path = self.current_path, side = side, line_start = line_start, line_end = le,
    target_win = target_win, target_line = target_line,
  })
  self:_edit(string.format("%s:%s (%s)", self.current_path, where, side),
    self:_existing_body(self.current_path, side, line_start, le), function(body)
      self:_upsert(self.current_path, side, line_start, le, body)
      self:_apply_extmarks()
      -- After the popup closes, return to the line we just commented on.
      -- Counters the diff pane jumping away (e.g. to the bottom) on close.
      vim.schedule(function()
        local valid = target_win and vim.api.nvim_win_is_valid(target_win)
        if self.closed or not valid then
          log.debug("restore.skip", {
            closed = self.closed, valid = valid,
            target_win = target_win, target_line = target_line,
          })
          return
        end
        pcall(vim.api.nvim_set_current_win, target_win)
        pcall(vim.api.nvim_win_set_cursor, target_win, { math.max(1, target_line), 0 })
        pcall(vim.api.nvim_win_call, target_win, function() vim.cmd("normal! zz") end)
        local actual = vim.api.nvim_win_get_cursor(target_win)[1]
        log.debug("restore.set", { target_win = target_win, target_line = target_line, actual = actual })
      end)
    end)
end

function M:_delete_under_cursor()
  if self.current_path == nil then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local side = win == self.original_win and "original" or "modified"
  local line = vim.api.nvim_win_get_cursor(win)[1]
  for _, c in ipairs(comments_store.for_path(self.comments, self.current_path)) do
    local lo = c.line or 0
    local hi = c.line_end or c.line or 0
    if lo > hi then lo, hi = hi, lo end
    if c.side == side and line >= lo and line <= hi then
      comments_store.remove(self.comments, c.id)
      self:_apply_extmarks()
      return
    end
  end
end

function M:_existing_body(path, side, line, line_end)
  for _, c in ipairs(comments_store.for_path(self.comments, path)) do
    if c.side == side and c.line == line and (c.line_end or line) == (line_end or line) then
      return c.body
    end
  end
  return ""
end

-- _upsert edits an existing same-location comment, or adds one. A blank body
-- removes the comment at that location (matches the editor's discard intent).
function M:_upsert(path, side, line, line_end, body)
  body = body or ""
  local has_text = body:match("%S") ~= nil
  for _, c in ipairs(comments_store.for_path(self.comments, path)) do
    if c.side == side and c.line == line and (c.line_end or line) == (line_end or line) then
      if has_text then
        comments_store.update(self.comments, c.id, body)
      else
        comments_store.remove(self.comments, c.id)
      end
      return
    end
  end
  if has_text then
    comments_store.add(self.comments, {
      path = path, mode = self.model:current_mode(), side = side,
      line = line, line_end = line_end, body = body,
    })
  end
end

-- _apply_extmarks draws a "+" glyph on commented lines and a file-note banner.
function M:_apply_extmarks()
  local function clear(buf, nulled)
    if buf and not nulled and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    end
  end
  clear(self.original_buf, self.original_nulled)
  clear(self.modified_buf, self.modified_nulled)
  if self.current_path == nil then return end
  for _, c in ipairs(comments_store.for_path(self.comments, self.current_path)) do
    if c.body:match("%S") then
      local label = c.body
      if c.line_end and c.line_end > (c.line or 0) then
        label = string.format("[%d-%d] %s", c.line, c.line_end, c.body)
      end
      local opts = { sign_text = "+", priority = 20, virt_text = { { label, "Comment" } } }
      if c.side == "file" then
        local buf = self.modified_nulled and self.original_buf or self.modified_buf
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, 0, 0, opts)
      elseif c.line and c.line > 0 then
        -- line <= 0 is never a valid target; skip rather than clamp onto line 1.
        local buf = c.side == "original" and self.original_buf or self.modified_buf
        local nulled = c.side == "original" and self.original_nulled or self.modified_nulled
        if c.line_end and c.line_end > (c.line or 0) then
          opts.end_row = math.max(0, c.line_end - 1)
        end
        if not nulled then
          pcall(vim.api.nvim_buf_set_extmark, buf, NS, math.max(0, c.line - 1), 0, opts)
        end
      end
    end
  end
end

-- Jump to the next/previous line comment in the current file (wraps around).
-- Lands on the comment's pane (switching side if needed) and centers it.
function M:_goto_comment(c)
  local win = (c.side == "original") and self.original_win or self.modified_win
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, c.line or 1), 0 })
    pcall(vim.api.nvim_win_call, win, function() vim.cmd("normal! zz") end)
  end
end

function M:_jump_comment(direction)
  if self.current_path == nil then
    return
  end
  local cur_line = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1]
  local items = {}
  for _, c in ipairs(comments_store.for_path(self.comments, self.current_path)) do
    if c.line and c.body:match("%S") then
      items[#items + 1] = c
    end
  end
  if #items == 0 then
    vim.notify("No comments in " .. self.current_path, vim.log.levels.INFO)
    return
  end
  table.sort(items, function(a, b) return (a.line or 0) < (b.line or 0) end)
  local target
  if direction >= 0 then
    for _, c in ipairs(items) do
      if (c.line or 0) > cur_line then
        target = c
        break
      end
    end
    target = target or items[1]
  else
    for i = #items, 1, -1 do
      if (items[i].line or 0) < cur_line then
        target = items[i]
        break
      end
    end
    target = target or items[#items]
  end
  self:_goto_comment(target)
end

function M:next_comment()
  self:_jump_comment(1)
end

function M:prev_comment()
  self:_jump_comment(-1)
end

function M:_save_session()
  self._session.mode = self.model:current_mode()
  self._session.comments = comments_store.to_review_comments(self.comments)
  self._session.activePath = self.current_path
  local cp = self.model:current_checkpoint()
  self._session.checkpointId = cp and cp.id or nil
  self.store:save_session(self._session)
end

function M:toggle_mode()
  self.model:set_mode(self.model:current_mode() == "checkpoint" and "head" or "checkpoint")
  self:_save_session()
  self:refresh()
end

-- submit() checkpoints the workspace, delivers feedback, and returns its path.
function M:submit()
  local composed = feedback.compose(comments_store.to_review_comments(self.comments))
  local reviewed_paths = self.model:checkpoint_changed_paths()
  local ok, cp = pcall(git.create_checkpoint, self.repo_root, reviewed_paths, composed)
  if not ok then
    log.debug("submit", { saved = false, err = tostring(cp) })
    vim.notify("Could not save checkpoint: " .. tostring(cp), vim.log.levels.ERROR)
    return
  end
  self.store:save_checkpoint(cp)
  self.model:set_checkpoint(cp)
  self.comments = comments_store.new()
  self._session.comments = {}
  self._session.checkpointId = cp.id
  self.store:save_session(self._session)
  self:refresh()
  log.debug("submit", { saved = true, composed_len = #composed, reviewed = #reviewed_paths })
  return self:deliver(composed)
end

-- Composed feedback from the live comment set (no checkpoint).
function M:_composed()
  return feedback.compose(comments_store.to_review_comments(self.comments))
end

function M:yank_feedback()
  local fb = self:_composed()
  if fb == "" then
    vim.notify("No comments to yank.", vim.log.levels.WARN)
    return
  end
  vim.fn.setreg("+", fb)
  vim.notify("Feedback yanked to \"+.", vim.log.levels.INFO)
end

function M:open_feedback()
  local fb = self:_composed()
  vim.cmd("split")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(fb, "\n", { plain = true }))
  vim.api.nvim_win_set_buf(0, buf)
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true, desc = "Close preview" })
  vim.notify(fb == "" and "No comments yet." or "Feedback preview (q to close).", vim.log.levels.INFO)
end

-- send_feedback() submits the review and copies the delivered file path to the
-- system clipboard.
function M:send_feedback()
  if self:_composed() == "" then
    vim.notify("No comments to send.", vim.log.levels.WARN)
    return
  end
  local path = self:submit()
  if not path then
    return
  end
  vim.fn.setreg("+", path)
  vim.notify("Feedback path copied to + register.", vim.log.levels.INFO)
end

-- deliver(fb) writes composed feedback to the feedback file, notifies the path,
-- and returns it.
function M:deliver(fb)
  if fb == "" then
    vim.notify("Review checkpoint saved (no comments).", vim.log.levels.INFO)
    return
  end
  local path = self:_feedback_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(fb)
  f:close()
  vim.notify("Feedback written to " .. path, vim.log.levels.INFO)
  return path
end

-- _feedback_path() -> configured path, else a stable path outside the worktree.
function M:_feedback_path()
  local cfg = config.get()
  if cfg.feedback_file and cfg.feedback_file ~= "" then
    return vim.fn.expand(cfg.feedback_file)
  end
  return vim.fn.stdpath("data") .. "/review-loop/feedback.md"
end

function M:_deactivate()
  self.closed = true
  self:_save_session()
  log.debug("close", {})
  self:_stop_watcher()
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  if M.active == self then M.active = nil end
end

function M:close()
  if self.closed then return end
  local view = self.view
  self:_deactivate()
  self.view = nil
  diffview.close(view)
end

-- _edit opens a floating editor. on_save(body) runs when the window closes
-- (closing == save) and on :w/:x, so the comment is never lost regardless of
-- how the window is dismissed. A blank body discards the comment.
function M:_edit(title, initial, on_save)
  local row = math.floor(vim.o.lines * 0.3)
  local col = math.floor(vim.o.columns * 0.25)
  local width = math.floor(vim.o.columns * 0.5)
  local height = 12
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "wipe" -- closing the window wipes the buffer -> save
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial, "\n", { plain = true }))
  vim.bo[buf].modified = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = row, col = col, width = width, height = height,
    border = "rounded",
    title = title .. "  (:w save | :x save&close | clear to discard)",
    title_pos = "center",
  })
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = true

  local function save_body()
    local body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    pcall(on_save, body)
  end
  -- Closing wipes the buffer -> save. Fires once, covers :q / <CR> / mouse.
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = save_body })
  -- :w / :x / :wq also save and clear the modified flag so quit is clean.
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = function()
    save_body()
    vim.bo[buf].modified = false
  end })

  -- Opens in NORMAL mode so motions/operators work immediately (vim-like):
  -- press i/a/o to insert, <Esc> to leave insert. <CR>/q close (save);
  -- :w/:x/:q are stock vim. Clearing the text and closing discards the comment.
  local function close()
    pcall(vim.api.nvim_win_close, win, true)
  end
  vim.keymap.set("n", "<CR>", close, { buffer = buf, silent = true, desc = "Save & close" })
  vim.keymap.set("n", "q", close, { buffer = buf, silent = true, desc = "Save & close" })
  vim.keymap.set("i", "<C-CR>", close, { buffer = buf, silent = true, desc = "Save & close" })
end

return M
