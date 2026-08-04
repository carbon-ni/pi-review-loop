local feedback = require("review-loop.feedback")
local eq = assert.are.same

describe("feedback.location", function()
  it("returns path for file-level comments", function()
    eq("src/x.ts", feedback.location({ path = "src/x.ts", side = "file", line = nil }))
  end)

  it("marks modified side as (current)", function()
    eq("src/x.ts:10 (current)",
      feedback.location({ path = "src/x.ts", side = "modified", line = 10, mode = "checkpoint" }))
  end)

  it("marks original side by mode", function()
    eq("a.go:5 (HEAD)", feedback.location({ path = "a.go", side = "original", line = 5, mode = "head" }))
    eq("a.go:5 (reviewed)", feedback.location({ path = "a.go", side = "original", line = 5, mode = "checkpoint" }))
  end)
end)

describe("feedback.compose", function()
  it("returns empty string for no comments", function()
    eq("", feedback.compose({}))
  end)

  it("skips blank and whitespace-only bodies", function()
    eq("", feedback.compose({
      { path = "a", side = "file", body = "   " },
      { path = "b", side = "file", body = "" },
    }))
  end)

  it("numbers valid comments and indents bodies", function()
    local out = feedback.compose({
      { path = "src/x.ts", mode = "checkpoint", side = "modified", line = 10, body = "fix this" },
    })
    eq("Please address the following review feedback:\n\n1. src/x.ts:10 (current)\n   fix this", out)
  end)

  it("indents each line of a multiline body with three spaces", function()
    local out = feedback.compose({
      { path = "a.go", mode = "head", side = "original", line = 5, body = "line1\nline2" },
    })
    eq("Please address the following review feedback:\n\n1. a.go:5 (HEAD)\n   line1\n   line2", out)
  end)

  it("numbers multiple comments in order", function()
    local out = feedback.compose({
      { path = "a", side = "file", body = "one" },
      { path = "b", side = "file", body = "two" },
    })
    eq("Please address the following review feedback:\n\n1. a\n   one\n\n2. b\n   two", out)
  end)
end)
