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
--
-- Resume after chunk unloads and server restarts:
-- Every movement and turn is written to a journal before and after it
-- happens, the job progress is saved regularly, and a startup file restarts
-- the program with "resume" when the turtle boots again. A movement that may
-- or may not have happened when the turtle was unloaded is resolved by
-- comparing the fuel level. Turns use no fuel, so an interrupted turn is
-- resolved with GPS when it is available; without GPS the turtle stops
-- safely instead of digging in a wrong direction.
--
-- Support modules live in endermine/ next to this file.

local util = require("endermine.util")
local config = require("endermine.config")
local store = require("endermine.store")
local geometry = require("endermine.geometry")
local wizard = require("endermine.wizard")

local VERSION = "3.0.0"
local PROTOCOL = "endermine.v1"
local CONFIG_FILE = "miner.cfg"

local now = util.now
local deepCopy = util.deepCopy
local toSet = util.toSet
local errText = util.errText
local DEFAULT_CONFIG = config.DEFAULT
local mergeConfig = config.merge
local STATE_FILE = store.STATE_FILE
local JOURNAL_FILE = store.JOURNAL_FILE
local STARTUP_FILE = store.STARTUP_FILE
local STATE_FORMAT = store.STATE_FORMAT
local writeAtomic = store.writeAtomic
local removeFile = store.removeFile
local clearJob = store.clearJob
local installStartup = store.installStartup
local DELTA = geometry.DELTA
local computeBands = geometry.computeBands
local toRelative = geometry.toRelative
local facingOf = geometry.facingOf

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
local GPS_TIMEOUT = 2
local RESUME_COUNTDOWN = 5
-- Cells between two progress saves. A reboot in between only repeats the
-- cells since the last save, the position journal is always current.
local PROGRESS_EVERY = 8

-- Blocks that fall when the block below them is removed
local FALLING = {
  ["minecraft:gravel"] = true,
  ["minecraft:sand"] = true,
  ["minecraft:red_sand"] = true,
  ["minecraft:suspicious_gravel"] = true,
  ["minecraft:suspicious_sand"] = true,
}

---@alias Direction "fwd"|"up"|"down"|"back"

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
  back = {
    move = "back",
  },
}

local CHEST_PLACE_ORDER = { "up", "down", "fwd" }
-- Sideways {dx, dy} offsets tried when the direct way home is blocked
local HOME_DETOURS = { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 2, 0 }, { -2, 0 } }
local ABORT = { abort = true }

---@param dir Direction
---@param action string
---@return any ...
local function act(dir, action, ...)
  local name = DIRS[dir][action]
  if not name then
    error(string.format("action '%s' is not available for direction '%s'", action, dir), 2)
  end
  return turtle[name](...)
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

---@return number|nil x
---@return number|nil y
---@return number|nil z
local function locate()
  if not gps or not gps.locate then
    return nil, nil, nil
  end
  local ok, x, y, z = pcall(gps.locate, GPS_TIMEOUT)
  if not ok or x == nil then
    return nil, nil, nil
  end
  return x, y, z
end

-- Miner -----------------------------------------------------------------------

---@param cfg MinerConfig
---@param saved SavedJob|nil Interrupted job to continue
---@return table miner
local function createMiner(cfg, saved)
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
  local warnedPersist = false
  local warnedSecret = false

  local junkSet = toSet(cfg.junkItems)
  local fuelSet = toSet(cfg.fuelItems)
  local torchSet = toSet(cfg.torchItems)
  local sideSign = cfg.side == "left" and -1 or 1
  local bands = computeBands(cfg.height)
  local cellsPerTunnel = #bands * cfg.width * cfg.length

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
    cellsTotal = cfg.tunnels * cellsPerTunnel,
    tunnel = 0,
    startedAt = now(),
    restarts = 0,
  }

  -- Job progress that survives a reboot
  local progress = { phase = "start", tunnel = 0, gps = nil, torchZ = nil }
  -- Position journal, rewritten around every movement and turn
  local journal = { pending = nil, chestOut = nil }
  -- Cells below this global index were mined before the reboot
  local skipCells = 0

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

  --- Write a file and warn once if the disk refuses it (e.g. disk full).
  ---@param path string
  ---@param data table
  local function persist(path, data)
    local okCall, okWrite, writeErr = pcall(writeAtomic, path, textutils.serialize(data))
    if (not okCall or not okWrite) and not warnedPersist then
      warnedPersist = true
      local reason = okCall and writeErr or okWrite
      event("Cannot save job state, resume will not work: " .. tostring(reason), "warn")
    end
  end

  ---@return number|string
  local function rawFuel()
    return turtle.getFuelLevel()
  end

  local function saveJournal()
    persist(JOURNAL_FILE, {
      x = pos.x,
      y = pos.y,
      z = pos.z,
      f = pos.f,
      cells = stats.cellsDone,
      pending = journal.pending,
      chestOut = journal.chestOut,
    })
  end

  local function saveProgress()
    local snapshot = deepCopy(stats)
    snapshot.elapsed = math.max(now() - stats.startedAt, 0)
    snapshot.startedAt = nil
    persist(STATE_FILE, {
      format = STATE_FORMAT,
      version = VERSION,
      cfg = cfg,
      phase = progress.phase,
      tunnel = progress.tunnel,
      torchZ = progress.torchZ,
      gps = progress.gps,
      homing = homing,
      paused = control.paused,
      stats = snapshot,
    })
  end

  ---@param phase string
  ---@param tunnel integer|nil
  local function setPhase(phase, tunnel)
    progress.phase = phase
    if tunnel then
      progress.tunnel = tunnel
    end
    saveProgress()
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
      restarts = stats.restarts,
      gps = progress.gps ~= nil,
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
      string.format("Pos: %d %d %d  GPS: %s", pos.x, pos.y, pos.z, progress.gps and "yes" or "no"),
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
  ---@return boolean
  local function lavaAhead(dir)
    if not cfg.avoidLava or dir == "back" then
      return false
    end
    local has, data = act(dir, "inspect")
    return has and type(data) == "table" and type(data.name) == "string" and data.name:find("lava$") ~= nil
  end

  ---@param dir Direction
  ---@param sign integer 1 to apply a movement, -1 to undo it
  local function applyMove(dir, sign)
    if dir == "fwd" then
      pos.x = pos.x + sign * DELTA[pos.f][1]
      pos.z = pos.z + sign * DELTA[pos.f][2]
    elseif dir == "back" then
      pos.x = pos.x - sign * DELTA[pos.f][1]
      pos.z = pos.z - sign * DELTA[pos.f][2]
    elseif dir == "up" then
      pos.y = pos.y + sign
    else
      pos.y = pos.y - sign
    end
  end

  --- Move one block. "back" never digs and gives up immediately when blocked.
  ---@param dir Direction
  ---@return boolean ok
  ---@return string|nil reason
  local function step(dir)
    ensureFuel(1)
    -- Journal first: if the turtle is unloaded during the move, the fuel
    -- level tells on resume whether the move happened.
    journal.pending = { kind = "move", dir = dir, fuel = rawFuel() }
    saveJournal()
    local ok, reason = false, "movement blocked"
    for _ = 1, MAX_MOVE_ATTEMPTS do
      if lavaAhead(dir) then
        reason = "lava ahead"
        break
      end
      if act(dir, "move") then
        applyMove(dir, 1)
        stats.moved = stats.moved + 1
        ok, reason = true, nil
        break
      end
      if dir == "back" then
        break
      end
      if act(dir, "detect") then
        local dug, digReason = dig(dir)
        if not dug then
          reason = digReason
          break
        end
      else
        -- Probably a mob or an item frame in the way
        act(dir, "attack")
        sleep(0.25)
      end
    end
    journal.pending = nil
    saveJournal()
    return ok, reason
  end

  ---@param dir Direction
  local function mustStep(dir)
    local ok, reason = step(dir)
    if not ok then
      fail("Cannot move " .. dir .. ": " .. tostring(reason))
    end
  end

  ---@param right boolean
  local function turn(right)
    local target = right and (pos.f + 1) % 4 or (pos.f + 3) % 4
    journal.pending = { kind = "turn", from = pos.f, to = target }
    saveJournal()
    local ok
    if right then
      ok = turtle.turnRight()
    else
      ok = turtle.turnLeft()
    end
    if ok then
      pos.f = target
    end
    journal.pending = nil
    saveJournal()
    if not ok then
      fail("Cannot turn " .. (right and "right" or "left"))
    end
  end

  ---@param facing integer
  local function face(facing)
    local diff = (facing - pos.f) % 4
    if diff == 1 then
      turn(true)
    elseif diff == 2 then
      turn(true)
      turn(true)
    elseif diff == 3 then
      turn(false)
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
  ---@param dir Direction
  ---@return boolean
  local function tryPlaceChest(slot, dir)
    turtle.select(slot)
    -- Journal first: a chest left in the world after a reboot is picked up again
    journal.chestOut = { slot = slot, dir = dir }
    saveJournal()
    if act(dir, "place") then
      turtle.select(FIRST_LOOT)
      return true
    end
    journal.chestOut = nil
    saveJournal()
    turtle.select(FIRST_LOOT)
    return false
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
      if not act(dir, "detect") and tryPlaceChest(slot, dir) then
        return dir, nil
      end
    end
    for _, dir in ipairs(CHEST_PLACE_ORDER) do
      turtle.select(FIRST_LOOT)
      if dig(dir) and tryPlaceChest(slot, dir) then
        return dir, nil
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
      for other = 1, LAST_SLOT do
        local item = other ~= slot and detail(other) or nil
        if item and (wanted == nil or (item.name == wanted.name and item.nbt == wanted.nbt)) then
          if wanted ~= nil or item.name:find("ender") then
            turtle.select(other)
            turtle.transferTo(slot)
            break
          end
        end
      end
    end
    turtle.select(FIRST_LOOT)
    if itemCount(slot) == 0 then
      fail("Could not pick up the ender chest from slot " .. slot .. ": " .. tostring(reason))
    end
    journal.chestOut = nil
    saveJournal()
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
      if control.abort and not homing then
        setState(prevState, prevMsg)
        error(ABORT, 0)
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
        saveProgress()
        event("Paused")
        while control.paused and not control.abort do
          report(false)
          sleep(1)
        end
        setState(prevState, prevMsg)
        saveProgress()
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
    local index = tunnel * cellsPerTunnel
    for bandIndex, band in ipairs(bands) do
      local first, last, delta = 1, #cells, 1
      if bandIndex % 2 == 0 then
        first, last, delta = #cells, 1, -1
      end
      for i = first, last, delta do
        index = index + 1
        if index > skipCells then
          local cell = cells[i]
          goTo(cell[1], band.center, cell[2], "yxz")
          clearAround(band)
          stats.cellsDone = index
          if index % PROGRESS_EVERY == 0 then
            saveProgress()
          end
          checkpoint()
        end
      end
    end
  end

  ---@param z integer
  ---@return boolean
  local function isTorchSpot(z)
    return z >= 2 and z % cfg.torchInterval == 0
  end

  --- Place a torch on the floor in front of the turtle (facing +z).
  local function placeTorchAhead()
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
    turtle.select(SLOT_TORCH)
    if turtle.place() then
      stats.torchesPlaced = stats.torchesPlaced + 1
    end
    turtle.select(FIRST_LOOT)
  end

  --- Step one block towards the entrance while still facing +z. Driving
  --- backwards avoids two turns per torch, and turns are the only moves that
  --- cannot be verified by the fuel level after a reboot.
  local function retreat()
    if step("back") then
      return
    end
    -- Something is in the way (a mob or fallen gravel): turn and dig through
    face(2)
    mustStep("fwd")
    face(0)
  end

  ---@param tunnel integer
  local function torchPass(tunnel)
    local x0 = tunnelX(tunnel, 0)
    setState("mining", string.format("Placing torches in tunnel %d", tunnel + 1))
    -- progress.torchZ is the saved position of an interrupted torch pass
    local startZ = progress.torchZ or cfg.length
    local continued = progress.torchZ ~= nil
    goTo(x0, 0, startZ, "yxz")
    face(0)
    progress.torchZ = startZ
    saveProgress()
    if continued and startZ < cfg.length and isTorchSpot(startZ + 1) then
      -- The turtle may have stopped between the step and placing this torch.
      -- Placing fails harmlessly when the torch is already there.
      placeTorchAhead()
    end
    for z = startZ - 1, 1, -1 do
      retreat()
      if isTorchSpot(z + 1) then
        placeTorchAhead()
      end
      progress.torchZ = z
      saveProgress()
      checkpoint()
    end
    progress.torchZ = nil
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
    saveProgress()
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

  ---@param slots integer[]
  local function checkChests(slots)
    for _, slot in ipairs(slots) do
      local item = detail(slot)
      if not item or item.count ~= 1 then
        fail(string.format("Slot %d must contain exactly one ender chest", slot))
      end
      if item.name == "minecraft:ender_chest" then
        fail("Vanilla ender chests do not work with turtles, use EnderStorage ender chests")
      end
    end
  end

  local function preflight()
    checkChests({ SLOT_SUPPLY, SLOT_DUMP })
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

  --- Learn how job coordinates map to GPS coordinates. Needs the position
  --- before and after the first step forward from the start block.
  ---@param sx number|nil
  ---@param sy number|nil
  ---@param sz number|nil
  local function calibrateGps(sx, sy, sz)
    if sx == nil then
      return
    end
    local ax, ay, az = locate()
    if ax == nil then
      return
    end
    local dx, dz = ax - sx, az - sz
    if math.abs(dx) + math.abs(dz) == 1 and ay == sy then
      progress.gps = { x = sx, y = sy, z = sz, dx = dx, dz = dz }
      saveProgress()
      event("GPS available - interrupted turns can be recovered")
    end
  end

  local function mine()
    if progress.phase == "start" then
      preflight()
      setState("mining", "")
      report(true)
      local sx, sy, sz = locate()
      goTo(0, 0, 1, "z")
      calibrateGps(sx, sy, sz)
      setPhase("tunnel", 0)
    end
    if progress.phase == "tunnel" or progress.phase == "torch" then
      for tunnel = progress.tunnel, cfg.tunnels - 1 do
        if progress.phase == "tunnel" then
          local started = skipCells > tunnel * cellsPerTunnel
          if tunnel > 0 and not started then
            setState("mining", string.format("Moving to tunnel %d", tunnel + 1))
            goTo(tunnelX(tunnel, 0), 0, 1, "xyz")
          end
          clearTunnel(tunnel)
          setPhase("torch", tunnel)
        end
        stats.tunnel = tunnel + 1
        if cfg.useTorches then
          torchPass(tunnel)
        else
          goTo(tunnelX(tunnel, 0), 0, 1, "yxz")
        end
        setPhase("tunnel", tunnel + 1)
      end
      setPhase("finish")
    end
    manageInventory(true)
    goHome("Job finished, returning")
  end

  --- Restore position and inventory after a reboot.
  ---@return boolean ok
  ---@return string|nil err
  local function recover()
    local j = saved.journal
    local p = saved.progress
    pos.x, pos.y, pos.z, pos.f = j.x, j.y, j.z, j.f
    if type(pos.x) ~= "number" or type(pos.f) ~= "number" then
      return false, "position journal is damaged"
    end
    progress.phase = p.phase or "start"
    progress.tunnel = p.tunnel or 0
    progress.torchZ = type(p.torchZ) == "number" and p.torchZ or nil
    progress.gps = p.gps
    control.paused = p.paused == true
    homing = p.homing == true
    if type(p.stats) == "table" then
      for key, value in pairs(p.stats) do
        if stats[key] ~= nil then
          stats[key] = value
        end
      end
      stats.startedAt = now() - (tonumber(p.stats.elapsed) or 0)
    end
    stats.restarts = stats.restarts + 1
    -- The journal is written around every move, so its cell count is newer
    -- than the throttled progress file.
    stats.cellsDone = math.max(stats.cellsDone, tonumber(j.cells) or 0)
    skipCells = stats.cellsDone

    local pending = j.pending
    local unsure = nil
    if type(pending) == "table" and pending.kind == "move" then
      local fuel = rawFuel()
      if fuel ~= "unlimited" and type(pending.fuel) == "number" then
        if fuel == pending.fuel - 1 then
          applyMove(pending.dir, 1)
        elseif fuel ~= pending.fuel then
          unsure = "fuel level changed unexpectedly during the last move"
        end
      else
        unsure = "with unlimited fuel the last move cannot be verified"
      end
    elseif type(pending) == "table" and pending.kind == "turn" then
      unsure = "the turtle was turning when it stopped"
    end

    if unsure then
      local frame = progress.gps
      if not frame then
        return false, "Position unknown after restart: " .. unsure .. ". Set up GPS to recover from this"
      end
      local x1, y1, z1 = locate()
      if x1 == nil then
        return false, "Position unknown after restart and GPS is not reachable"
      end
      pos.x, pos.y, pos.z = toRelative(frame, x1, y1, z1)
      if type(pending) == "table" and pending.kind == "turn" then
        -- Measure the facing with one step: forward into open space, else back
        local moved = 0
        if not turtle.detect() and turtle.forward() then
          moved = 1
        elseif turtle.back() then
          moved = -1
        elseif dig("fwd") and turtle.forward() then
          moved = 1
        end
        local x2, y2, z2 = locate()
        if moved == 0 or x2 == nil then
          return false, "Facing unknown after restart, the turtle cannot move to measure it"
        end
        local f = facingOf(frame, (x2 - x1) * moved, (z2 - z1) * moved)
        if f == nil then
          return false, "Facing unknown after restart, GPS gave an unexpected result"
        end
        pos.f = f
        pos.x, pos.y, pos.z = toRelative(frame, x2, y2, z2)
      end
      event("Position recovered with GPS")
    end
    journal.pending = nil

    -- An ender chest that was out in the world when the turtle stopped
    local out = j.chestOut
    if type(out) == "table" and type(out.slot) == "number" and itemCount(out.slot) == 0 then
      local okPickup, pickupErr = pcall(pickupChest, out.slot, out.dir)
      if not okPickup then
        return false, errText(pickupErr)
      end
      event("Picked up the ender chest left behind")
    end
    journal.chestOut = nil
    saveJournal()
    saveProgress()
    return true, nil
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
        if cfg.secret == nil or msg.secret == cfg.secret then
          self.handleCommand(tostring(msg.cmd), sender)
        elseif not warnedSecret then
          warnedSecret = true
          event("Rejected a command with a wrong secret", "warn")
        end
      end
    end
  end

  ---@return boolean success
  ---@return string state
  ---@return string message
  function self.run()
    turtle.select(FIRST_LOOT)
    if saved then
      setState("resuming", "Continuing after a restart")
      report(true)
      local ok, recErr = recover()
      if not ok then
        local text = tostring(recErr)
        setState("lost", text)
        event(text, "error")
        -- A lost turtle must not restart the job on every boot
        pcall(removeFile, STARTUP_FILE)
        report(true)
        return false, state, message
      end
      event(string.format("Resumed after restart at %d/%d/%d", pos.x, pos.y, pos.z))
      local okCheck, checkErr = pcall(checkChests, { SLOT_SUPPLY, SLOT_DUMP })
      if not okCheck then
        local text = errText(checkErr)
        setState("lost", text)
        event(text, "error")
        pcall(removeFile, STARTUP_FILE)
        report(true)
        return false, state, message
      end
    else
      stats.startedAt = now()
      saveJournal()
      saveProgress()
      local okCall, okWrite, startupErr = pcall(installStartup)
      if not okCall or not okWrite then
        local reason = okCall and startupErr or okWrite
        event("Cannot create the startup file, no auto resume: " .. tostring(reason), "warn")
      end
    end
    setState("mining", "")

    local ok, err = pcall(function()
      if homing then
        goHome()
      else
        mine()
      end
    end)
    local keepJob = false
    if ok then
      setState("done", string.format("Finished: %d blocks mined", stats.mined))
      event("Job finished")
    elseif type(err) == "table" and err.abort then
      event("Abort requested, returning home")
      local homeOk, homeErr = pcall(goHome)
      if homeOk then
        setState("aborted", "Stopped by the controller, back at start")
      else
        local text = errText(homeErr)
        setState("error", "Return failed: " .. text)
        event(message, "error")
      end
    elseif err == "Terminated" then
      -- Keep the job so "miner" can offer to resume it, but do not restart
      -- it on the next boot without asking.
      keepJob = true
      setState("stopped", "Terminated by the user, run 'miner' to resume")
      event(message, "warn")
    else
      local text = errText(err)
      setState("error", text)
      event(text, "error")
      if cfg.returnOnError and not homing then
        report(true)
        local homeOk, homeErr = pcall(goHome)
        if not homeOk then
          local homeText = errText(homeErr)
          event("Return failed: " .. homeText, "error")
        end
        setState("error", text)
      end
    end
    if keepJob then
      pcall(removeFile, STARTUP_FILE)
    else
      pcall(clearJob)
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

-- Entry point -----------------------------------------------------------------

---@param miner table
local function runMiner(miner)
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

---@param cfg MinerConfig
local function saveConfigSafe(cfg)
  local ok, saveErr = pcall(config.save, CONFIG_FILE, cfg)
  if not ok then
    printError(tostring(saveErr))
  end
end

---@param argv string[]
local function main(argv)
  if not turtle then
    printError("This program must run on a mining turtle.")
    return
  end

  local saved, savedErr = store.loadSavedJob()
  if savedErr then
    printError("Cannot resume the last job: " .. savedErr)
    clearJob()
  end

  if argv[1] == "resume" then
    if not saved then
      -- Nothing to do, make sure the startup file does not linger
      removeFile(STARTUP_FILE)
      print("No interrupted mining job found.")
      return
    end
    if not wizard.countdown(RESUME_COUNTDOWN) then
      removeFile(STARTUP_FILE)
      print("Cancelled. Run 'miner' to resume or discard the job.")
      return
    end
    pcall(installStartup)
    runMiner(createMiner(saved.cfg, saved))
    return
  end

  if saved then
    print("An interrupted mining job was found.")
    if wizard.askBool("Resume it", true) then
      pcall(installStartup)
      runMiner(createMiner(saved.cfg, saved))
      return
    end
    clearJob()
    print("Job discarded.")
  end

  local cfg, err, unknown = config.load(CONFIG_FILE)
  if not cfg and fs.exists(CONFIG_FILE) then
    printError("Invalid " .. CONFIG_FILE .. ": " .. tostring(err))
  end
  if unknown and #unknown > 0 then
    printError("Ignoring unknown keys in " .. CONFIG_FILE .. ": " .. table.concat(unknown, ", "))
  end
  if argv[1] == "setup" or not cfg then
    cfg = wizard.run(VERSION, cfg or DEFAULT_CONFIG)
    saveConfigSafe(cfg)
  end
  while true do
    wizard.printSummary(VERSION, cfg)
    write("Enter=start e=edit q=quit: ")
    local answer = (read() or ""):lower()
    if answer == "q" then
      return
    elseif answer == "e" then
      cfg = wizard.run(VERSION, cfg)
      saveConfigSafe(cfg)
    else
      break
    end
  end
  runMiner(createMiner(cfg))
end

local M = {
  VERSION = VERSION,
  PROTOCOL = PROTOCOL,
  DEFAULT_CONFIG = DEFAULT_CONFIG,
  STATE_FILE = STATE_FILE,
  JOURNAL_FILE = JOURNAL_FILE,
  STARTUP_FILE = STARTUP_FILE,
  computeBands = computeBands,
  mergeConfig = mergeConfig,
  validateConfig = config.validate,
  loadConfig = config.load,
  saveConfig = config.save,
  loadSavedJob = store.loadSavedJob,
  toRelative = toRelative,
  facingOf = facingOf,
  createMiner = createMiner,
}

local args = { ... }
if args[1] == "--lib" then
  return M
end
main(args)
