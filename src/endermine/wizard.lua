-- cc-ender-miner - interactive setup and console prompts
-- Copyright (C) 2026 Julian Schäfer
-- SPDX-License-Identifier: GPL-3.0-or-later

local config = require("endermine.config")
local util = require("endermine.util")

local M = {}

local RULES = config.INT_RULES

---@param text string
---@param default any
---@return string
local function prompt(text, default)
  write(string.format("%s [%s]: ", text, tostring(default)))
  local input = read()
  if input == nil or input == "" then
    return tostring(default)
  end
  return input
end

---@param text string
---@param default integer
---@param min integer
---@param max integer
---@return integer
local function askInt(text, default, min, max)
  while true do
    local value = tonumber(prompt(text, default))
    if value and value == math.floor(value) and value >= min and value <= max then
      return value
    end
    printError(string.format("Enter a whole number %d-%d", min, max))
  end
end

---@param text string
---@param default boolean
---@return boolean
function M.askBool(text, default)
  while true do
    local answer = prompt(text .. " (y/n)", default and "y" or "n"):lower()
    if answer == "y" or answer == "yes" or answer == "j" then
      return true
    elseif answer == "n" or answer == "no" then
      return false
    end
    printError("Enter y or n")
  end
end

---@param version string
---@param base MinerConfig
---@return MinerConfig
function M.run(version, base)
  local cfg = util.deepCopy(base)
  term.clear()
  term.setCursorPos(1, 1)
  print("Ender Miner " .. version .. " setup")
  cfg.tunnels = askInt("Tunnels", cfg.tunnels, RULES.tunnels[1], RULES.tunnels[2])
  cfg.width = askInt("Width", cfg.width, RULES.width[1], RULES.width[2])
  cfg.height = askInt("Height", cfg.height, RULES.height[1], RULES.height[2])
  cfg.length = askInt("Length", cfg.length, RULES.length[1], RULES.length[2])
  if cfg.tunnels > 1 then
    cfg.spacing = askInt("Blocks between", cfg.spacing, RULES.spacing[1], RULES.spacing[2])
  end
  if cfg.tunnels > 1 or cfg.width > 1 then
    while true do
      local side = prompt("Side (left/right)", cfg.side):lower()
      if side == "l" or side == "left" then
        cfg.side = "left"
        break
      elseif side == "r" or side == "right" then
        cfg.side = "right"
        break
      end
      printError("Enter left or right")
    end
  end
  cfg.useTorches = M.askBool("Place torches", cfg.useTorches)
  if cfg.useTorches then
    cfg.torchInterval = askInt("Torch distance", cfg.torchInterval, RULES.torchInterval[1], RULES.torchInterval[2])
  end
  cfg.dropJunk = M.askBool("Drop cobble etc.", cfg.dropJunk)
  cfg.avoidLava = M.askBool("Avoid lava", cfg.avoidLava)
  local controller = askInt("Monitor PC id (-1=any)", cfg.controllerId or -1, -1, 65535)
  if controller < 0 then
    cfg.controllerId = nil
  else
    cfg.controllerId = controller
  end
  local secret = prompt("Command secret (-=none)", cfg.secret or "-")
  if secret == "-" then
    cfg.secret = nil
  else
    cfg.secret = secret:sub(1, 64)
  end
  return cfg
end

---@param version string
---@param cfg MinerConfig
function M.printSummary(version, cfg)
  term.clear()
  term.setCursorPos(1, 1)
  print("Ender Miner " .. version)
  print(
    string.format(
      "%d tunnel(s) %dx%dx%d, gap %d, %s",
      cfg.tunnels,
      cfg.width,
      cfg.height,
      cfg.length,
      cfg.spacing,
      cfg.side
    )
  )
  print(
    string.format(
      "Torches: %s  Drop junk: %s",
      cfg.useTorches and ("every " .. cfg.torchInterval) or "off",
      cfg.dropJunk and "yes" or "no"
    )
  )
  print("Monitor: " .. (cfg.controllerId and ("#" .. cfg.controllerId) or "broadcast"))
  print("Commands: " .. (cfg.secret and "secret required" or "no secret, anyone in range"))
  print("")
  print("1: supply ender chest (torches)")
  print("2: resource ender chest")
  print("3: torches  4: fuel  5-16: empty")
  print("")
end

--- Count down before an automatic resume, any key cancels.
---@param seconds integer
---@return boolean proceed
function M.countdown(seconds)
  local timer = os.startTimer(1)
  local left = seconds
  print(string.format("Resuming the mining job in %d s - press any key to cancel", left))
  while true do
    local ev, arg = os.pullEvent()
    if ev == "key" or ev == "char" then
      return false
    elseif ev == "timer" and arg == timer then
      left = left - 1
      if left <= 0 then
        return true
      end
      timer = os.startTimer(1)
    end
  end
end

return M
