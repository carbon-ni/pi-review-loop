-- Shared disk-based persistence for the review loop.
--
-- Files live under .review-loop/ in the repository root:
--   checkpoint.json  — latest immutable checkpoint (content baseline)
--   session.json     — mutable work-in-progress (comments, viewed, mode, active file)
--
-- Both the TypeScript extension and Neovim plugin read and write the same files
-- so review state is shared across frontends.

local M = {}

local CHECKPOINT_FILE = "checkpoint.json"
local SESSION_FILE = "session.json"

--- Create a store backed by <repo_root>/.review-loop/.
---@param repo_root string
function M.new(repo_root)
  local self = { repo_root = repo_root, dir = repo_root .. "/.review-loop" }
  return setmetatable(self, { __index = M })
end

--- Load checkpoint and session; returns nil for missing files.
---@return { checkpoint: table|nil, session: table|nil }
function M:load()
  vim.fn.mkdir(self.dir, "p")
  return {
    checkpoint = read_json(self.dir .. "/" .. CHECKPOINT_FILE),
    session = read_json(self.dir .. "/" .. SESSION_FILE),
  }
end

--- Persist a checkpoint (overwrites).
---@param checkpoint table
function M:save_checkpoint(checkpoint)
  write_json(self.dir .. "/" .. CHECKPOINT_FILE, checkpoint)
end

--- Persist a session (bumps updatedAt to now, overwrites).
---@param session table
function M:save_session(session)
  session.updatedAt = os.time() * 1000
  write_json(self.dir .. "/" .. SESSION_FILE, session)
end

--- Remove the entire .review-loop/ directory.
function M:clear()
  vim.fn.delete(self.dir, "rf")
end

---@param path string
---@return table|nil
function read_json(path)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = io.open(path, "r")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  if not body or body == "" then return nil end
  return vim.json.decode(body)
end

---@param path string
---@param data table
function write_json(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(vim.json.encode(data))
  f:close()
end

return M
