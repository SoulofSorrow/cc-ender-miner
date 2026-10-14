-- cc-ender-miner - shared helpers
-- Copyright (C) 2026 Julian Schäfer
-- SPDX-License-Identifier: GPL-3.0-or-later

local M = {}

---@return number seconds
function M.now()
  if os.epoch then
    return os.epoch("utc") / 1000
  end
  return os.clock()
end

---@param value any
---@return any
function M.deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for k, v in pairs(value) do
    result[k] = M.deepCopy(v)
  end
  return result
end

---@param list string[]
---@return table<string, boolean>
function M.toSet(list)
  local set = {}
  for _, name in ipairs(list) do
    set[name] = true
  end
  return set
end

---@param value any
---@return boolean
function M.isInt(value)
  return type(value) == "number" and value == math.floor(value)
end

--- Readable text of an error value: fatal miner errors carry a table.
---@param err any
---@return string
function M.errText(err)
  if type(err) == "table" and err.msg then
    return tostring(err.msg)
  end
  return tostring(err)
end

return M
