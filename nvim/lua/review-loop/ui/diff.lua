-- Two-pane diff rendering: original (baseline) | modified (working tree).
-- Sets scratch buffers, enables diff mode, and restores scroll per path/mode.

local M = {}

-- Per (path|mode) view state so reopening a file resumes where you left off.
M.saved_views = {}

local function view_key(path, mode)
  return path .. "|" .. mode
end

local function save_view(win, path, mode)
  M.saved_views[view_key(path, mode)] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
end

local function restore_view(win, path, mode)
  local v = M.saved_views[view_key(path, mode)]
  if v then
    vim.api.nvim_win_call(win, function() vim.fn.winrestview(v) end)
  end
end

-- show(ctx, file) renders FileContents into the two diff windows.
-- ctx = { original_win, modified_win, original_buf, modified_buf }
function M.show(ctx, file)
  -- Filetype from the path so syntax + minimap look right.
  local ft = vim.filetype.match({ filename = file.path }) or "text"

  for _, pair in ipairs({
    { buf = ctx.original_buf, content = file.originalContent, label = "REVIEWED" },
    { buf = ctx.modified_buf, content = file.modifiedContent, label = "CURRENT" },
  }) do
    vim.bo[pair.buf].modifiable = true
    vim.bo[pair.buf].filetype = ft
    vim.api.nvim_buf_set_lines(pair.buf, 0, -1, false, vim.split(pair.content, "\n", { plain = true }))
    vim.bo[pair.buf].modifiable = false
    vim.bo[pair.buf].modified = false
  end

  -- Diff mode is a per-window property; both windows must opt in.
  for _, win in ipairs({ ctx.original_win, ctx.modified_win }) do
    vim.wo[win].diff = true
    vim.wo[win].cursorline = true
    vim.wo[win].foldmethod = "diff"
  end

  restore_view(ctx.original_win, file.path, file.mode)
  restore_view(ctx.modified_win, file.path, file.mode)
end

-- remember(ctx, path, mode) snapshots scroll before switching files.
function M.remember(ctx, path, mode)
  save_view(ctx.original_win, path, mode)
  save_view(ctx.modified_win, path, mode)
end

return M
