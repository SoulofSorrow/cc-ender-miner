-- cc-ender-miner - tunnel mining program for CC: Tweaked mining turtles
-- Copyright (C) 2026 Julian Schäfer
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Slot layout:
--    1     ender chest linked to the SUPPLY chest (torches, optional fuel)
--    2     ender chest linked to the RESOURCE chest (everything that is mined)
--    3     torches
--    4     fuel
--    5-16  mined items
--
-- Coordinates are relative to the start position: +z is the direction the
-- turtle faces when started, +x is to its right, +y is up.

local VERSION = "1.0.0"
local PROTOCOL = "endermine.v1"
local CONFIG_FILE = "miner.cfg"

local SLOT_SUPPLY = 1
local SLOT_DUMP = 2
local SLOT_TORCH = 3
local SLOT_FUEL = 4
local FIRST_LOOT = 5
local LAST_SLOT = 16
local LOOT_SLOTS = LAST_SLOT - FIRST_LOOT + 1

local MAX_DIG_ATTEMPTS = 64
local MAX_MOVE_ATTEMPTS = 64
local MAX_SUCK_ROUNDS = 8
local MAX_EVENTS = 5
local MAX_REPORTED_ORES = 16
local FALL_DELAY = 0.4

-- Blocks that fall when the block below them is removed
local FALLING = {
  ["minecraft:gravel"] = true,
  ["minecraft:sand"] = true,
  ["minecraft:red_sand"] = true,
  ["minecraft:suspicious_gravel"] = true,
  ["minecraft:suspicious_sand"] = true,
}

---@alias Direction "fwd"|"up"|"down"

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
---@field returnOnError boolean Try to return to the start position after a fatal error

---@type MinerConfig
local DEFAULT_CONFIG = {
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
  returnOnError = true,
}

local OPTIONAL_KEYS = { controllerId = true }

local INT_RULES = {
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

local BOOL_KEYS = { "useTorches", "dropJunk", "refuelFromLoot", "returnOnError" }
local LIST_KEYS = { "junkItems", "fuelItems", "torchItems" }

local DIRS = {
  fwd = {
    move = "forward",
    dig = "dig",
    detect = "detect",
    inspect = "inspect",
    place = "place",
    drop = "drop",
    suck = "suck",
    attack = "attack",
  },
  up = {
    move = "up",
    dig = "digUp",
    detect = "detectUp",
    inspect = "inspectUp",
    place = "placeUp",
    drop = "dropUp",
    suck = "suckUp",
    attack = "attackUp",
  },
  down = {
    move = "down",
    dig = "digDown",
    detect = "detectDown",
    inspect = "inspectDown",
    place = "placeDown",
    drop = "dropDown",
    suck = "suckDown",
    attack = "attackDown",
  },
}

-- Movement delta {dx, dz} per facing: 0 = forward, 1 = right, 2 = back, 3 = left
local DELTA = { [0] = { 0, 1 }, [1] = { 1, 0 }, [2] = { 0, -1 }, [3] = { -1, 0 } }
local CHEST_PLACE_ORDER = { "up", "down", "fwd" }
-- Sideways {dx, dy} offsets tried when the direct way home is blocked
local HOME_DETOURS = { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 2, 0 }, { -2, 0 } }
local ABORT = { abort = true }

---@param dir Direction
---@param action string
---@return any ...
local function act(dir, action, ...)
  return turtle[DIRS[dir][action]](...)
end

---@return number seconds
local function now()
  if os.epoch then
    return os.epoch("utc") / 1000
  end
  return os.clock()
end

---@param value any
---@return any
local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for k, v in pairs(value) do
    result[k] = deepCopy(v)
  end
  return result
end

---@param list string[]
---@return table<string, boolean>
local function toSet(list)
  local set = {}
  for _, name in ipairs(list) do
    set[name] = true
  end
  return set
end

---@param value any
---@return boolean
local function isInt(value)
  return type(value) == "number" and value == math.floor(value)
end

---@param base MinerConfig
---@param override table|nil
---@return MinerConfig
local function mergeConfig(base, override)
  local result = deepCopy(base)
  if type(override) == "table" then
    for key, value in pairs(override) do
      if DEFAULT_CONFIG[key] ~= nil or OPTIONAL_KEYS[key] then
        result[key] = deepCopy(value)
      end
    end
  end
  return result
end

---@param cfg table
---@return boolean ok
---@return string[] errors
local function validateConfig(cfg)
  local errors = {}
  for key, range in pairs(INT_RULES) do
    local value = cfg[key]
    if not isInt(value) or value < range[1] or value > range[2] then
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
  if cfg.controllerId ~= nil and (not isInt(cfg.controllerId) or cfg.controllerId < 0) then
    errors[#errors + 1] = "controllerId must be a computer id or nil"
  end
  table.sort(errors)
  return #errors == 0, errors
end

---@param path string
---@return MinerConfig|nil cfg
---@return string|nil err
local function loadConfig(path)
  if not fs.exists(path) then
    return nil, "config file not found"
  end
  local handle, openErr = fs.open(path, "r")
  if not handle then
    return nil, "cannot open config: " .. tostring(openErr)
  end
  local content = handle.readAll()
  handle.close()
  local data = textutils.unserialize(content or "")
  if type(data) ~= "table" then
    return nil, "config file is not a valid table"
  end
  local cfg = mergeConfig(DEFAULT_CONFIG, data)
  local ok, errors = validateConfig(cfg)
  if not ok then
    return nil, table.concat(errors, "; ")
  end
  return cfg, nil
end

---@param path string
---@param cfg MinerConfig
local function saveConfig(path, cfg)
  local handle, err = fs.open(path, "w")
  if not handle then
    error("cannot write config: " .. tostring(err), 0)
  end
  handle.write(textutils.serialize(cfg))
  handle.close()
end

---@class Band
---@field low integer
---@field high integer
---@field center integer

--- Split the tunnel height into horizontal bands of up to three blocks.
--- The turtle travels through the center row of a band and digs the rows
--- above and below it, so one pass clears three rows.
---@param height integer
---@return Band[]
local function computeBands(height)
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

---@param data table
---@return boolean
local function isOre(data)
  if type(data.tags) == "table" and (data.tags["c:ores"] or data.tags["forge:ores"]) then
    return true
  end
  local name = type(data.name) == "string" and data.name or ""
  return name:find("_ore$") ~= nil or name == "minecraft:ancient_debris"
end

---@param cfg MinerConfig
---@return table miner
local function createMiner(cfg)
  local self = {}

  local pos = { x = 0, y = 0, z = 0, f = 0 }
  local control = { paused = false, abort = false }
  local homing = false
  local state, message = "starting", ""
  local events = {}
  local lastReport = -math.huge
  local modemName = nil
  local chestDetails = {}
  local warnedNoTorches = false

  local junkSet = toSet(cfg.junkItems)
  local fuelSet = toSet(cfg.fuelItems)
  local torchSet = toSet(cfg.torchItems)
  local sideSign = cfg.side == "left" and -1 or 1
  local bands = computeBands(cfg.height)

  local stats = {
    mined = 0,
    moved = 0,
    torchesPlaced = 0,
    dumps = 0,
    itemsDumped = 0,
    resupplies = 0,
    junkDropped = 0,
    ores = {},
    cellsDone = 0,
    cellsTotal = cfg.tunnels * #bands * cfg.width * cfg.length,
    tunnel = 0,
    startedAt = now(),
  }

  -- Forward declarations for mutually dependent helpers
  local report, checkpoint, ensureFuel, resupply, dumpToChest

  ---@param msg string
  local function fail(msg)
    error({ fatal = true, msg = string.format("%s (at %d/%d/%d)", msg, pos.x, pos.y, pos.z) }, 0)
  end

  ---@param newState string
  ---@param msg string|nil
  local function setState(newState, msg)
    state = newState
    message = msg or ""
  end

  ---@param payload table
  local function transmit(payload)
    if not modemName then
      return
    end
    local ok, err = pcall(function()
      if cfg.controllerId then
        rednet.send(cfg.controllerId, payload, PROTOCOL)
      else
        rednet.broadcast(payload, PROTOCOL)
      end
    end)
    if not ok then
      modemName = nil
      events[1] = "Telemetry disabled: " .. tostring(err)
    end
  end

  ---@param text string
  ---@param level string|nil
  local function event(text, level)
    table.insert(events, 1, text)
    while #events > MAX_EVENTS do
      table.remove(events)
    end
    transmit({
      type = "event",
      id = os.getComputerID(),
      level = level or "info",
      text = text,
    })
  end

  ---@param slot integer
  ---@return integer
  local function itemCount(slot)
    return turtle.getItemCount(slot)
  end

  ---@param slot integer
  ---@return table|nil
  local function detail(slot)
    if turtle.getItemCount(slot) == 0 then
      return nil
    end
    return turtle.getItemDetail(slot)
  end

  ---@return integer
  local function freeLootSlots()
    local free = 0
    for slot = FIRST_LOOT, LAST_SLOT do
      if itemCount(slot) == 0 then
        free = free + 1
      end
    end
    return free
  end

  ---@return integer|nil
  local function firstEmptyLootSlot()
    for slot = FIRST_LOOT, LAST_SLOT do
      if itemCount(slot) == 0 then
        return slot
      end
    end
    return nil
  end

  ---@return number
  local function fuelLevel()
    local level = turtle.getFuelLevel()
    if level == "unlimited" then
      return math.huge
    end
    return level
  end

  ---@return integer
  local function distanceHome()
    return math.abs(pos.x) + math.abs(pos.y) + math.abs(pos.z)
  end

  ---@param data table
  local function recordBlock(data)
    stats.mined = stats.mined + 1
    if isOre(data) then
      stats.ores[data.name] = (stats.ores[data.name] or 0) + 1
    end
  end

  ---@return table[]
  local function topOres()
    local list = {}
    for name, count in pairs(stats.ores) do
      list[#list + 1] = { name = name, count = count }
    end
    table.sort(list, function(a, b)
      if a.count == b.count then
        return a.name < b.name
      end
      return a.count > b.count
    end)
    while #list > MAX_REPORTED_ORES do
      table.remove(list)
    end
    return list
  end

  ---@return table
  local function buildStatus()
    local elapsed = math.max(now() - stats.startedAt, 0)
    local eta = nil
    if stats.cellsDone > 0 and stats.cellsTotal > stats.cellsDone then
      eta = elapsed / stats.cellsDone * (stats.cellsTotal - stats.cellsDone)
    end
    local fuel = turtle.getFuelLevel()
    local limit = turtle.getFuelLimit()
    local torches = 0
    local torchDetail = detail(SLOT_TORCH)
    if torchDetail and torchSet[torchDetail.name] then
      torches = torchDetail.count
    end
    local id = os.getComputerID()
    return {
      type = "status",
      v = 1,
      id = id,
      label = os.getComputerLabel() or ("Turtle #" .. id),
      version = VERSION,
      state = state,
      message = message,
      pos = { x = pos.x, y = pos.y, z = pos.z, f = pos.f },
      fuel = fuel == "unlimited" and -1 or fuel,
      fuelLimit = limit == "unlimited" and -1 or limit,
      progress = {
        done = stats.cellsDone,
        total = stats.cellsTotal,
        tunnel = stats.tunnel,
        tunnels = cfg.tunnels,
      },
      inventory = { used = LOOT_SLOTS - freeLootSlots(), total = LOOT_SLOTS },
      torches = torches,
      torchesPlaced = stats.torchesPlaced,
      mined = stats.mined,
      moved = stats.moved,
      dumps = stats.dumps,
      itemsDumped = stats.itemsDumped,
      resupplies = stats.resupplies,
      junkDropped = stats.junkDropped,
      uptime = elapsed,
      eta = eta,
      ores = topOres(),
      job = {
        tunnels = cfg.tunnels,
        width = cfg.width,
        height = cfg.height,
        length = cfg.length,
        spacing = cfg.spacing,
        side = cfg.side,
      },
    }
  end

  local function updateScreen()
    if not term or not term.getSize then
      return
    end
    local width = term.getSize()
    local percent = 0
    if stats.cellsTotal > 0 then
      percent = stats.cellsDone / stats.cellsTotal * 100
    end
    local lines = {
      string.format("Ender Miner %s  #%d", VERSION, os.getComputerID()),
      "State: " .. state,
      message,
      string.format("Tunnel %d/%d  %.1f%%", stats.tunnel, cfg.tunnels, percent),
      string.format("Fuel: %s", tostring(turtle.getFuelLevel())),
      string.format("Pos: %d %d %d", pos.x, pos.y, pos.z),
      string.format("Mined %d  Torches %d  Unloads %d", stats.mined, stats.torchesPlaced, stats.dumps),
      modemName and ("Telemetry: " .. PROTOCOL) or "Telemetry: off",
      "",
    }
    for _, text in ipairs(events) do
      lines[#lines + 1] = "> " .. text
    end
    term.clear()
    for i, text in ipairs(lines) do
      term.setCursorPos(1, i)
      term.write(text:sub(1, width))
    end
  end

  ---@param force boolean
  report = function(force)
    local t = now()
    if not force and t - lastReport < cfg.reportInterval then
      return
    end
    lastReport = t
    updateScreen()
    transmit(buildStatus())
  end

  ---@param dir Direction
  ---@return boolean ok
  ---@return string|nil reason
  local function dig(dir)
    local attempts = 0
    while act(dir, "detect") do
      attempts = attempts + 1
      if attempts > MAX_DIG_ATTEMPTS then
        return false, "block keeps coming back"
      end
      local hasBlock, data = act(dir, "inspect")
      local name = hasBlock and type(data) == "table" and data.name or ""
      if type(name) == "string" and name:find("^computercraft:turtle") then
        -- Never mine other turtles, wait for them to move away instead
        sleep(1)
      else
        local ok, reason = act(dir, "dig")
        if ok then
          if hasBlock and type(data) == "table" then
            recordBlock(data)
          end
          if FALLING[name] and dir ~= "down" then
            -- Give gravel and sand above the time to fall into the gap
            sleep(FALL_DELAY)
          end
        else
          local text = tostring(reason or ""):lower()
          if text:find("unbreakable") or text:find("no tool") or text:find("protected") then
            return false, tostring(reason)
          end
          sleep(0.25)
        end
      end
    end
    return true, nil
  end

  ---@param dir Direction
  ---@return boolean ok
  ---@return string|nil reason
  local function step(dir)
    ensureFuel(1)
    for _ = 1, MAX_MOVE_ATTEMPTS do
      if act(dir, "move") then
        if dir == "fwd" then
          pos.x = pos.x + DELTA[pos.f][1]
          pos.z = pos.z + DELTA[pos.f][2]
        elseif dir == "up" then
          pos.y = pos.y + 1
        else
          pos.y = pos.y - 1
        end
        stats.moved = stats.moved + 1
        return true, nil
      end
      if act(dir, "detect") then
        local ok, reason = dig(dir)
        if not ok then
          return false, reason
        end
      else
        -- Probably a mob or an item frame in the way
        act(dir, "attack")
        sleep(0.25)
      end
    end
    return false, "movement blocked"
  end

  ---@param dir Direction
  local function mustStep(dir)
    local ok, reason = step(dir)
    if not ok then
      fail("Cannot move " .. dir .. ": " .. tostring(reason))
    end
  end

  local function turnRight()
    if not turtle.turnRight() then
      fail("Cannot turn right")
    end
    pos.f = (pos.f + 1) % 4
  end

  local function turnLeft()
    if not turtle.turnLeft() then
      fail("Cannot turn left")
    end
    pos.f = (pos.f + 3) % 4
  end

  ---@param facing integer
  local function face(facing)
    local diff = (facing - pos.f) % 4
    if diff == 1 then
      turnRight()
    elseif diff == 2 then
      turnRight()
      turnRight()
    elseif diff == 3 then
      turnLeft()
    end
  end

  ---@param axis "x"|"y"|"z"
  ---@param target integer
  local function moveAxis(axis, target)
    if axis == "y" then
      while pos.y < target do
        mustStep("up")
        checkpoint()
      end
      while pos.y > target do
        mustStep("down")
        checkpoint()
      end
    elseif axis == "x" then
      if pos.x ~= target then
        face(target > pos.x and 1 or 3)
      end
      while pos.x ~= target do
        mustStep("fwd")
        checkpoint()
      end
    else
      if pos.z ~= target then
        face(target > pos.z and 0 or 2)
      end
      while pos.z ~= target do
        mustStep("fwd")
        checkpoint()
      end
    end
  end

  ---@param x integer
  ---@param y integer
  ---@param z integer
  ---@param order string|nil Axis order, e.g. "yxz"
  local function goTo(x, y, z, order)
    order = order or "xyz"
    local targets = { x = x, y = y, z = z }
    for i = 1, #order do
      local axis = order:sub(i, i)
      moveAxis(axis, targets[axis])
    end
  end

  --- Move foreign items out of the torch and fuel slots.
  local function sanitizeSpecialSlots()
    local torch = detail(SLOT_TORCH)
    if torch and not torchSet[torch.name] then
      local target = firstEmptyLootSlot()
      if target then
        turtle.select(SLOT_TORCH)
        turtle.transferTo(target)
      end
    end
    if itemCount(SLOT_FUEL) > 0 then
      turtle.select(SLOT_FUEL)
      if not turtle.refuel(0) then
        local target = firstEmptyLootSlot()
        if target then
          turtle.transferTo(target)
        end
      end
    end
    turtle.select(FIRST_LOOT)
  end

  ---@param slot integer
  ---@param target number
  ---@param anyFuel boolean Accept every burnable item, not only configured fuel items
  local function burnSlot(slot, target, anyFuel)
    local item = detail(slot)
    if not item or (not anyFuel and not fuelSet[item.name]) then
      return
    end
    turtle.select(slot)
    while itemCount(slot) > 0 and fuelLevel() < target do
      if not turtle.refuel(1) then
        break
      end
    end
    turtle.select(FIRST_LOOT)
  end

  ---@param need number
  ---@return number
  local function fuelTarget(need)
    local limit = turtle.getFuelLimit()
    if limit == "unlimited" then
      return math.huge
    end
    return math.min(limit, need + cfg.fuelBuffer)
  end

  ---@param target number
  local function refuelLocal(target)
    burnSlot(SLOT_FUEL, target, true)
    if cfg.refuelFromLoot then
      for slot = FIRST_LOOT, LAST_SLOT do
        if fuelLevel() >= target then
          break
        end
        burnSlot(slot, target, false)
      end
    end
  end

  ---@param slot integer
  ---@return string|nil dir
  ---@return string|nil err
  local function placeChest(slot)
    if itemCount(slot) == 0 then
      return nil, "no ender chest in slot " .. slot
    end
    chestDetails[slot] = detail(slot)
    for _, dir in ipairs(CHEST_PLACE_ORDER) do
      if not act(dir, "detect") then
        turtle.select(slot)
        if act(dir, "place") then
          turtle.select(FIRST_LOOT)
          return dir, nil
        end
      end
    end
    for _, dir in ipairs(CHEST_PLACE_ORDER) do
      turtle.select(FIRST_LOOT)
      if dig(dir) then
        turtle.select(slot)
        if act(dir, "place") then
          turtle.select(FIRST_LOOT)
          return dir, nil
        end
      end
    end
    turtle.select(FIRST_LOOT)
    return nil, "no space to place the ender chest"
  end

  ---@param slot integer
  ---@param dir Direction
  local function pickupChest(slot, dir)
    turtle.select(slot)
    local _, reason = act(dir, "dig")
    if itemCount(slot) == 0 then
      -- The chest landed in another slot, move it back
      local wanted = chestDetails[slot]
      for other = SLOT_TORCH, LAST_SLOT do
        local item = detail(other)
        if wanted and item and item.name == wanted.name and item.nbt == wanted.nbt then
          turtle.select(other)
          turtle.transferTo(slot)
          break
        end
      end
    end
    turtle.select(FIRST_LOOT)
    if itemCount(slot) == 0 then
      fail("Could not pick up the ender chest from slot " .. slot .. ": " .. tostring(reason))
    end
  end

  ---@param slot integer
  ---@return boolean
  local function shouldDump(slot)
    if itemCount(slot) == 0 then
      return false
    end
    if slot >= FIRST_LOOT then
      return true
    end
    if slot == SLOT_TORCH then
      local item = detail(slot)
      return item ~= nil and not torchSet[item.name]
    end
    if slot == SLOT_FUEL then
      turtle.select(slot)
      local burnable = turtle.refuel(0)
      turtle.select(FIRST_LOOT)
      return not burnable
    end
    return false
  end

  dumpToChest = function()
    local prevState, prevMsg = state, message
    setState("dumping", "Unloading into the resource chest")
    local dir, err = placeChest(SLOT_DUMP)
    if not dir then
      fail("Cannot place the resource chest: " .. tostring(err))
    end
    local dumped = 0
    for slot = SLOT_TORCH, LAST_SLOT do
      if shouldDump(slot) then
        turtle.select(slot)
        local waiting = false
        while itemCount(slot) > 0 do
          local before = itemCount(slot)
          if act(dir, "drop") then
            dumped = dumped + before - itemCount(slot)
          else
            if not waiting then
              waiting = true
              event("Resource chest is full - waiting", "warn")
            end
            setState("chest_full", "Resource ender chest is full, empty it")
            report(true)
            sleep(5)
            if control.abort and not homing then
              break
            end
          end
        end
        if waiting then
          setState("dumping", "Unloading into the resource chest")
        end
      end
    end
    turtle.select(FIRST_LOOT)
    pickupChest(SLOT_DUMP, dir)
    stats.dumps = stats.dumps + 1
    stats.itemsDumped = stats.itemsDumped + dumped
    event(string.format("Unloaded %d items", dumped))
    setState(prevState, prevMsg)
  end

  ---@param slot integer
  ---@param set table<string, boolean>
  ---@return integer
  local function spaceFor(slot, set)
    local item = detail(slot)
    if not item then
      return 64
    end
    if set and not set[item.name] then
      return 0
    end
    return turtle.getItemSpace(slot)
  end

  ---@param wantTorches boolean
  ---@param wantFuel boolean
  ---@return boolean gotSomething
  resupply = function(wantTorches, wantFuel)
    if itemCount(SLOT_SUPPLY) == 0 then
      return false
    end
    sanitizeSpecialSlots()
    if freeLootSlots() < 2 then
      dumpToChest()
    end
    if freeLootSlots() < 2 then
      return false
    end
    local prevState, prevMsg = state, message
    setState("resupply", "Fetching supplies from the supply chest")
    local dir, err = placeChest(SLOT_SUPPLY)
    if not dir then
      event("Cannot place supply chest: " .. tostring(err), "warn")
      setState(prevState, prevMsg)
      return false
    end
    local gotTorches, gotFuel = 0, 0
    local foreign = false
    local held = {}
    for _ = 1, MAX_SUCK_ROUNDS do
      local torchSpace = spaceFor(SLOT_TORCH, torchSet)
      local fuelSpace = spaceFor(SLOT_FUEL, fuelSet)
      local needTorches = wantTorches and torchSpace > 0
      local needFuel = wantFuel and fuelSpace > 0
      -- Choose the scratch slot only now: placing the chest may have dug a
      -- block that landed in the slot that was empty before. One slot is
      -- always kept free so mining can continue after the resupply.
      local tmp = firstEmptyLootSlot()
      if (not needTorches and not needFuel) or not tmp or freeLootSlots() < 2 then
        break
      end
      turtle.select(tmp)
      if not act(dir, "suck") then
        break
      end
      local item = detail(tmp)
      if item and torchSet[item.name] then
        if torchSpace > 0 then
          turtle.transferTo(SLOT_TORCH)
          gotTorches = gotTorches + item.count - itemCount(tmp)
        end
      elseif item and fuelSet[item.name] then
        if fuelSpace > 0 then
          turtle.transferTo(SLOT_FUEL)
          gotFuel = gotFuel + item.count - itemCount(tmp)
        end
      elseif item then
        -- Foreign items stay in the loot slots and end up in the resource
        -- chest, which keeps the supply chest clean.
        foreign = true
      end
      if item and itemCount(tmp) > 0 and (torchSet[item.name] or fuelSet[item.name]) then
        -- Supplies that do not fit right now are held back so the chest hands
        -- out the next stack, and are returned below.
        held[#held + 1] = tmp
      end
    end
    for _, slot in ipairs(held) do
      if itemCount(slot) > 0 then
        turtle.select(slot)
        if not act(dir, "drop") then
          event("Supply chest is full, keeping extra supplies in the inventory", "warn")
        end
      end
    end
    turtle.select(FIRST_LOOT)
    pickupChest(SLOT_SUPPLY, dir)
    stats.resupplies = stats.resupplies + 1
    if foreign then
      event("Supply chest contains items other than torches/fuel", "warn")
    end
    event(string.format("Resupply: +%d torches, +%d fuel", gotTorches, gotFuel))
    setState(prevState, prevMsg)
    return gotTorches > 0 or gotFuel > 0
  end

  ---@param steps integer
  ensureFuel = function(steps)
    if turtle.getFuelLevel() == "unlimited" then
      return
    end
    local need = steps + distanceHome() + cfg.fuelReserve
    if fuelLevel() >= need then
      return
    end
    local target = fuelTarget(need)
    local prevState, prevMsg = state, message
    local waiting = false
    while true do
      refuelLocal(target)
      if fuelLevel() >= need then
        break
      end
      resupply(false, true)
      refuelLocal(target)
      if fuelLevel() >= need then
        break
      end
      if not waiting then
        waiting = true
        event("Out of fuel - waiting", "warn")
      end
      setState(
        "no_fuel",
        string.format("Fuel %d/%d - put fuel into slot %d or the supply chest", fuelLevel(), need, SLOT_FUEL)
      )
      report(true)
      sleep(5)
    end
    if waiting then
      event("Fuel restored")
    end
    setState(prevState, prevMsg)
  end

  local function dropJunk()
    for slot = FIRST_LOOT, LAST_SLOT do
      local item = detail(slot)
      if item and junkSet[item.name] then
        turtle.select(slot)
        local before = itemCount(slot)
        if turtle.drop() or turtle.dropUp() or turtle.dropDown() then
          stats.junkDropped = stats.junkDropped + before - itemCount(slot)
        end
      end
    end
    turtle.select(FIRST_LOOT)
  end

  local function compact()
    for i = FIRST_LOOT, LAST_SLOT - 1 do
      local target = detail(i)
      if target and turtle.getItemSpace(i) > 0 then
        for j = i + 1, LAST_SLOT do
          local item = detail(j)
          if item and item.name == target.name and item.nbt == target.nbt then
            turtle.select(j)
            turtle.transferTo(i)
            if turtle.getItemSpace(i) == 0 then
              break
            end
          end
        end
      end
    end
    turtle.select(FIRST_LOOT)
  end

  ---@return boolean
  local function hasCargo()
    for slot = SLOT_TORCH, LAST_SLOT do
      if shouldDump(slot) then
        return true
      end
    end
    return false
  end

  ---@param force boolean Unload everything regardless of free space
  local function manageInventory(force)
    if not force and freeLootSlots() > cfg.minFreeSlots then
      return
    end
    sanitizeSpecialSlots()
    if cfg.refuelFromLoot then
      refuelLocal(fuelTarget(distanceHome() + cfg.fuelReserve))
    end
    if cfg.dropJunk then
      dropJunk()
    end
    compact()
    if force then
      if hasCargo() then
        dumpToChest()
      end
    elseif freeLootSlots() <= cfg.minFreeSlots + 2 then
      dumpToChest()
    end
  end

  checkpoint = function()
    if not homing then
      if control.abort then
        error(ABORT, 0)
      end
      if control.paused then
        local prevState, prevMsg = state, message
        setState("paused", "Paused by the controller")
        event("Paused")
        while control.paused and not control.abort do
          report(false)
          sleep(1)
        end
        setState(prevState, prevMsg)
        if control.abort then
          error(ABORT, 0)
        end
        event("Resumed")
      end
    end
    manageInventory(false)
    report(false)
  end

  ---@param band Band
  local function clearAround(band)
    if band.high > pos.y then
      local ok, reason = dig("up")
      if not ok then
        event("Cannot dig up: " .. tostring(reason), "warn")
      end
    end
    if band.low < pos.y then
      local ok, reason = dig("down")
      if not ok then
        event("Cannot dig down: " .. tostring(reason), "warn")
      end
    end
  end

  ---@param tunnel integer Zero based tunnel index
  ---@param column integer Zero based column inside the tunnel
  ---@return integer
  local function tunnelX(tunnel, column)
    -- "+ 0" turns -0 into 0, which would otherwise show up as "-0"
    return sideSign * (tunnel * (cfg.width + cfg.spacing) + column) + 0
  end

  ---@param tunnel integer
  local function clearTunnel(tunnel)
    stats.tunnel = tunnel + 1
    setState("mining", string.format("Tunnel %d of %d", tunnel + 1, cfg.tunnels))
    local cells = {}
    for column = 0, cfg.width - 1 do
      local x = tunnelX(tunnel, column)
      if column % 2 == 0 then
        for z = 1, cfg.length do
          cells[#cells + 1] = { x, z }
        end
      else
        for z = cfg.length, 1, -1 do
          cells[#cells + 1] = { x, z }
        end
      end
    end
    for index, band in ipairs(bands) do
      local first, last, delta = 1, #cells, 1
      if index % 2 == 0 then
        first, last, delta = #cells, 1, -1
      end
      for i = first, last, delta do
        local cell = cells[i]
        goTo(cell[1], band.center, cell[2], "yxz")
        clearAround(band)
        stats.cellsDone = stats.cellsDone + 1
        checkpoint()
      end
    end
  end

  ---@param z integer
  ---@return boolean
  local function isTorchSpot(z)
    return z >= 2 and z % cfg.torchInterval == 0
  end

  --- Place a torch on the floor of the block the turtle just left.
  --- Expects the turtle to be walking towards the tunnel entrance.
  local function placeTorchBehind()
    local torch = detail(SLOT_TORCH)
    if not torch or not torchSet[torch.name] then
      sanitizeSpecialSlots()
      resupply(true, false)
      torch = detail(SLOT_TORCH)
    end
    if not torch or not torchSet[torch.name] then
      if not warnedNoTorches then
        warnedNoTorches = true
        event("Out of torches - skipping torches", "warn")
      end
      return
    end
    warnedNoTorches = false
    face(0)
    turtle.select(SLOT_TORCH)
    if turtle.place() then
      stats.torchesPlaced = stats.torchesPlaced + 1
    end
    turtle.select(FIRST_LOOT)
    face(2)
  end

  ---@param tunnel integer
  local function torchPass(tunnel)
    local x0 = tunnelX(tunnel, 0)
    setState("mining", string.format("Placing torches in tunnel %d", tunnel + 1))
    goTo(x0, 0, cfg.length, "yxz")
    for z = cfg.length - 1, 1, -1 do
      goTo(x0, 0, z, "z")
      if isTorchSpot(z + 1) then
        placeTorchBehind()
      end
    end
  end

  --- Direct way back: along the tunnel to the entrance corridor, down to the
  --- floor, along the corridor and back onto the start block.
  local function homeRoute()
    if pos.z > 1 then
      goTo(pos.x, pos.y, 1, "z")
    end
    goTo(pos.x, 0, pos.z, "y")
    goTo(0, 0, pos.z, "x")
    goTo(0, 0, 0, "z")
    face(0)
  end

  ---@param msg string|nil
  local function goHome(msg)
    homing = true
    setState("returning", msg or "Returning to the start position")
    report(true)
    local lastErr = nil
    for _, detour in ipairs(HOME_DETOURS) do
      local ok, err = pcall(function()
        if detour[1] ~= 0 or detour[2] ~= 0 then
          goTo(pos.x + detour[1], pos.y + detour[2], pos.z, "yx")
        end
        homeRoute()
      end)
      if ok then
        return
      end
      if type(err) ~= "table" or not err.fatal then
        -- Termination and unexpected errors are not retried
        error(err, 0)
      end
      lastErr = err
      event("Way home blocked, trying a detour", "warn")
    end
    error(lastErr, 0)
  end

  local function preflight()
    for _, slot in ipairs({ SLOT_SUPPLY, SLOT_DUMP }) do
      local item = detail(slot)
      if not item or item.count ~= 1 then
        fail(string.format("Slot %d must contain exactly one ender chest", slot))
      end
      if item.name == "minecraft:ender_chest" then
        fail("Vanilla ender chests do not work with turtles, use EnderStorage ender chests")
      end
    end
    sanitizeSpecialSlots()
    turtle.select(FIRST_LOOT)
    if freeLootSlots() < LOOT_SLOTS then
      event("Slots 5-16 are not empty, they will be unloaded", "warn")
    end
    ensureFuel(1)
    if cfg.useTorches and spaceFor(SLOT_TORCH, torchSet) == 64 then
      resupply(true, false)
    end
  end

  local function mine()
    preflight()
    setState("mining", "")
    report(true)
    goTo(0, 0, 1, "z")
    for tunnel = 0, cfg.tunnels - 1 do
      if tunnel > 0 then
        setState("mining", string.format("Moving to tunnel %d", tunnel + 1))
        goTo(tunnelX(tunnel, 0), 0, 1, "xyz")
      end
      clearTunnel(tunnel)
      if cfg.useTorches then
        torchPass(tunnel)
      else
        goTo(tunnelX(tunnel, 0), 0, 1, "yxz")
      end
    end
    manageInventory(true)
    goHome("Job finished, returning")
  end

  --- Open the first wireless (or ender) modem for telemetry.
  ---@return boolean
  function self.openTelemetry()
    if not peripheral or not rednet then
      return false
    end
    local modem = peripheral.find("modem", function(_, wrapped)
      return wrapped.isWireless ~= nil and wrapped.isWireless()
    end)
    if not modem then
      return false
    end
    local name = peripheral.getName(modem)
    local ok = pcall(function()
      if not rednet.isOpen(name) then
        rednet.open(name)
      end
    end)
    if ok then
      modemName = name
    end
    return ok
  end

  ---@param cmd string
  ---@param sender integer|nil
  ---@return boolean handled
  function self.handleCommand(cmd, sender)
    local from = sender and (" from #" .. tostring(sender)) or ""
    if cmd == "pause" then
      control.paused = true
    elseif cmd == "resume" then
      control.paused = false
    elseif cmd == "home" then
      control.abort = true
      control.paused = false
    elseif cmd == "ping" then
      lastReport = -math.huge
    else
      return false
    end
    event("Command '" .. cmd .. "'" .. from)
    return true
  end

  --- Listen for commands from the monitor. Runs in parallel to run().
  function self.commandLoop()
    while true do
      local sender, msg = rednet.receive(PROTOCOL)
      if
        type(msg) == "table"
        and msg.type == "command"
        and (msg.target == nil or msg.target == os.getComputerID())
        and (cfg.controllerId == nil or sender == cfg.controllerId)
      then
        self.handleCommand(tostring(msg.cmd), sender)
      end
    end
  end

  ---@return boolean success
  ---@return string state
  ---@return string message
  function self.run()
    stats.startedAt = now()
    turtle.select(FIRST_LOOT)
    local ok, err = pcall(mine)
    if ok then
      setState("done", string.format("Finished: %d blocks mined", stats.mined))
      event("Job finished")
    elseif type(err) == "table" and err.abort then
      event("Abort requested, returning home")
      local homeOk, homeErr = pcall(goHome)
      if homeOk then
        setState("aborted", "Stopped by the controller, back at start")
      else
        local text = type(homeErr) == "table" and homeErr.msg or tostring(homeErr)
        setState("error", "Return failed: " .. text)
        event(message, "error")
      end
    elseif err == "Terminated" then
      setState("stopped", "Terminated by the user")
      event(message, "warn")
    else
      local text = type(err) == "table" and err.msg or tostring(err)
      setState("error", text)
      event(text, "error")
      if cfg.returnOnError and not homing then
        report(true)
        local homeOk, homeErr = pcall(goHome)
        if not homeOk then
          local homeText = type(homeErr) == "table" and homeErr.msg or tostring(homeErr)
          event("Return failed: " .. homeText, "error")
        end
        setState("error", text)
      end
    end
    report(true)
    return state == "done", state, message
  end

  ---@return table
  function self.getStatus()
    return buildStatus()
  end

  return self
end

-- Interactive setup ---------------------------------------------------------

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
local function askBool(text, default)
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

---@param base MinerConfig
---@return MinerConfig
local function runWizard(base)
  local cfg = deepCopy(base)
  term.clear()
  term.setCursorPos(1, 1)
  print("Ender Miner " .. VERSION .. " setup")
  cfg.tunnels = askInt("Tunnels", cfg.tunnels, INT_RULES.tunnels[1], INT_RULES.tunnels[2])
  cfg.width = askInt("Width", cfg.width, INT_RULES.width[1], INT_RULES.width[2])
  cfg.height = askInt("Height", cfg.height, INT_RULES.height[1], INT_RULES.height[2])
  cfg.length = askInt("Length", cfg.length, INT_RULES.length[1], INT_RULES.length[2])
  if cfg.tunnels > 1 then
    cfg.spacing = askInt("Blocks between", cfg.spacing, INT_RULES.spacing[1], INT_RULES.spacing[2])
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
  cfg.useTorches = askBool("Place torches", cfg.useTorches)
  if cfg.useTorches then
    cfg.torchInterval =
      askInt("Torch distance", cfg.torchInterval, INT_RULES.torchInterval[1], INT_RULES.torchInterval[2])
  end
  cfg.dropJunk = askBool("Drop cobble etc.", cfg.dropJunk)
  local controller = askInt("Monitor PC id (-1=any)", cfg.controllerId or -1, -1, 65535)
  if controller < 0 then
    cfg.controllerId = nil
  else
    cfg.controllerId = controller
  end
  return cfg
end

---@param cfg MinerConfig
local function printSummary(cfg)
  term.clear()
  term.setCursorPos(1, 1)
  print("Ender Miner " .. VERSION)
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
  print("")
  print("1: supply ender chest (torches)")
  print("2: resource ender chest")
  print("3: torches  4: fuel  5-16: empty")
  print("")
end

---@param argv string[]
local function main(argv)
  if not turtle then
    printError("This program must run on a mining turtle.")
    return
  end
  local cfg, err = loadConfig(CONFIG_FILE)
  if not cfg and fs.exists(CONFIG_FILE) then
    printError("Invalid " .. CONFIG_FILE .. ": " .. tostring(err))
  end
  if argv[1] == "setup" or not cfg then
    cfg = runWizard(cfg or DEFAULT_CONFIG)
    local ok, saveErr = pcall(saveConfig, CONFIG_FILE, cfg)
    if not ok then
      printError(tostring(saveErr))
    end
  end
  while true do
    printSummary(cfg)
    write("Enter=start e=edit q=quit: ")
    local answer = (read() or ""):lower()
    if answer == "q" then
      return
    elseif answer == "e" then
      cfg = runWizard(cfg)
      local ok, saveErr = pcall(saveConfig, CONFIG_FILE, cfg)
      if not ok then
        printError(tostring(saveErr))
      end
    else
      break
    end
  end

  local miner = createMiner(cfg)
  local telemetry = miner.openTelemetry()
  local success, finalState, finalMessage
  local function runJob()
    success, finalState, finalMessage = miner.run()
  end
  if telemetry then
    parallel.waitForAny(runJob, miner.commandLoop)
  else
    print("No ender/wireless modem - telemetry off")
    runJob()
  end
  print("")
  if success then
    print("Done: " .. tostring(finalMessage))
  else
    printError(tostring(finalState) .. ": " .. tostring(finalMessage))
  end
end

local M = {
  VERSION = VERSION,
  PROTOCOL = PROTOCOL,
  DEFAULT_CONFIG = DEFAULT_CONFIG,
  computeBands = computeBands,
  mergeConfig = mergeConfig,
  validateConfig = validateConfig,
  loadConfig = loadConfig,
  saveConfig = saveConfig,
  createMiner = createMiner,
}

local args = { ... }
if args[1] == "--lib" then
  return M
end
main(args)
