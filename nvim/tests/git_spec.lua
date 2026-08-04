local git = require("review-loop.git")
local eq = assert.are.same

-- Helpers to build a deterministic throwaway git repository.
local function write(repo, path, content)
  local abs = repo .. "/" .. path
  vim.fn.mkdir(vim.fs.dirname(abs), "p")
  local f = assert(io.open(abs, "w"))
  f:write(content)
  f:close()
end

local function sh(repo, cmd)
  vim.system({ "sh", "-c", cmd }, { cwd = repo }):wait()
end

local function make_repo()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  sh(repo, "git init -q")
  sh(repo, "git config user.email t@t.t")
  sh(repo, "git config user.name t")
  sh(repo, "git config commit.gpgsign false")
  return repo
end

local function commit(repo, msg)
  sh(repo, "git add -A && git commit -q -m " .. vim.fn.shellescape(msg))
end

describe("git.parse_porcelain_paths", function()
  it("extracts paths from porcelain -z output", function()
    -- Two modified files.
    local out = " M src/a.ts\0 M src/b.ts\0"
    eq({ "src/a.ts", "src/b.ts" }, git.parse_porcelain_paths(out))
  end)

  it("includes the rename source for R/C entries", function()
    local out = "R  src/new.ts\0src/old.ts\0"
    eq({ "src/new.ts", "src/old.ts" }, git.parse_porcelain_paths(out))
  end)

  it("dedupes while preserving order", function()
    local out = " M a\0?? b\0 M a\0"
    eq({ "a", "b" }, git.parse_porcelain_paths(out))
  end)
end)

describe("git repo against a real temp repo", function()
  local repo
  before_each(function()
    repo = make_repo()
    write(repo, "committed.txt", "committed\n")
    commit(repo, "init")
  end)
  after_each(function()
    vim.fn.delete(repo, "rf")
  end)

  it("reads head sha and branch", function()
    assert.truthy(git.head_sha(repo))
    assert.truthy(git.branch_name(repo))
  end)

  it("reports a modified file as modified against HEAD", function()
    write(repo, "committed.txt", "changed\n")
    local pairs = git.scan_against_head(repo)
    eq(1, #pairs)
    eq("committed.txt", pairs[1].path)
    eq("modified", pairs[1].status)
    eq("committed\n", pairs[1].originalContent)
    eq("changed\n", pairs[1].modifiedContent)
  end)

  it("reports a new untracked file as added", function()
    write(repo, "new.txt", "fresh\n")
    local pairs = git.scan_against_head(repo)
    local by_path = {}
    for _, p in ipairs(pairs) do by_path[p.path] = p end
    eq("added", by_path["new.txt"].status)
    eq("", by_path["new.txt"].originalContent)
    eq("fresh\n", by_path["new.txt"].modifiedContent)
  end)

  it("reports a deleted tracked file as deleted", function()
    vim.fn.delete(repo .. "/committed.txt")
    local pairs = git.scan_against_head(repo)
    eq(1, #pairs)
    eq("deleted", pairs[1].status)
    eq("", pairs[1].modifiedContent)
  end)

  it("scan_against_checkpoint shows only changes after the checkpoint baseline", function()
    -- Establish a checkpoint baseline over a DIRTY tree so an override exists.
    write(repo, "committed.txt", "dirty\n")
    local cp = git.create_checkpoint(repo, { "committed.txt" }, "")
    assert.truthy(cp.overrides["committed.txt"])

    -- Against this checkpoint, the dirty state is the baseline: nothing changed yet.
    eq({}, git.scan_against_checkpoint(repo, cp))

    -- Modify again -> one change vs checkpoint.
    write(repo, "committed.txt", "changed again\n")
    local pairs = git.scan_against_checkpoint(repo, cp)
    eq(1, #pairs)
    eq("modified", pairs[1].status)
    eq("dirty\n", pairs[1].originalContent)
  end)
end)
