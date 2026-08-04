-- Reviewer controller: owns windows/buffers, the WorkspaceModel, the comment
-- store, the keymaps, the repo file watcher, and feedback-file delivery.
-- One active instance per open() call; M.active references it for commands.

local git = require("review-loop.git")
local checkpoint = require("review-loop.checkpoint")
local Model = require("review-loop.state").WorkspaceModel
local feedback = require("review-loop.feedback")
local config = require("review-loop.config")
local comments_store = require("review-loop.ui.comments")
local sidebar = require("review-loop.ui.sidebar")
local diffview = require("review-loop.ui.diff")

local M = {}
local NS = vim.api.nvim_create_namespace("review-loop")
local AU_GROUP = "ReviewLoopRefresh"

-- Active controller; auxiliary commands operate on this.
M.active = nil

-- open() -> controller table.
function M.open()
  local cwd = vim.fn.getcwd()
  local repo_root = git.repo_root(cwd)
  if repo_root == nil or repo_root == "" then
    repo_root = cwd
  end

  local cp = checkpoint.load(repo_root)
  local model = Model.new(git, repo_root, cp)
  local store = comments_store.new()

  local self = setmetatable({}, { __index = M })
  self.repo_root = repo_root
  self.model = model
  self.comments = store
  self.current_path = nil
  self.augroup = nil
  self.closed = false
  self.fs = nil
  self.watching = false
  self._debounce = nil
  self:_layout()
  self:_keymaps()
  self:_watch()
  self:_start_watcher()
  self:refresh()
  M.active = self
  return self
end

-- Build the three-window layout: sidebar | original | modified.
function M:_layout()
  vim.cmd("tabnew")
  self.tab = vim.api.nvim_get_current_tabpage()

  self.sidebar_win = vim.api.nvim_get_current_win()
  local width = config.get().width
  vim.api.nvim_win_set_width(self.sidebar_win, width)
  self.sidebar_buf = self:_scratch("review-loop-sidebar", true)
  vim.api.nvim_win_set_buf(self.sidebar_win, self.sidebar_buf)
  vim.wo[self.sidebar_win].cursorline = true
  vim.wo[self.sidebar_win].wrap = false

  vim.cmd("botright vnew")
  self.original_win = vim.api.nvim_get_current_win()
  self.original_buf = self:_scratch("review-loop-original")
  vim.api.nvim_win_set_buf(self.original_win, self.original_buf)

  vim.cmd("botright vnew")
  self.modified_win = vim.api.nvim_get_current_win()
  self.modified_buf = self:_scratch("review-loop-modified")
  vim.api.nvim_win_set_buf(self.modified_win, self.modified_buf)

  local diff_w = math.floor((vim.o.columns - width) / 2)
  pcall(vim.api.nvim_win_set_width, self.original_win, diff_w)

  vim.api.nvim_set_current_win(self.sidebar_win)
end

function M:_scratch(name, listed)
  local buf = vim.api.nvim_create_buf(listed == true, false)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  return buf
end

function M:_keymaps()
  local km = config.get().keymaps
  local function map(buf, lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, desc = desc })
  end

  local sb = self.sidebar_buf
  map(sb, km.open_file, function() self:_open_under_cursor() end, "Open file under cursor")
  map(sb, km.add_file_note, function() self:_note_under_cursor() end, "Add file note")
  map(sb, km.refresh, function() self:refresh() end, "Refresh")
  map(sb, km.submit, function() self:submit() end, "Submit review")
  map(sb, km.toggle_mode, function() self:toggle_mode() end, "Toggle diff mode")
  map(sb, km.close, function() self:close() end, "Close")

  for _, buf in ipairs({ self.original_buf, self.modified_buf }) do
    map(buf, km.add_comment, function() self:_comment_under_cursor() end, "Add/edit comment")
    map(buf, km.delete_comment, function() self:_delete_under_cursor() end, "Delete comment")
    map(buf, km.refresh, function() self:refresh() end, "Refresh")
    map(buf, km.submit, function() self:submit() end, "Submit review")
    map(buf, km.toggle_mode, function() self:toggle_mode() end, "Toggle diff mode")
  end
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
  self.watching = true
end

function M:_stop_watcher()
  if self.fs then
    pcall(function() self.fs:stop() end)
    self.fs = nil
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

-- refresh() re-scans, re-renders the sidebar, reloads the current file, labels.
function M:refresh()
  local state = self.model:refresh()
  sidebar.render(self.sidebar_buf, state, self.comments)

  if self.current_path == nil and #state.recentPaths > 0 then
    self.current_path = state.recentPaths[1]
  end

  if self.current_path ~= nil then
    local file = self:_file_or_nil(self.current_path)
    if file then
      diffview.show(self:_diff_ctx(), file)
    else
      self.current_path = nil
      self:_clear_diff()
    end
  else
    self:_clear_diff()
  end
  self:_apply_extmarks()
  self:_set_labels()
end

-- winbar labels: which pane is the baseline vs current, plus mode/watch state.
function M:_set_labels()
  local mode = self.model:current_mode()
  local left = mode == "checkpoint" and "Reviewed (since review)" or "Reviewed (HEAD)"
  local watch = self.watching and " *watching" or ""
  local m = mode == "checkpoint" and "since review" or "vs HEAD"
  pcall(function()
    vim.wo[self.sidebar_win].winbar = ("%s  [%s]%s"):format(self.model:state().repoName, m, watch)
    vim.wo[self.original_win].winbar = left
    vim.wo[self.modified_win].winbar = "Current"
  end)
end

function M:_diff_ctx()
  return {
    original_win = self.original_win,
    modified_win = self.modified_win,
    original_buf = self.original_buf,
    modified_buf = self.modified_buf,
  }
end

function M:_file_or_nil(path)
  local state = self.model:state()
  for _, f in ipairs(state.files) do
    if f.path == path then
      local ok, file = pcall(self.model.get_file, self.model, path, self.model:current_mode())
      if ok then
        return file
      end
    end
  end
  return nil
end

function M:_clear_diff()
  for _, buf in ipairs({ self.original_buf, self.modified_buf }) do
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    vim.bo[buf].modifiable = false
  end
  vim.api.nvim_buf_clear_namespace(self.original_buf, NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.modified_buf, NS, 0, -1)
end

function M:_open_under_cursor()
  local path = sidebar.line_to_path[vim.api.nvim_win_get_cursor(self.sidebar_win)[1]]
  if path == nil then
    return
  end
  if self.current_path ~= nil then
    diffview.remember(self:_diff_ctx(), self.current_path, self.model:current_mode())
  end
  self.current_path = path
  local file = self:_file_or_nil(path)
  if file then
    diffview.show(self:_diff_ctx(), file)
    self:_apply_extmarks()
    self:_set_labels()
  end
end

function M:_note_under_cursor()
  local path = sidebar.line_to_path[vim.api.nvim_win_get_cursor(self.sidebar_win)[1]]
  if path == nil then
    return
  end
  self:_edit("File note: " .. path, self:_existing_body(path, "file", nil), function(body)
    self:_upsert(path, "file", nil, body)
    self:refresh()
  end)
end

function M:_comment_under_cursor()
  if self.current_path == nil then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local side = win == self.original_win and "original" or "modified"
  local line = vim.api.nvim_win_get_cursor(win)[1]
  self:_edit(string.format("%s:%d (%s)", self.current_path, line, side),
    self:_existing_body(self.current_path, side, line), function(body)
      self:_upsert(self.current_path, side, line, body)
      self:_apply_extmarks()
      sidebar.render(self.sidebar_buf, self.model:state(), self.comments)
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
    if c.side == side and c.line == line then
      comments_store.remove(self.comments, c.id)
      self:_apply_extmarks()
      sidebar.render(self.sidebar_buf, self.model:state(), self.comments)
      return
    end
  end
end

function M:_existing_body(path, side, line)
  for _, c in ipairs(comments_store.for_path(self.comments, path)) do
    if c.side == side and c.line == line then
      return c.body
    end
  end
  return ""
end

-- _upsert edits an existing same-location comment, or adds one. A blank body
-- removes the comment at that location (matches the editor's discard intent).
function M:_upsert(path, side, line, body)
  local has_text = body:match("%S") ~= nil
  for _, c in ipairs(comments_store.for_path(self.comments, path)) do
    if c.side == side and c.line == line then
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
      path = path, mode = self.model:current_mode(), side = side, line = line, body = body,
    })
  end
end

-- _apply_extmarks draws a "+" glyph on commented lines and a file-note banner.
function M:_apply_extmarks()
  vim.api.nvim_buf_clear_namespace(self.original_buf, NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(self.modified_buf, NS, 0, -1)
  if self.current_path == nil then
    return
  end
  for _, c in ipairs(comments_store.for_path(self.comments, self.current_path)) do
    if c.body:match("%S") then
      local opts = { sign_text = "+", priority = 20, virt_text = { { c.body, "Comment" } } }
      if c.side == "file" then
        vim.api.nvim_buf_set_extmark(self.modified_buf, NS, 0, 0, opts)
      elseif c.line then
        local buf = c.side == "original" and self.original_buf or self.modified_buf
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, math.max(0, c.line - 1), 0, opts)
      end
    end
  end
end

function M:toggle_mode()
  self.model:set_mode(self.model:current_mode() == "checkpoint" and "head" or "checkpoint")
  self:refresh()
end

-- submit() checkpoints the workspace, then delivers the composed feedback.
function M:submit()
  local composed = feedback.compose(comments_store.to_review_comments(self.comments))
  local reviewed_paths = self.model:checkpoint_changed_paths()
  local ok, cp = pcall(git.create_checkpoint, self.repo_root, reviewed_paths, composed)
  if not ok then
    vim.notify("Could not save checkpoint: " .. tostring(cp), vim.log.levels.ERROR)
    return
  end
  checkpoint.save(cp)
  self.model:set_checkpoint(cp)
  self.comments = comments_store.new()
  self:refresh()
  self:deliver(composed)
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

-- send_feedback() writes the current feedback file WITHOUT checkpointing.
function M:send_feedback()
  local fb = self:_composed()
  if fb == "" then
    vim.notify("No comments to send.", vim.log.levels.WARN)
    return
  end
  self:deliver(fb)
end

-- deliver(fb) writes composed feedback to the feedback file and notifies the path.
-- Paste the file's path to the agent, or tell the agent to read it.
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
end

-- _feedback_path() -> configured path, else a stable path outside the worktree.
function M:_feedback_path()
  local cfg = config.get()
  if cfg.feedback_file and cfg.feedback_file ~= "" then
    return vim.fn.expand(cfg.feedback_file)
  end
  return vim.fn.stdpath("data") .. "/review-loop/feedback.md"
end

function M:close()
  self.closed = true
  self:_stop_watcher()
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  end
  if self.tab and vim.api.nvim_tabpage_is_valid(self.tab) then
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(self.tab))
  end
  if M.active == self then
    M.active = nil
  end
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
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial, "\n", { plain = true }))
  vim.bo[buf].modified = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = row, col = col, width = width, height = height,
    border = "rounded", title = title .. "  (close to save, clear to discard)",
    title_pos = "center", style = "minimal",
  })
  vim.wo[win].signcolumn = "no"

  local function save_body()
    local body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    pcall(on_save, body)
  end
  -- Closing wipes the buffer -> save. Fires once, covers :q / <CR> / <Esc> / mouse.
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = save_body })
  -- :w / :x / :wq also save and clear the modified flag so quit is clean.
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = function()
    save_body()
    vim.bo[buf].modified = false
  end })

  local function close()
    pcall(vim.api.nvim_win_close, win, true)
  end
  vim.keymap.set("n", "<CR>", close, { buffer = buf, silent = true, desc = "Save & close" })
  vim.keymap.set("n", "q", close, { buffer = buf, silent = true, desc = "Save & close" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true, desc = "Save & close" })
  vim.keymap.set("i", "<C-CR>", close, { buffer = buf, silent = true, desc = "Save & close" })

  vim.cmd("startinsert")
end

return M
