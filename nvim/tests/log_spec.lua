local log = require("review-loop.log")
local eq = assert.are.same

-- Each test points the log at a throwaway file so we never touch the user's data dir.
local function with_tmp_dir(fn)
  return function()
    local dir = vim.fn.tempname() .. "-rl-log"
    log.data_dir = dir
    log.set_enabled(true)
    fn(dir)
    log.set_enabled(false)
    log.data_dir = nil
    log._enabled = nil
    pcall(vim.fn.delete, dir, "rf")
  end
end

describe("log formatting", function()
  it("_format renders event then kv pairs in sorted key order", function()
    local line = log._format("restore.set", { win = 12, line = 2, closed = false })
    eq("restore.set closed=false line=2 win=12", line)
  end)

  it("_format quotes strings that contain spaces or quotes", function()
    -- backslash-quote escapes the embedded quote: body value is "he said \"hi\""
    eq('comment.save body="he said \\"hi\\"" title="a b"',
      log._format("comment.save", { title = "a b", body = 'he said "hi"' }))
    eq("selection.read path=a.txt", log._format("selection.read", { path = "a.txt" }))
  end)

  it("_format renders tables as JSON", function()
    eq('x v={"a":1}', log._format("x", { v = { a = 1 } }))
  end)
end)

describe("log enable state", function()
  after_each(function() log._enabled = nil end)

  it("set_enabled / enabled round-trip", function()
    log.set_enabled(false)
    eq(false, log.enabled())
    log.set_enabled(true)
    eq(true, log.enabled())
  end)

  it("toggle flips and returns the new state", function()
    log.set_enabled(false)
    eq(true, log.toggle())
    eq(false, log.toggle())
  end)

  it("enabled resolves from config.debug when not explicitly set", function()
    log._enabled = nil
    require("review-loop.config").setup({ debug = true })
    eq(true, log.enabled())
    require("review-loop.config").setup({ debug = false })
    log._enabled = nil
    eq(false, log.enabled())
  end)
end)

describe("log file writes", function()
  it("is a no-op when disabled (no file created)", with_tmp_dir(function(dir)
    log.set_enabled(false)
    log.debug("selection.read", { path = "a.txt", s = 2 })
    eq(0, vim.fn.filereadable(log.path()))
  end))

  it("appends structured lines when enabled", with_tmp_dir(function(dir)
    log.debug("selection.read", { path = "a.txt", s = 2, e = 5 })
    log.debug("restore.set", { line = 2, actual = 2 })
    local lines = vim.fn.readfile(log.path())
    -- timestamp prefix is ignored; assert the sorted-key payload tail of each line.
    assert.truthy(lines[1]:find("selection%.read e=5 path=a%.txt s=2$"))
    assert.truthy(lines[2]:find("restore%.set actual=2 line=2$"))
  end))

  it("clear empties the file", with_tmp_dir(function()
    log.debug("x", { a = 1 })
    log.clear()
    eq({}, vim.fn.readfile(log.path()))
  end))

  it("path lives under data_dir/review-loop.log", with_tmp_dir(function(dir)
    eq(dir .. "/review-loop.log", log.path())
  end))
end)
