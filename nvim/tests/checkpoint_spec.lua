local cp = require("review-loop.checkpoint")
local eq = assert.are.same

describe("checkpoint.fingerprint", function()
  it("matches sha256 of the content bytes", function()
    -- sha256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
    eq("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
      cp.fingerprint("hello"))
  end)

  it("returns 'deleted' for nil", function()
    eq("deleted", cp.fingerprint(nil))
  end)
end)

describe("checkpoint encode/decode (gzip+base64)", function()
  it("round-trips arbitrary text", function()
    local content = "line one\nline two\n\xff\xfe bytes here"
    local stored = cp.encode_stored(content)
    eq("present", stored.state)
    eq("gzip+base64", stored.encoding)
    eq(cp.fingerprint(content), stored.fingerprint)
    eq(content, cp.decode_stored(stored))
  end)

  it("encodes nil as a deleted entry", function()
    eq({ state = "deleted" }, cp.encode_stored(nil))
    assert.is_nil(cp.decode_stored({ state = "deleted" }))
  end)

  it("round-trips a unicode payload through the real gzip codec", function()
    local payload = "こんにちは world 🌍\n\tindent"
    eq(payload, cp.decode_stored(cp.encode_stored(payload)))
  end)
end)

describe("checkpoint.make_checkpoint", function()
  it("builds a version 1 checkpoint with sorted, deduped reviewed paths", function()
    local c = cp.make_checkpoint("/repo", "deadbeef", { "b.ts", "a.ts", "b.ts" }, "notes", {})
    eq(1, c.version)
    eq("deadbeef", c.headSha)
    eq({ "a.ts", "b.ts" }, c.reviewedPaths)
    eq("notes", c.feedback)
    eq("/repo", c.repoRoot)
    eq({}, c.overrides)
    assert.truthy(c.id)
    assert.truthy(c.createdAt)
  end)

  it("encodes overrides into StoredFile entries", function()
    local c = cp.make_checkpoint("/repo", nil, {}, "", { ["x.ts"] = "abc", ["y.ts"] = cp.DELETED })
    eq("present", c.overrides["x.ts"].state)
    eq("abc", cp.decode_stored(c.overrides["x.ts"]))
    eq({ state = "deleted" }, c.overrides["y.ts"])
  end)
end)

describe("checkpoint persistence", function()
  local tmp
  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.delete(tmp, "rf")
    cp.data_dir = tmp
  end)
  after_each(function()
    cp.data_dir = nil
    vim.fn.delete(tmp, "rf")
  end)

  it("save then load round-trips the checkpoint", function()
    local c = cp.make_checkpoint("/repo", "sha", { "a" }, "fb", { ["a"] = "x" })
    cp.save(c)
    local loaded = cp.load("/repo")
    eq(c, loaded)
  end)

  it("load returns nil when no checkpoint exists", function()
    assert.is_nil(cp.load("/nope"))
  end)
end)
