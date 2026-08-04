-- Sidebar rendering: "Recently Changed" (flat, newest first) and "Files" (tree),
-- both following the active diff mode. Pure buffer writes driven by WorkspaceState.

local M = {}

-- build_tree(paths) -> nested table: { [name] = subtree|true }
local function build_tree(paths)
  local root = {}
  for _, p in ipairs(paths) do
    local node = root
    local segments = vim.split(p, "/", { plain = true })
    for i, seg in ipairs(segments) do
      if i == #segments then
        node[seg] = true
      else
        node[seg] = node[seg] or {}
        node = node[seg]
      end
    end
  end
  return root
end

-- path_for_line maps a sidebar 1-based line number to a file path (nil if header/blank).
M.line_to_path = {}

local function status_letter(status)
  if status == "added" then return "A" end
  if status == "deleted" then return "D" end
  return "M"
end

-- badge_for(store, path) -> " (n)" when n comments exist, else "".
local function badge_for(comments_store, path)
  if not comments_store then return "" end
  local count = require("review-loop.ui.comments").count_for_path(comments_store, path)
  return count > 0 and string.format(" (%d)", count) or ""
end

-- render(buf, state, comments_store) populates the sidebar buffer and index.
function M.render(buf, state, comments_store)
  M.line_to_path = {}
  local lines = {}

  local function add_line(text, path)
    lines[#lines + 1] = text
    M.line_to_path[#lines] = path
  end

  add_line(string.format(" %s  %s%s", state.repoName, state.branch or "",
    state.mode == "checkpoint" and "  [since review]" or "  [vs HEAD]"), nil)
  add_line("", nil)

  -- Recently Changed: flat list ordered by mtime (state.recentPaths).
  add_line(" Recently Changed", nil)
  for _, path in ipairs(state.recentPaths) do
    local file
    for _, f in ipairs(state.files) do
      if f.path == path then file = f break end
    end
    local letter = status_letter(file and file.status or "M")
    local badge = badge_for(comments_store, path)
    add_line(string.format("   %s %s%s", letter, vim.fs.basename(path), badge), path)
  end
  add_line("", nil)

  -- Files: directory tree.
  add_line(" Files", nil)
  local tree = build_tree(state.recentPaths)
  local function walk(node, prefix)
    -- iterate sorted entries: directories first (tables), then files.
    local names = vim.tbl_keys(node)
    table.sort(names, function(a, b)
      local ad, bd = type(node[a]) == "table", type(node[b]) == "table"
      if ad ~= bd then return ad end
      return a < b
    end)
    for _, name in ipairs(names) do
      local child = node[name]
      if child == true then
        local rel = prefix == "" and name or (prefix .. "/" .. name)
        add_line(string.format("   %s %s%s", " ", name, badge_for(comments_store, rel)), rel)
      else
        add_line("   " .. name .. "/", nil)
        walk(child, prefix == "" and name or (prefix .. "/" .. name))
      end
    end
  end
  walk(tree, "")

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

return M
