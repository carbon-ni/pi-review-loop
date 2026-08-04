-- WorkspaceModel: holds the active mode + checkpoint, derives WorkspaceState.
-- Port of src/workspace.ts. The git module is injected so the derivation logic
-- can be tested with a fake (no real repository) for determinism.

local M = {}

local WorkspaceModel = {}
WorkspaceModel.__index = WorkspaceModel
M.WorkspaceModel = WorkspaceModel

function WorkspaceModel.new(git_mod, repo_root, checkpoint)
  local self = setmetatable({}, WorkspaceModel)
  self.git = git_mod
  self.repoRoot = repo_root
  self.checkpoint = checkpoint
  self.mode = "checkpoint"
  self.initialHead = git_mod.head_sha(repo_root)
  self.pairsByMode = {}
  self.mtimes = {}
  self.branch = nil
  return self
end

function WorkspaceModel:current_mode()
  return self.mode
end

function WorkspaceModel:current_checkpoint()
  return self.checkpoint
end

function WorkspaceModel:set_mode(mode)
  self.mode = mode
end

function WorkspaceModel:set_checkpoint(checkpoint)
  self.checkpoint = checkpoint
  self.pairsByMode = {}
  self.mtimes = {}
end

-- Baseline used for "checkpoint" mode: the checkpoint, or initial HEAD on first open.
function WorkspaceModel:checkpoint_baseline()
  if self.checkpoint ~= nil then
    return { headSha = self.checkpoint.headSha, overrides = self.checkpoint.overrides }
  end
  return { headSha = self.initialHead, overrides = {} }
end

-- refresh() rescans both modes and recomputes mtimes. Returns the new state.
function WorkspaceModel:refresh()
  local checkpoint_pairs = self.git.scan_against_checkpoint(self.repoRoot, self:checkpoint_baseline())
  local head_pairs = self.git.scan_against_head(self.repoRoot)
  self.branch = self.git.branch_name(self.repoRoot)

  local function index(pairs)
    local map = {}
    for _, p in ipairs(pairs) do
      map[p.path] = p
    end
    return map
  end
  self.pairsByMode = { checkpoint = index(checkpoint_pairs), head = index(head_pairs) }

  local paths = {}
  for _, p in ipairs(checkpoint_pairs) do paths[p.path] = true end
  for _, p in ipairs(head_pairs) do paths[p.path] = true end
  self.mtimes = {}
  for path in pairs(paths) do
    self.mtimes[path] = self.git.file_mtime(self.repoRoot, path)
  end
  return self:state()
end

local function to_changed_file(pair, mtimes)
  return {
    path = pair.path,
    status = pair.status,
    fingerprint = pair.fingerprint,
    recentAt = mtimes[pair.path],
  }
end

function WorkspaceModel:state()
  local mode_pairs = self.pairsByMode[self.mode] or {}
  local checkpoint_pairs = self.pairsByMode.checkpoint or {}

  local files = {}
  for _, pair in pairs(mode_pairs) do
    files[#files + 1] = to_changed_file(pair, self.mtimes)
  end

  local pending_files = {}
  for _, pair in pairs(checkpoint_pairs) do
    pending_files[#pending_files + 1] = to_changed_file(pair, self.mtimes)
  end

  -- recentPaths: files of the active mode, newest mtime first, path as tiebreaker.
  local recent = vim.deepcopy(files)
  table.sort(recent, function(x, y)
    local xr, yr = (x.recentAt or 0), (y.recentAt or 0)
    if xr ~= yr then
      return xr > yr
    end
    return x.path < y.path
  end)
  local recent_paths = {}
  for i, f in ipairs(recent) do recent_paths[i] = f.path end

  return {
    repoRoot = self.repoRoot,
    repoName = self.git.repo_name(self.repoRoot),
    branch = self.branch,
    mode = self.mode,
    hasCheckpoint = self.checkpoint ~= nil,
    checkpointCreatedAt = self.checkpoint and self.checkpoint.createdAt or nil,
    files = files,
    pendingFiles = pending_files,
    recentPaths = recent_paths,
  }
end

function WorkspaceModel:get_file(path, mode)
  local pair = (self.pairsByMode[mode] or {})[path]
  if pair == nil then
    error(path .. " is no longer changed in this mode.")
  end
  return {
    path = path,
    mode = mode,
    fingerprint = pair.fingerprint,
    originalContent = pair.originalContent,
    modifiedContent = pair.modifiedContent,
  }
end

function WorkspaceModel:checkpoint_changed_paths()
  local out = {}
  for path in pairs(self.pairsByMode.checkpoint or {}) do
    out[#out + 1] = path
  end
  return out
end

return M
