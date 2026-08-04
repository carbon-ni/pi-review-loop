-- Checkpoint serialization, format-compatible with src/git.ts (encodeStored /
-- decodeStored / fingerprint) so a Lua-written checkpoint round-trips with the
-- TypeScript extension and vice versa.
--
-- StoredFile = { state = "deleted" }
--            | { state = "present", fingerprint, encoding = "gzip+base64", content }
-- ReviewCheckpoint fields mirror types.ts#ReviewCheckpoint (version 1).

local M = {}

local uv = vim.uv or vim.loop

-- Codec is injectable so tests can verify round-trips deterministically.
-- Default uses gzip(1) + vim.base64, which are universally available.
-- vim.system is binary-safe over stdin/stdout pipes (vim.fn.system truncates
-- at NUL bytes, which corrupts gzipped output).
local function pipe(cmd, input)
  local obj = vim.system(cmd, { stdin = input, text = false }):wait()
  if obj.code ~= 0 then
    error(cmd[1] .. " failed: " .. tostring(obj.stderr or obj.stdout))
  end
  return obj.stdout
end

M.codec = {
  encode_content = function(content)
    return vim.base64.encode(pipe({ "gzip", "-c" }, content))
  end,
  decode_content = function(encoded)
    return pipe({ "gunzip", "-c" }, vim.base64.decode(encoded))
  end,
}

-- fingerprint(content) -> sha256 hex, or "deleted" for nil. Matches Node createHash("sha256").
function M.fingerprint(content)
  if content == nil then
    return "deleted"
  end
  return vim.fn.sha256(content)
end

function M.encode_stored(content)
  if content == nil then
    return { state = "deleted" }
  end
  return {
    state = "present",
    fingerprint = M.fingerprint(content),
    encoding = "gzip+base64",
    content = M.codec.encode_content(content),
  }
end

function M.decode_stored(stored)
  if stored == nil or stored.state == "deleted" then
    return nil
  end
  return M.codec.decode_content(stored.content)
end

-- make_checkpoint builds a ReviewCheckpoint from resolved overrides.
-- overrides: path -> content-or-nil (nil content yields a deleted entry).
function M.make_checkpoint(repo_root, head_sha, reviewed_paths, feedback, overrides)
  local stored = {}
  for path, content in pairs(overrides or {}) do
    -- Accept a pre-built StoredFile (e.g. M.DELETED) or raw content.
    if type(content) == "table" and content.state ~= nil then
      stored[path] = content
    else
      stored[path] = M.encode_stored(content)
    end
  end

  local reviewed = {}
  local seen = {}
  for _, p in ipairs(reviewed_paths or {}) do
    if not seen[p] then
      seen[p] = true
      reviewed[#reviewed + 1] = p
    end
  end
  table.sort(reviewed)

  local sec, usec = uv.gettimeofday()
  return {
    version = 1,
    id = M.uuid(),
    repoRoot = repo_root,
    createdAt = sec * 1000 + math.floor((usec or 0) / 1000),
    headSha = head_sha,
    overrides = stored,
    reviewedPaths = reviewed,
    feedback = feedback or "",
  }
end

-- RFC4122 v4-shaped uuid using sha256 of time+random (uniqueness only; not crypto).
function M.uuid()
  local seed = tostring(uv.hrtime()) .. tostring(math.random()) .. tostring(uv.getpid and uv.getpid() or "")
  local hex = vim.fn.sha256(seed):sub(1, 32)
  return hex:sub(1, 8)
      .. "-" .. hex:sub(9, 12)
      .. "-4" .. hex:sub(14, 16)
      .. "-8" .. hex:sub(18, 19) .. hex:sub(20, 20)
      .. "-" .. hex:sub(21, 32)
end

-- On-disk persistence. One checkpoint per repo under stdpath("data")/review-loop.
M.data_dir = nil  -- override in tests; defaults to stdpath("data") at use.

-- Sentinel for a deleted override. Lua tables cannot hold nil values, so callers
-- expressing "this path is deleted in the checkpoint" pass M.DELETED.
M.DELETED = { state = "deleted" }

local function base_dir()
  return M.data_dir or (vim.fn.stdpath("data") .. "/review-loop")
end

local function store_key(repo_root)
  return (repo_root:gsub("[^%w]", "_"))
end

function M.store_path(repo_root)
  return base_dir() .. "/" .. store_key(repo_root) .. ".json"
end

function M.save(checkpoint)
  local path = M.store_path(checkpoint.repoRoot)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(vim.json.encode(checkpoint))
  f:close()
  return path
end

function M.load(repo_root)
  local f = io.open(M.store_path(repo_root), "r")
  if not f then
    return nil
  end
  local body = f:read("*a")
  f:close()
  if not body or body == "" then
    return nil
  end
  return vim.json.decode(body)
end

return M
