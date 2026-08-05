-- Head mode must refresh when HEAD moves (new commit / branch switch). The file
-- watcher ignores .git and isn't recursive into .git on Linux, so this is driven
-- by an explicit HEAD poll, not the fs watcher. See range-comment report companion.
local ui = require("review-loop.ui")
local eq = assert.are.same

describe("head-mode auto-refresh on a new commit", function()
  local ctrl, fake_git, refreshed, sha

  before_each(function()
    sha = "aaa"
    refreshed = 0
    fake_git = { head_sha = function() return sha end }
    ctrl = setmetatable({
      repo_root = "/repo",
      closed = false,
      _lastHead = "aaa",
      model = {
        git = fake_git,
        current_mode = function() return "head" end,
      },
      refresh = function() refreshed = refreshed + 1 end,
    }, { __index = ui })
  end)

  it("refreshes when HEAD moves while in head mode", function()
    sha = "bbb"
    ctrl:_poll_head()
    eq(1, refreshed)
    eq("bbb", ctrl._lastHead, "the new HEAD is recorded")
  end)

  it("does nothing when HEAD is unchanged", function()
    ctrl:_poll_head()
    eq(0, refreshed)
  end)

  it("tracks but does not refresh when in checkpoint mode", function()
    ctrl.model.current_mode = function() return "checkpoint" end
    sha = "bbb"
    ctrl:_poll_head()
    eq(0, refreshed, "checkpoint baseline is unaffected by a new commit")
    eq("bbb", ctrl._lastHead, "HEAD is still tracked for when the user toggles modes")
  end)

  it("is a no-op when HEAD is nil (repo with no commits)", function()
    sha = nil
    ctrl:_poll_head()
    eq(0, refreshed)
    eq("aaa", ctrl._lastHead)
  end)
end)
