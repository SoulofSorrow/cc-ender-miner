-- cc-ender-miner - configuration: defaults, validation, loading, saving
-- Copyright (C) 2026 Julian Schäfer
-- SPDX-License-Identifier: GPL-3.0-or-later

local util = require("endermine.util")

local M = {}

---@class MinerConfig
---@field tunnels integer Number of parallel tunnels
---@field width integer Tunnel width in blocks
---@field height integer Tunnel height in blocks
---@field length integer Tunnel length in blocks
---@field spacing integer Solid blocks between two tunnels
---@field side "left"|"right" Side on which additional columns and tunnels are dug
---@field useTorches boolean Place torches on the tunnel floor
---@field torchInterval integer Distance between two torches
---@field dropJunk boolean Drop junk items instead of sending them to the resource chest
---@field junkItems string[] Item ids treated as junk
---@field fuelItems string[] Item ids that may be burned from the loot slots and pulled from the supply chest
---@field torchItems string[] Item ids accepted as torches
---@field refuelFromLoot boolean Burn mined fuel items (e.g. coal) when fuel runs low
---@field fuelReserve integer Fuel kept on top of the distance home
---@field fuelBuffer integer Extra fuel taken in when refuelling
---@field minFreeSlots integer Unload when this few loot slots are free
---@field reportInterval number Seconds between two telemetry updates
---@field controllerId integer|nil Computer id of the monitor; nil broadcasts and accepts commands from anyone
---@field secret string|nil Shared secret the monitor must send with every command; nil accepts all
---@field returnOnError boolean Try to return to the start position after a fatal error
---@field avoidLava boolean Never step into lava, treat it as a blocked way

---@type MinerConfig
M.DEFAULT = {
  tunnels = 3,
  width = 3,
  height = 3,
  length = 48,
  spacing = 3,
  side = "right",
  useTorches = true,
  torchInterval = 8,
  dropJunk = true,
  junkItems = {
    "minecraft:cobblestone",
    "minecraft:cobbled_deepslate",
    "minecraft:dirt",
    "minecraft:gravel",
    "minecraft:andesite",
    "minecraft:diorite",
    "minecraft:granite",
    "minecraft:tuff",
    "minecraft:calcite",
    "minecraft:netherrack",
  },
  fuelItems = { "minecraft:coal", "minecraft:charcoal", "minecraft:coal_block" },
  torchItems = { "minecraft:torch" },
  refuelFromLoot = true,
  fuelReserve = 100,
  fuelBuffer = 1000,
  minFreeSlots = 2,
  reportInterval = 2,
  controllerId = nil,
  secret = nil,
  returnOnError = true,
  avoidLava = true,
}

local OPTIONAL_KEYS = { controllerId = true, secret = true }

M.INT_RULES = {
  tunnels = { 1, 64 },
  width = { 1, 64 },
  height = { 1, 64 },
  length = { 1, 4096 },
  spacing = { 0, 64 },
  torchInterval = { 2, 64 },
  fuelReserve = { 0, 100000 },
  fuelBuffer = { 0, 100000 },
  minFreeSlots = { 1, 6 },
}

local BOOL_KEYS = { "useTorches", "dropJunk", "refuelFromLoot", "returnOnError", "avoidLava" }
local LIST_KEYS = { "junkItems", "fuelItems", "torchItems" }
local MAX_SECRET_LENGTH = 64

--- Overlay known keys of override on a copy of base.
---@param base MinerConfig
---@param override table|nil
---@return MinerConfig cfg
---@return string[] unknown Keys of override that are not configuration options
function M.merge(base, override)
  local result = util.deepCopy(base)
  local unknown = {}
  if type(override) == "table" then
    for key, value in pairs(override) do
      if M.DEFAULT[key] ~= nil or OPTIONAL_KEYS[key] then
        result[key] = util.deepCopy(value)
      else
        unknown[#unknown + 1] = tostring(key)
      end
    end
  end
  table.sort(unknown)
  return result, unknown
end

---@param cfg table
---@return boolean ok
---@return string[] errors
function M.validate(cfg)
  local errors = {}
  for key, range in pairs(M.INT_RULES) do
    local value = cfg[key]
    if not util.isInt(value) or value < range[1] or value > range[2] then
      errors[#errors + 1] = string.format("%s must be a whole number between %d and %d", key, range[1], range[2])
    end
  end
  if cfg.side ~= "left" and cfg.side ~= "right" then
    errors[#errors + 1] = "side must be 'left' or 'right'"
  end
  for _, key in ipairs(BOOL_KEYS) do
    if type(cfg[key]) ~= "boolean" then
      errors[#errors + 1] = key .. " must be true or false"
    end
  end
  for _, key in ipairs(LIST_KEYS) do
    local list = cfg[key]
    local valid = type(list) == "table"
    if valid then
      for _, entry in ipairs(list) do
        if type(entry) ~= "string" then
          valid = false
        end
      end
    end
    if not valid then
      errors[#errors + 1] = key .. " must be a list of item ids"
    end
  end
  if type(cfg.reportInterval) ~= "number" or cfg.reportInterval < 0.2 or cfg.reportInterval > 60 then
    errors[#errors + 1] = "reportInterval must be a number between 0.2 and 60"
  end
  if cfg.controllerId ~= nil and (not util.isInt(cfg.controllerId) or cfg.controllerId < 0) then
    errors[#errors + 1] = "controllerId must be a computer id or nil"
  end
  if cfg.secret ~= nil and (type(cfg.secret) ~= "string" or cfg.secret == "" or #cfg.secret > MAX_SECRET_LENGTH) then
    errors[#errors + 1] = "secret must be a text of 1-" .. MAX_SECRET_LENGTH .. " characters or nil"
  end
  table.sort(errors)
  return #errors == 0, errors
end

---@param path string
---@return MinerConfig|nil cfg
---@return string|nil err
---@return string[]|nil unknown Ignored keys found in the file
function M.load(path)
  if not fs.exists(path) then
    return nil, "config file not found", nil
  end
  local handle, openErr = fs.open(path, "r")
  if not handle then
    return nil, "cannot open config: " .. tostring(openErr), nil
  end
  local content = handle.readAll()
  handle.close()
  local data = textutils.unserialize(content or "")
  if type(data) ~= "table" then
    return nil, "config file is not a valid table", nil
  end
  local cfg, unknown = M.merge(M.DEFAULT, data)
  local ok, errors = M.validate(cfg)
  if not ok then
    return nil, table.concat(errors, "; "), unknown
  end
  return cfg, nil, unknown
end

---@param path string
---@param cfg MinerConfig
function M.save(path, cfg)
  local handle, err = fs.open(path, "w")
  if not handle then
    error("cannot write config: " .. tostring(err), 0)
  end
  handle.write(textutils.serialize(cfg))
  handle.close()
end

return M
