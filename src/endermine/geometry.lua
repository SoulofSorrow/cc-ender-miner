-- cc-ender-miner - geometry: tunnel bands and GPS frame conversion
-- Copyright (C) 2026 Julian Schäfer
-- SPDX-License-Identifier: GPL-3.0-or-later

local M = {}

-- Movement delta {dx, dz} per facing: 0 = forward, 1 = right, 2 = back, 3 = left
M.DELTA = { [0] = { 0, 1 }, [1] = { 1, 0 }, [2] = { 0, -1 }, [3] = { -1, 0 } }

---@class Band
---@field low integer
---@field high integer
---@field center integer

--- Split the tunnel height into horizontal bands of up to three blocks.
--- The turtle travels through the center row of a band and digs the rows
--- above and below it, so one pass clears three rows.
---@param height integer
---@return Band[]
function M.computeBands(height)
  local bands = {}
  local low = 0
  while low <= height - 1 do
    local high = math.min(low + 2, height - 1)
    local center = low
    if high > low then
      center = low + 1
    end
    bands[#bands + 1] = { low = low, high = high, center = center }
    low = low + 3
  end
  return bands
end

---@class GpsFrame
---@field x integer Absolute x of the start block
---@field y integer Absolute y of the start block
---@field z integer Absolute z of the start block
---@field dx integer Absolute x step of relative facing 0
---@field dz integer Absolute z step of relative facing 0

--- Convert an absolute GPS position into job coordinates.
---@param frame GpsFrame
---@param ax number
---@param ay number
---@param az number
---@return integer x
---@return integer y
---@return integer z
function M.toRelative(frame, ax, ay, az)
  local ox, oz = ax - frame.x, az - frame.z
  -- Facing 1 (right) is facing 0 turned clockwise: (dx, dz) -> (-dz, dx)
  local rz = ox * frame.dx + oz * frame.dz
  local rx = ox * -frame.dz + oz * frame.dx
  return math.floor(rx + 0.5), math.floor(ay - frame.y + 0.5), math.floor(rz + 0.5)
end

--- Relative facing of an absolute horizontal step, nil if it is not one.
---@param frame GpsFrame
---@param adx integer
---@param adz integer
---@return integer|nil
function M.facingOf(frame, adx, adz)
  local rz = adx * frame.dx + adz * frame.dz
  local rx = adx * -frame.dz + adz * frame.dx
  for f = 0, 3 do
    if M.DELTA[f][1] == rx and M.DELTA[f][2] == rz then
      return f
    end
  end
  return nil
end

return M
