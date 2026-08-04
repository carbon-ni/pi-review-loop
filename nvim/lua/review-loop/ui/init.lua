-- Reviewer controller: owns windows/buffers, the WorkspaceModel, the comment
-- store, and the keymaps. One active instance per open() call.

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

-- open() -> controller table (or nil, errmsg on failure).
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
  self:_layout()
  self:_keymaps()
  self:_watch()
  self:refresh()
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

-- refresh() re-scans, re-renders the sidebar, and reloads the current file.
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

-- _upsert edits an existing same-location comment or adds a new one.
function M:_upsert(path, side, line, body)
  for _, c in ipairs(comments_store.for_path(self.comments, path)) do
    if c.side == side and c.line == line then
      comments_store.update(self.comments, c.id, body)
      return
    end
  end
  comments_store.add(self.comments, {
    path = path, mode = self.model:current_mode(), side = side, line = line, body = body,
  })
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

-- submit() composes feedback, checkpoints the workspace, and hands off via config.
function M:submit()
  local review_comments = comments_store.to_review_comments(self.comments)
  local composed = feedback.compose(review_comments)
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
  config.get().on_submit(composed, cp)
end

function M:close()
  self.closed = true
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  end
  if self.tab and vim.api.nvim_tabpage_is_valid(self.tab) then
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(self.tab))
  end
end

-- _edit opens a small floating window; on_save(body) is called with the text.
function M:_edit(title, initial, on_save)
  local row = math.floor(vim.o.lines * 0.3)
  local col = math.floor(vim.o.columns * 0.25)
  local width = math.floor(vim.o.columns * 0.5)
  local height = 12
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial, "\n", { plain = true }))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = row, col = col, width = width, height = height,
    border = "rounded", title = title, title_pos = "center", style = "minimal",
  })
  vim.wo[win].signcolumn = "no"

  local function save()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local body = table.concat(lines, "\n")
    pcall(vim.api.nvim_win_close, win, true)
    on_save(body)
  end
  vim.keymap.set("n", "<CR>", save, { buffer = buf, silent = true, desc = "Save comment" })
  vim.keymap.set("n", "<Esc>", function() pcall(vim.api.nvim_win_close, win, true) end,
    { buffer = buf, silent = true, desc = "Cancel" })
  vim.keymap.set("i", "<C-CR>", save, { buffer = buf, desc = "Save comment" })
end

return M
