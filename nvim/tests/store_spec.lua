local Store = require("review-loop.store")
local eq = assert.are.same

local function checkpoint(over)
  over = over or {}
  return vim.tbl_extend("force", {
    version = 1,
    id = "cp-1",
    repoRoot = "/repo",
    createdAt = 1000,
    headSha = "sha1",
    overrides = {},
    reviewedPaths = { "a.ts" },
    feedback = "looks good",
  }, over)
end

local function session(over)
  over = over or {}
  return vim.tbl_extend("force", {
    version = 1,
    repoRoot = "/repo",
    checkpointId = vim.NIL,  -- Lua's null equivalent for JSON
    mode = "checkpoint",
    comments = {},
    viewedPaths = {},
    activePath = vim.NIL,
    createdAt = 500,
    updatedAt = 500,
  }, over)
end

local function tmpdir()
  local d = vim.fn.tempname() .. "_dir"
  vim.fn.mkdir(d, "p")
  return d
end

describe("store", function()
  it("load returns nil when no files exist", function()
    local tmp = tmpdir()
    local store = Store.new(tmp)
    local state = store:load()
    eq(nil, state.checkpoint)
    eq(nil, state.session)
    vim.fn.delete(tmp, "rf")
  end)

  it("save and load checkpoint round-trips", function()
    local tmp = tmpdir()
    local store = Store.new(tmp)
    local cp = checkpoint({ id = "abc", createdAt = 42 })
    store:save_checkpoint(cp)
    local state = store:load()
    eq(cp, state.checkpoint)
    vim.fn.delete(tmp, "rf")
  end)

  it("save and load session round-trips", function()
    local tmp = tmpdir()
    local store = Store.new(tmp)
    local sess = session({
      mode = "head",
      comments = {
        { id = "c1", path = "a.ts", side = "modified", line = 10, body = "nit" },
      },
      viewedPaths = { "a.ts", "b.ts" },
      activePath = "a.ts",
    })
    store:save_session(sess)
    local state = store:load()
    eq(sess, state.session)
    vim.fn.delete(tmp, "rf")
  end)

  it("session updatedAt is bumped on save", function()
    local tmp = tmpdir()
    local store = Store.new(tmp)
    local sess = session({ updatedAt = 1 })
    store:save_session(sess)
    local state = store:load()
    -- updatedAt should be > 1 after save_session bumps it
    assert(state.session.updatedAt > 1, "expected updatedAt > 1, got " .. tostring(state.session.updatedAt))
    vim.fn.delete(tmp, "rf")
  end)

  it("save overwrites previous", function()
    local tmp = tmpdir()
    local store = Store.new(tmp)
    store:save_checkpoint(checkpoint({ id = "first" }))
    store:save_checkpoint(checkpoint({ id = "second" }))
    local state = store:load()
    eq("second", state.checkpoint.id)
    vim.fn.delete(tmp, "rf")
  end)

  it("clear removes all files", function()
    local tmp = tmpdir()
    local store = Store.new(tmp)
    store:save_checkpoint(checkpoint())
    store:save_session(session())
    store:clear()
    local state = store:load()
    eq(nil, state.checkpoint)
    eq(nil, state.session)
    vim.fn.delete(tmp, "rf")
  end)

  it("checkpoint and session coexist in the same directory", function()
    local tmp = tmpdir()
    local store = Store.new(tmp)
    local cp = checkpoint({ id = "cp-x" })
    local sess = session({ checkpointId = "cp-x" })
    store:save_checkpoint(cp)
    store:save_session(sess)
    local state = store:load()
    eq(cp, state.checkpoint)
    eq(sess, state.session)
    vim.fn.delete(tmp, "rf")
  end)
end)
