-- Structured debug log for observability (o11y). Off by default; enable via
-- config.debug = true or :ReviewLoopDebug (toggles at runtime).
--
-- Append-only lines to stdpath("data")/review-loop/review-loop.log:
--   2024-01-01T12:00:00 EVENT key=value key="spaced value" ...
-- Pure: only io + vim.fn for path/time. No window/buffer APIs, so it is safe
-- to call from inside scheduled callbacks and tests. data_dir is overridable
-- so tests never touch the user's real log.

local M = {}

-- Override in tests to redirect the file; nil -> stdpath("data")/review-loop.
M.data_dir = nil
-- Cache of the resolved enable flag. nil = "resolve from config on next read".
M._enabled = nil

local function base_dir()
  return M.data_dir or (vim.fn.stdpath("data") .. "/review-loop")
end

function M.path()
  return base_dir() .. "/review-loop.log"
end

function M.enabled()
  if M._enabled ~= nil then
    return M._enabled
  end
  local ok, cfg = pcall(require, "review-loop.config")
  M._enabled = (ok and cfg.get().debug) and true or false
  return M._enabled
end

-- Force the flag (tests / :ReviewLoopDebug). Bypasses config resolution.
function M.set_enabled(v)
  M._enabled = v and true or false
end

-- Flip the flag and return the new state.
function M.toggle()
  M._enabled = not M.enabled()
  return M._enabled
end

-- _now() is split out so tests can stub the timestamp if they ever need to.
function M._now()
  return os.date("%Y-%m-%dT%H:%M:%S")
end

-- Format a single value: numbers/bools bare, nil -> <nil>, tables -> JSON,
-- strings quoted only when they contain a space or a quote.
local function fmt_value(v)
  if v == nil then
    return "<nil>"
  end
  local ty = type(v)
  if ty == "boolean" then
    return v and "true" or "false"
  end
  if ty == "number" then
    return tostring(v)
  end
  if ty == "table" then
    return vim.json.encode(v)
  end
  -- string
  if v:find("[ %s\"]") then
    return "\"" .. v:gsub("\"", "\\\"") .. "\""
  end
  return v
end

-- _format(event, kv) -> deterministic line body (no timestamp).
-- kv key order is preserved as given so callers control readability.
function M._format(event, kv)
  local parts = { event }
  if kv then
    -- Sort keys for deterministic, greppable lines (Lua pairs() is unordered).
    local keys = {}
    for k in pairs(kv) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      parts[#parts + 1] = k .. "=" .. fmt_value(kv[k])
    end
  end
  return table.concat(parts, " ")
end

-- debug(event, kv) appends a timestamped line when enabled; no-op otherwise.
-- Never throws: a logging failure must not break the reviewed workflow.
function M.debug(event, kv)
  if not M.enabled() then
    return
  end
  local line = M._now() .. " " .. M._format(event, kv) .. "\n"
  local p = M.path()
  pcall(vim.fn.mkdir, vim.fs.dirname(p), "p")
  local f = io.open(p, "a")
  if f then
    f:write(line)
    f:close()
  end
end

-- clear() truncates the log file.
function M.clear()
  local f = io.open(M.path(), "w")
  if f then
    f:close()
  end
end

return M
