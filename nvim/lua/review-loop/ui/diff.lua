-- Adapter between review-loop's checkpoint model and diffview.nvim's custom view.
-- Review-loop owns file discovery/content; Diffview owns layout and navigation.

local M = {}

local STATUS = {
  added = "A",
  modified = "M",
  deleted = "D",
}

local function lines(content)
  if content == "" then
    return {}
  end
  local result = vim.split(content, "\n", { plain = true })
  if content:sub(-1) == "\n" and result[#result] == "" then
    table.remove(result)
  end
  return result
end

function M.file_dict(state)
  local selected = state.recentPaths and state.recentPaths[1] or nil
  local working = {}
  for _, file in ipairs(state.files or {}) do
    working[#working + 1] = {
      path = file.path,
      status = STATUS[file.status] or "X",
      left_null = file.status == "added",
      right_null = file.status == "deleted",
      selected = file.path == selected,
    }
  end
  return { working = working, staged = {}, conflicting = {} }
end

function M.file_data(model, _kind, path, split)
  local ok, file = pcall(model.get_file, model, path, model:current_mode())
  if not ok then
    return nil
  end
  local content = split == "left" and file.originalContent or file.modifiedContent
  return lines(content)
end

function M.baseline_revision(model, head_sha)
  local mode = model:current_mode()
  if mode == "checkpoint" then
    local cp = model:current_checkpoint()
    if cp then
      return table.concat({ "review-loop-checkpoint", cp.headSha or "unborn", cp.createdAt or "initial" }, "-")
    end
  end
  return "review-loop-" .. mode .. "-" .. (head_sha or "unborn")
end

local function dependencies()
  local ok_diffview, load_error = pcall(require, "diffview")
  if not ok_diffview then
    error("review-loop.nvim requires sindrets/diffview.nvim: " .. tostring(load_error))
  end
  local ok_view, custom = pcall(require, "diffview.api.views.diff.diff_view")
  if not ok_view then
    error("review-loop.nvim could not load Diffview custom view API: " .. tostring(custom))
  end
  return {
    CDiffView = custom.CDiffView,
    GitRev = require("diffview.vcs.adapters.git.rev").GitRev,
    RevType = require("diffview.vcs.rev").RevType,
    lib = require("diffview.lib"),
  }
end

local function mark_text_files(entries)
  for _, section in pairs(entries) do
    for _, entry in ipairs(section) do
      for _, file in ipairs(entry.layout:files()) do
        -- The contents come from review-loop, so Diffview must not probe the
        -- synthetic baseline revision to decide whether a file is binary.
        file.binary = false
      end
    end
  end
  return entries
end

function M.current_context(view, entry)
  local layout = view.cur_layout
  if not layout or not layout.a or not layout.b then
    return nil
  end
  return {
    path = entry.path,
    original_buf = layout.a.file.bufnr,
    modified_buf = layout.b.file.bufnr,
    original_win = layout.a.id,
    modified_win = layout.b.id,
    original_file = layout.a.file,
    modified_file = layout.b.file,
    original_nulled = layout.a:is_nulled(),
    modified_nulled = layout.b:is_nulled(),
  }
end

function M.open(opts)
  local deps = dependencies()
  local model = assert(opts.model, "model is required")
  local files = M.file_dict(model:state())
  local left = deps.GitRev(deps.RevType.COMMIT, M.baseline_revision(model, opts.head_sha()))
  local right = deps.GitRev(deps.RevType.LOCAL)
  local view = deps.CDiffView({
    git_root = opts.repo_root,
    left = left,
    right = right,
    files = files,
    update_files = function()
      return M.file_dict(model:state())
    end,
    get_file_data = function(kind, path, split)
      return M.file_data(model, kind, path, split)
    end,
  })

  local create_entries = view.create_file_entries
  view.create_file_entries = function(self, next_files)
    return mark_text_files(create_entries(self, next_files))
  end
  mark_text_files({
    working = view.files.working,
    staged = view.files.staged,
    conflicting = view.files.conflicting,
  })

  view.emitter:on("file_open_post", function(_, entry)
    local context = M.current_context(view, entry)
    if context and opts.on_file_open then
      opts.on_file_open(context)
    end
  end)
  view.emitter:on("view_closed", function()
    if opts.on_close then opts.on_close() end
  end)

  deps.lib.add_view(view)
  view:open()
  return view
end

function M.refresh(view, model, head_sha)
  local deps = dependencies()
  local revision = M.baseline_revision(model, head_sha)
  if view.left.commit ~= revision then
    local left = deps.GitRev(deps.RevType.COMMIT, revision)
    view.left = left
    for _, entry in ipairs(view.files.working) do
      local file = entry.layout.a.file
      file:dispose_buffer()
      file.rev = left
      file.binary = false
      entry.revs.a = left
    end
  end
  view:update_files()
end

function M.close(view)
  if not view then return end
  local deps = dependencies()
  view:close()
  deps.lib.dispose_view(view)
end

return M
