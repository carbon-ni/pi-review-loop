-- Git porcelain + diff scanning. Port of src/git.ts.
-- All git calls go through vim.system (binary-safe). The module is injectable:
-- state_spec passes a fake here so the derivation logic stays deterministic.

local M = {}

local uv = vim.uv or vim.loop
local checkpoint = require("review-loop.checkpoint")

-- git(args, opts) -> { code, stdout, stderr }. stdout/stderr are raw bytes.
local function git(args, opts)
  opts = opts or {}
  local cmd = vim.list_extend({ "git" }, args)
  local obj = vim.system(cmd, { cwd = opts.cwd, text = false }):wait()
  return { code = obj.code, stdout = obj.stdout or "", stderr = obj.stderr or "" }
end

-- git_ok throws on non-zero unless allow_failure; returns trimmed stdout.
local function git_ok(args, cwd, allow_failure)
  local r = git(args, { cwd = cwd })
  if r.code ~= 0 then
    if allow_failure then
      return ""
    end
    local msg = r.stderr
    if msg == "" then msg = r.stdout end
    if msg == "" then msg = "git " .. table.concat(args, " ") .. " failed" end
    error(msg)
  end
  return r.stdout
end

local function split_nonempty(s)
  -- NUL-delimited split using plain byte find; Lua patterns mis-handle a NUL
  -- inside a character class.
  local out = {}
  local start = 1
  while true do
    local fin = s:find("\0", start, true)
    if not fin then
      local part = s:sub(start)
      if part ~= "" then out[#out + 1] = part end
      break
    end
    local part = s:sub(start, fin - 1)
    if part ~= "" then out[#out + 1] = part end
    start = fin + 1
  end
  return out
end

function M.repo_root(cwd)
  return git_ok({ "rev-parse", "--show-toplevel" }, cwd):gsub("%s+$", "")
end

function M.head_sha(repo_root)
  local out = git_ok({ "rev-parse", "--verify", "HEAD" }, repo_root, true)
  out = out:gsub("%s+$", "")
  return out == "" and nil or out
end

function M.branch_name(repo_root)
  local out = git_ok({ "branch", "--show-current" }, repo_root, true)
  out = out:gsub("%s+$", "")
  return out == "" and nil or out
end

-- parse_porcelain_paths(output): mirrors git.ts#parsePorcelainPaths exactly.
-- Porcelain v1 -z fields are "XY path\0[oldpath\0]". R/C consume a paired old path.
function M.parse_porcelain_paths(output)
  local fields = split_nonempty(output)
  local paths, seen = {}, {}
  local function add(p)
    if p and p ~= "" and not seen[p] then
      seen[p] = true
      paths[#paths + 1] = p
    end
  end
  local i = 1
  while i <= #fields do
    local field = fields[i]
    if #field >= 4 then
      local status = field:sub(1, 2)
      add(field:sub(4))
      if status:find("R") or status:find("C") then
        add(fields[i + 1])
        i = i + 1
      end
    end
    i = i + 1
  end
  return paths
end

function M.dirty_paths(repo_root)
  local out = git_ok({ "status", "--porcelain=v1", "-z", "--untracked-files=all" }, repo_root)
  return M.parse_porcelain_paths(out)
end

function M.untracked_paths(repo_root)
  return split_nonempty(git_ok({ "ls-files", "--others", "--exclude-standard", "-z" }, repo_root, true))
end

function M.current_paths(repo_root)
  return split_nonempty(git_ok({ "ls-files", "--cached", "--others", "--exclude-standard", "-z" }, repo_root, true))
end

function M.changed_against(repo_root, revision)
  if revision == nil then
    return M.current_paths(repo_root)
  end
  return split_nonempty(git_ok({ "diff", "--name-only", "-z", revision, "--" }, repo_root, true))
end

function M.read_current(repo_root, path)
  local abs = repo_root .. "/" .. path
  local info = uv.fs_stat(abs)
  if not info or info.type ~= "file" then
    return nil
  end
  local fd = uv.fs_open(abs, "r", 438)
  if not fd then
    return nil
  end
  local data = uv.fs_read(fd, info.size, 0)
  uv.fs_close(fd)
  return data
end

function M.read_revision(repo_root, revision, path)
  if revision == nil then
    return nil
  end
  local r = git({ "show", revision .. ":" .. path }, { cwd = repo_root })
  return r.code == 0 and r.stdout or nil
end

function M.status_for(original, modified)
  if original == nil then
    return "added"
  end
  if modified == nil then
    return "deleted"
  end
  return "modified"
end

-- baseline_content resolves the checkpoint baseline for one path:
-- override wins, else git show <headSha>:<path>.
function M.baseline_content(repo_root, checkpoint_baseline, path)
  local override = checkpoint_baseline.overrides and checkpoint_baseline.overrides[path]
  if override ~= nil then
    return checkpoint.decode_stored(override)
  end
  return M.read_revision(repo_root, checkpoint_baseline.headSha, path)
end

-- scan_against_checkpoint(repo_root, checkpoint?) -> FilePair[]
-- A path is "changed" if baseline != current. Mirrors git.ts#scanAgainstCheckpoint.
function M.scan_against_checkpoint(repo_root, checkpoint_baseline)
  local cp = checkpoint_baseline or { headSha = nil, overrides = {} }
  local candidates, seen = {}, {}
  local function add(p)
    if p and p ~= "" and not seen[p] then
      seen[p] = true
      candidates[#candidates + 1] = p
    end
  end
  for _, p in ipairs(M.changed_against(repo_root, cp.headSha)) do add(p) end
  for _, p in ipairs(M.untracked_paths(repo_root)) do add(p) end
  if cp.overrides then
    for p in pairs(cp.overrides) do add(p) end
  end

  local pairs_out = {}
  for _, path in ipairs(candidates) do
    local original = M.baseline_content(repo_root, cp, path)
    local modified = M.read_current(repo_root, path)
    if original ~= modified then
      pairs_out[#pairs_out + 1] = {
        path = path,
        status = M.status_for(original, modified),
        fingerprint = checkpoint.fingerprint(modified),
        originalContent = original or "",
        modifiedContent = modified or "",
      }
    end
  end
  table.sort(pairs_out, function(a, b) return a.path < b.path end)
  return pairs_out
end

function M.scan_against_head(repo_root)
  return M.scan_against_checkpoint(repo_root, { headSha = M.head_sha(repo_root), overrides = {} })
end

-- create_checkpoint(repo_root, reviewed_paths, feedback) -> ReviewCheckpoint.
-- Overrides = every dirty path snapshotted at current content (deleted -> DELETED).
function M.create_checkpoint(repo_root, reviewed_paths, feedback)
  local overrides = {}
  for _, path in ipairs(M.dirty_paths(repo_root)) do
    local content = M.read_current(repo_root, path)
    overrides[path] = content == nil and checkpoint.DELETED or content
  end
  return checkpoint.make_checkpoint(repo_root, M.head_sha(repo_root), reviewed_paths, feedback, overrides)
end

function M.file_mtime(repo_root, path)
  local abs = repo_root .. "/" .. path
  local s = uv.fs_stat(abs)
  local function ms(stat)
    return stat.mtime.sec * 1000 + math.floor(stat.mtime.nsec / 1e6)
  end
  if s then
    return ms(s)
  end
  -- Deleted-file fallback: parent directory mtime. Matches git.ts#fileMtime.
  local d = uv.fs_stat(vim.fs.dirname(abs))
  if d then
    return ms(d)
  end
  return 0
end

function M.repo_name(repo_root)
  return vim.fs.basename(repo_root)
end

function M.path_exists(repo_root, path)
  return uv.fs_stat(repo_root .. "/" .. path) ~= nil
end

return M
