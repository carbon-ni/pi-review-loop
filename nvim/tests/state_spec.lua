local Model = require("review-loop.state").WorkspaceModel
local eq = assert.are.same

-- A fake git module so state derivation is tested deterministically (no repo).
local function fake_git(over)
  over = over or {}
  return {
    head_sha = function() return over.head_sha or "HEAD1" end,
    branch_name = function() return over.branch or "main" end,
    repo_name = function(_root) return "repo" end,
    file_mtime = function(_root, path)
      local t = over.mtimes or {}
      return t[path] or 0
    end,
    scan_against_checkpoint = function(_root, _cp)
      return over.checkpoint_pairs or {}
    end,
    scan_against_head = function(_root)
      return over.head_pairs or {}
    end,
  }
end

local function pair(path, status, orig, mod)
  return {
    path = path, status = status,
    fingerprint = "fp-" .. path,
    originalContent = orig or "", modifiedContent = mod or "",
  }
end

describe("WorkspaceModel", function()
  it("defaults to checkpoint mode and reports no checkpoint initially", function()
    local m = Model.new(fake_git(), "/repo", nil)
    eq("checkpoint", m:current_mode())
    assert.is_nil(m:current_checkpoint())
  end)

  it("refresh caches both modes; get_file returns contents for the active mode", function()
    local cp_pair = pair("a.ts", "modified", "old", "new")
    local head_pair = pair("a.ts", "modified", "old", "new")
    local m = Model.new(fake_git({
      head_sha = "H", checkpoint_pairs = { cp_pair }, head_pairs = { head_pair },
    }), "/repo", nil)
    m:refresh()

    local file = m:get_file("a.ts", "checkpoint")
    eq("a.ts", file.path)
    eq("old", file.originalContent)
    eq("new", file.modifiedContent)
  end)

  it("state lists files of the active mode and recentPaths newest-first", function()
    local m = Model.new(fake_git({
      mtimes = { ["a.ts"] = 100, ["b.ts"] = 300, ["c.ts"] = 200 },
      checkpoint_pairs = {
        pair("a.ts", "modified"), pair("b.ts", "added"), pair("c.ts", "modified"),
      },
      head_pairs = {
        pair("a.ts", "modified"), pair("b.ts", "added"), pair("c.ts", "modified"),
      },
    }), "/repo", nil)
    local state = m:refresh()
    eq("main", state.branch)
    eq(true, state.hasCheckpoint == false)

    -- mtime desc with path tiebreak
    eq({ "b.ts", "c.ts", "a.ts" }, state.recentPaths)
  end)

  it("switching mode changes which files the state exposes", function()
    local m = Model.new(fake_git({
      checkpoint_pairs = { pair("only-checkpoint.ts", "modified") },
      head_pairs = { pair("only-head.ts", "added") },
    }), "/repo", nil)
    m:refresh()

    m:set_mode("head")
    local head_state = m:state()
    local names = {}
    for _, f in ipairs(head_state.files) do names[#names + 1] = f.path end
    eq({ "only-head.ts" }, names)

    m:set_mode("checkpoint")
    local cp_state = m:state()
    local cp_names = {}
    for _, f in ipairs(cp_state.files) do cp_names[#cp_names + 1] = f.path end
    eq({ "only-checkpoint.ts" }, cp_names)
  end)

  it("checkpoint_changed_paths lists files changed since the checkpoint baseline", function()
    local m = Model.new(fake_git({
      checkpoint_pairs = { pair("a.ts", "modified"), pair("b.ts", "added") },
      head_pairs = {},
    }), "/repo", nil)
    m:refresh()
    local paths = m:checkpoint_changed_paths()
    table.sort(paths)
    eq({ "a.ts", "b.ts" }, paths)
  end)

  it("get_file throws when the path is not changed in the mode", function()
    local m = Model.new(fake_git({}), "/repo", nil)
    m:refresh()
    assert.has_error(function() m:get_file("missing.ts", "checkpoint") end)
  end)

  it("set_checkpoint clears caches so the next refresh uses the new baseline", function()
    local over = { checkpoint_pairs = { pair("a.ts", "modified") }, head_pairs = {} }
    local m = Model.new(fake_git(over), "/repo", nil)
    m:refresh()
    eq({ "a.ts" }, m:checkpoint_changed_paths())

    -- Simulate a new checkpoint that marks everything reviewed: scan now empty.
    over.checkpoint_pairs = {}
    m:set_checkpoint({ headSha = "H", overrides = {}, reviewedPaths = {}, feedback = "" })
    m:refresh()
    eq({}, m:checkpoint_changed_paths())
    eq(true, m:current_checkpoint() ~= nil)
  end)
end)
