-- Composes review comments into a feedback text block.
-- Port of src/prompt.ts (composeFeedback / location). Output is byte-for-byte
-- compatible with the TypeScript implementation so the agent sees identical text.

local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- location(comment) mirrors prompt.ts#location
local function location(comment)
  if comment.side == "file" or comment.line == nil then
    return comment.path
  end
  local suffix
  if comment.side == "original" then
    suffix = comment.mode == "head" and " (HEAD)" or " (reviewed)"
  else
    suffix = " (current)"
  end
  return comment.path .. ":" .. tostring(comment.line) .. suffix
end

-- compose(comments) -> string
-- Returns "" when no comment has a non-blank body.
function M.compose(comments)
  local valid = {}
  for _, c in ipairs(comments) do
    if #trim(c.body or "") > 0 then
      valid[#valid + 1] = c
    end
  end
  if #valid == 0 then
    return ""
  end

  local lines = { "Please address the following review feedback:", "" }
  for i, c in ipairs(valid) do
    lines[#lines + 1] = i .. ". " .. location(c)
    local indented = trim(c.body):gsub("\n", "\n   ")
    lines[#lines + 1] = "   " .. indented
    lines[#lines + 1] = ""
  end
  return trim(table.concat(lines, "\n"))
end

M.location = location

return M
