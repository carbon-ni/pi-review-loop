local adapter = require("review-loop.ui.diff")
local eq = assert.are.same

local function changed(path, status)
  return { path = path, status = status, fingerprint = "fp-" .. path }
end

describe("Diffview adapter", function()
  it("maps review-loop files to Diffview working entries and selects most recent", function()
    local files = adapter.file_dict({
      files = {
        changed("src/modified.lua", "modified"),
        changed("src/added.lua", "added"),
        changed("src/deleted.lua", "deleted"),
      },
      recentPaths = { "src/added.lua", "src/modified.lua", "src/deleted.lua" },
    })

    eq(3, #files.working)
    eq("M", files.working[1].status)
    eq("A", files.working[2].status)
    eq("D", files.working[3].status)
    eq(false, files.working[1].selected)
    eq(true, files.working[2].selected)
    eq({}, files.staged)
    eq({}, files.conflicting)
  end)

  it("returns checkpoint and current buffer lines without a phantom trailing line", function()
    local requested
    local model = {
      current_mode = function() return "checkpoint" end,
      get_file = function(_, path, mode)
        requested = { path, mode }
        return {
          originalContent = "before\nline\n",
          modifiedContent = "after\nline\n",
        }
      end,
    }

    eq({ "before", "line" }, adapter.file_data(model, "working", "a.txt", "left"))
    eq({ "a.txt", "checkpoint" }, requested)
    eq({ "after", "line" }, adapter.file_data(model, "working", "a.txt", "right"))
  end)

  it("returns nil when Diffview requests a file that disappeared during refresh", function()
    local model = {
      current_mode = function() return "head" end,
      get_file = function() error("gone") end,
    }

    assert.is_nil(adapter.file_data(model, "working", "gone.txt", "left"))
  end)

  it("labels each mode with a distinct stable baseline revision", function()
    local checkpoint_model = {
      current_mode = function() return "checkpoint" end,
      current_checkpoint = function()
        return { headSha = "abc123", createdAt = "2026-08-04T10:00:00Z" }
      end,
    }
    local head_model = {
      current_mode = function() return "head" end,
      current_checkpoint = function() return nil end,
    }

    eq("review-loop-checkpoint-abc123-2026-08-04T10:00:00Z", adapter.baseline_revision(checkpoint_model, "head-now"))
    eq("review-loop-head-head-now", adapter.baseline_revision(head_model, "head-now"))
  end)
end)
