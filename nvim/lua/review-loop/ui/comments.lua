-- In-memory review comment store. Pure logic; no nvim APIs.
-- A comment: { id, path, mode, side = "original"|"modified"|"file", line = number|nil, body }.
-- The UI binds extmarks to ids; compose() consumes the ReviewComment projection.

local M = {}

local function next_id(store)
  store._seq = (store._seq or 0) + 1
  return "c" .. store._seq
end

function M.new()
  return { items = {}, _seq = 0 }
end

-- add(store, comment) -> id. Normalizes a file-level comment to line = nil.
function M.add(store, comment)
  local line = nil
  if comment.side ~= "file" then
    line = comment.line
  end
  local c = {
    path = comment.path,
    mode = comment.mode,
    side = comment.side,
    line = line,
    body = comment.body or "",
  }
  local id = next_id(store)
  c.id = id
  store.items[id] = c
  return id
end

function M.update(store, id, body)
  local c = store.items[id]
  if c then
    c.body = body
  end
end

function M.remove(store, id)
  store.items[id] = nil
end

function M.get(store, id)
  return store.items[id]
end

function M.clear(store)
  store.items = {}
end

-- all(store) -> list ordered by id (insertion order).
function M.all(store)
  local out = {}
  for _, c in pairs(store.items) do
    out[#out + 1] = c
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function M.for_path(store, path)
  local out = {}
  for _, c in pairs(store.items) do
    if c.path == path then
      out[#out + 1] = c
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function M.count_for_path(store, path)
  local n = 0
  for _, c in pairs(store.items) do
    if c.path == path then
      n = n + 1
    end
  end
  return n
end

-- to_review_comments(store) -> ReviewComment[] for feedback.compose.
-- Drops comments with blank bodies to match the TypeScript submit path.
function M.to_review_comments(store)
  local out = {}
  for _, c in ipairs(M.all(store)) do
    if (c.body or ""):match("%S") then
      out[#out + 1] = {
        path = c.path,
        mode = c.mode,
        side = c.side,
        line = c.line,
        body = c.body,
      }
    end
  end
  return out
end

return M
