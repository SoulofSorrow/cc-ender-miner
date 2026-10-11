-- cc-ender-miner - chunk loading follower turtle
-- Copyright (C) 2026 Julian Schäfer
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- A second turtle with a chunk loader upgrade and an ender modem (no pickaxe
-- needed) that keeps the miner's chunk loaded. The monitor computer relays
-- the miner's position and progress to it. The follower only drives through
-- blocks the miner has already dug out and waits on parking cells the miner
-- never uses again, so the two never block each other for long.
--
-- Start position: directly BEHIND the miner's start block, facing the same
-- direction. Needs miner.lua on the same turtle (installed by "install
-- follower"), which provides the shared job geometry.
--
-- Coordinates are the miner's job coordinates: the miner starts at 0/0/0,
-- the follower at 0/0/-1.

local VERSION = "1.4.0"
local PROTOCOL = "endermine.v1"
local CONFIG_FILE = "follower.cfg"
local STATE_FILE = "follower.pos"
local STARTUP_DIR = "startup"
local STARTUP_FILE = "startup/endermine-follower.lua"
local LIB_FILE = "miner.lua"
local STATE_FORMAT = 1

local TICK = 0.5
local STALE_AFTER = 15
local WAIT_FOR_TURTLE = 3
local BLOCK_RETRY = 20
local MAKE_WAY_SECONDS = 30
local FUEL_RESERVE = 100
local RESUME_COUNTDOWN = 5

local START = { x = 0, y = 0, z = -1, f = 0 }
-- Where the follower waits when the job is finished: in front of the miner
local FINISH = { x = 0, y = 0, z = 1 }

local MINER_DONE = { done = true, aborted = true }
local MINER_HOLD = { lost = true, error = true, stopped = true }

---@class FollowerConfig
---@field hubId integer|nil Computer id of the monitor; nil accepts messages from any computer
---@field minerId integer|nil Miner to follow; nil lets the monitor assign one
---@field followDistance integer Move when the miner is farther away than this (x/z blocks)
---@field reportInterval number Seconds between two status updates

---@type FollowerConfig
local DEFAULT_CONFIG = {
  hubId = nil,
  minerId = nil,
  followDistance = 6,
  reportInterval = 2,
}

local DELTA = { [0] = { 0, 1 }, [1] = { 1, 0 }, [2] = { 0, -1 }, [3] = { -1, 0 } }

---@return number
local function now()
  if os.epoch then
    return os.epoch("utc") / 1000
  end
  return os.clock()
end

---@param x integer
---@param y integer
---@param z integer
---@return string
local function key(x, y, z)
  return string.format("%d,%d,%d", x, y, z)
end

---@param path string
---@param text string
---@return boolean ok
---@return string|nil err
local function writeAtomic(path, text)
  local handle, err = fs.open(path .. ".new", "w")
  if not handle then
    return false, tostring(err)
  end
  handle.write(text)
  handle.close()
  if fs.exists(path) then
    fs.delete(path)
  end
  fs.move(path .. ".new", path)
  return true, nil
end

---@param path string
---@return table|nil
local function readTable(path)
  for _, candidate in ipairs({ path, path .. ".new" }) do
    if fs.exists(candidate) then
      local handle = fs.open(candidate, "r")
      if handle then
        local data = textutils.unserialize(handle.readAll() or "")
        handle.close()
        if type(data) == "table" then
          return data
        end
      end
    end
  end
  return nil
end

---@param path string
local function removeFile(path)
  for _, candidate in ipairs({ path, path .. ".new" }) do
    if fs.exists(candidate) then
      fs.delete(candidate)
    end
  end
end

---@param cfg table
---@return boolean ok
---@return string[] errors
local function validateConfig(cfg)
  local errors = {}
  for _, field in ipairs({ "hubId", "minerId" }) do
    local value = cfg[field]
    if value ~= nil and (type(value) ~= "number" or value < 0 or value ~= math.floor(value)) then
      errors[#errors + 1] = field .. " must be a computer id or nil"
    end
  end
  if type(cfg.followDistance) ~= "number" or cfg.followDistance < 2 or cfg.followDistance > 32 then
    errors[#errors + 1] = "followDistance must be between 2 and 32"
  end
  if type(cfg.reportInterval) ~= "number" or cfg.reportInterval < 0.2 or cfg.reportInterval > 60 then
    errors[#errors + 1] = "reportInterval must be between 0.2 and 60"
  end
  return #errors == 0, errors
end

---@param data table|nil
---@return FollowerConfig
local function mergeConfig(data)
  local cfg = {}
  for k, v in pairs(DEFAULT_CONFIG) do
    cfg[k] = v
  end
  if type(data) == "table" then
    for k in pairs(DEFAULT_CONFIG) do
      if data[k] ~= nil then
        cfg[k] = data[k]
      end
    end
    -- Optional ids may be nil in the defaults
    cfg.hubId = data.hubId
    cfg.minerId = data.minerId
  end
  return cfg
end

--- Load the shared geometry from miner.lua.
---@return table|nil lib
---@return string|nil err
local function loadLib()
  if not fs.exists(LIB_FILE) then
    return nil, LIB_FILE .. " is missing, install it with 'install follower'"
  end
  local chunk, err = loadfile(LIB_FILE)
  if not chunk then
    return nil, "cannot load " .. LIB_FILE .. ": " .. tostring(err)
  end
  local ok, lib = pcall(chunk, "--lib")
  if not ok or type(lib) ~= "table" or type(lib.isParkingCell) ~= "function" then
    return nil, LIB_FILE .. " is too old for the follower, update it"
  end
  return lib, nil
end

--- Find and switch on a chunk loader upgrade.
---@return string "active", "passive" or "none"
local function startChunkLoader()
  if not peripheral then
    return "none"
  end
  for _, side in ipairs({ "left", "right" }) do
    local kind = peripheral.getType(side)
    if type(kind) == "string" and kind:lower():find("chunk") then
      local device = peripheral.wrap(side)
      if device and type(device.setActive) == "function" then
        local ok = pcall(device.setActive, true)
        return ok and "active" or "none"
      end
      -- Upgrades without a switch load chunks on their own
      return "passive"
    end
  end
  return "none"
end

---@param cfg FollowerConfig
---@param lib table Geometry from miner.lua
---@param saved table|nil Saved position journal to continue from
---@return table follower
local function createFollower(cfg, lib, saved)
  local self = {}
  local pos = { x = START.x, y = START.y, z = START.z, f = START.f }
  local state, message = "waiting", "Waiting for the miner"
  local minerId = cfg.minerId
  local info = nil
  local infoAt = -math.huge
  local makeWay = nil
  local blocked = {}
  local lastReport = -math.huge
  local modemName = nil
  local chunkLoader = "none"
  local finished = false
  local restarts = 0

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
    pcall(function()
      if cfg.hubId then
        rednet.send(cfg.hubId, payload, PROTOCOL)
      else
        rednet.broadcast(payload, PROTOCOL)
      end
    end)
  end

  ---@param text string
  ---@param level string|nil
  local function event(text, level)
    transmit({ type = "event", id = os.getComputerID(), level = level or "info", text = text })
  end

  ---@param pending table|nil
  local function saveJournal(pending)
    pcall(
      writeAtomic,
      STATE_FILE,
      textutils.serialize({
        format = STATE_FORMAT,
        x = pos.x,
        y = pos.y,
        z = pos.z,
        f = pos.f,
        minerId = minerId,
        restarts = restarts,
        pending = pending,
      })
    )
  end

  ---@return integer|nil
  local function minerDistance()
    if not info or type(info.pos) ~= "table" then
      return nil
    end
    return math.abs(info.pos.x - pos.x) + math.abs(info.pos.z - pos.z)
  end

  ---@return table
  local function buildStatus()
    local fuel = turtle.getFuelLevel()
    local limit = turtle.getFuelLimit()
    local id = os.getComputerID()
    return {
      type = "status",
      role = "follower",
      v = 1,
      id = id,
      label = os.getComputerLabel() or ("Follower #" .. id),
      version = VERSION,
      state = state,
      message = message,
      pos = { x = pos.x, y = pos.y, z = pos.z, f = pos.f },
      fuel = fuel == "unlimited" and -1 or fuel,
      fuelLimit = limit == "unlimited" and -1 or limit,
      follow = minerId,
      distance = minerDistance(),
      chunkLoader = chunkLoader,
      restarts = restarts,
    }
  end

  ---@param force boolean
  local function report(force)
    local t = now()
    if not force and t - lastReport < cfg.reportInterval then
      return
    end
    lastReport = t
    if term and term.getSize then
      local width = term.getSize()
      local lines = {
        string.format("Ender Follower %s  #%d", VERSION, os.getComputerID()),
        "State: " .. state,
        message,
        "Miner: " .. (minerId and ("#" .. minerId) or "not assigned"),
        string.format("Pos: %d %d %d  Distance: %s", pos.x, pos.y, pos.z, tostring(minerDistance() or "-")),
        "Chunk loader: " .. chunkLoader,
        "Fuel: " .. tostring(turtle.getFuelLevel()),
      }
      term.clear()
      for i, text in ipairs(lines) do
        term.setCursorPos(1, i)
        term.write(text:sub(1, width))
      end
    end
    transmit(buildStatus())
  end

  ---@return boolean
  local function ensureFuel()
    local level = turtle.getFuelLevel()
    if level == "unlimited" or level >= FUEL_RESERVE then
      return true
    end
    for slot = 1, 16 do
      if turtle.getItemCount(slot) > 0 then
        turtle.select(slot)
        -- Burn one item at a time until there is enough
        local burning = true
        while burning and turtle.getFuelLevel() < FUEL_RESERVE * 5 do
          burning = turtle.refuel(1)
        end
      end
    end
    turtle.select(1)
    return turtle.getFuelLevel() >= FUEL_RESERVE
  end

  ---@param right boolean
  ---@return boolean
  local function turn(right)
    local target = right and (pos.f + 1) % 4 or (pos.f + 3) % 4
    saveJournal({ kind = "turn", to = target })
    local ok
    if right then
      ok = turtle.turnRight()
    else
      ok = turtle.turnLeft()
    end
    if ok then
      pos.f = target
    end
    saveJournal(nil)
    return ok
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

  ---@param x integer
  ---@param y integer
  ---@param z integer
  ---@return boolean
  local function isMinerAt(x, y, z)
    local p = info and info.pos
    return type(p) == "table" and p.x == x and p.y == y and p.z == z
  end

  ---@param x integer
  ---@param y integer
  ---@param z integer
  ---@return boolean
  local function isBlocked(x, y, z)
    local until_ = blocked[key(x, y, z)]
    return until_ ~= nil and until_ > now()
  end

  ---@param prog table
  ---@param x integer
  ---@param y integer
  ---@param z integer
  ---@return boolean
  local function passable(prog, x, y, z)
    if isMinerAt(x, y, z) or isBlocked(x, y, z) then
      return false
    end
    if x == START.x and y == START.y and z == START.z then
      return true
    end
    return lib.isOpenCell(info.job, info.bands, prog, x, y, z)
  end

  --- Breadth first search through dug out cells.
  ---@param goal fun(x: integer, y: integer, z: integer): boolean
  ---@return table[]|nil path Cells to visit, without the current one
  local function findPath(goal)
    local prog = info.progress
    local job = info.job
    local span = job.tunnels * (job.width + job.spacing) + 1
    local minX, maxX = -span, span
    local startKey = key(pos.x, pos.y, pos.z)
    local parent = { [startKey] = false }
    local queue = { { pos.x, pos.y, pos.z } }
    local head = 1
    local steps = { { 0, 1, 0 }, { 0, -1, 0 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
    while head <= #queue do
      local cell = queue[head]
      head = head + 1
      if head > 2 and goal(cell[1], cell[2], cell[3]) then
        local path = {}
        local current = key(cell[1], cell[2], cell[3])
        local node = cell
        while current ~= startKey do
          table.insert(path, 1, node)
          node = parent[current]
          current = key(node[1], node[2], node[3])
        end
        return path
      end
      for _, d in ipairs(steps) do
        local x, y, z = cell[1] + d[1], cell[2] + d[2], cell[3] + d[3]
        local k = key(x, y, z)
        if
          parent[k] == nil
          and x >= minX
          and x <= maxX
          and y >= -1
          and y <= job.height
          and z >= -1
          and z <= job.length + 1
          and passable(prog, x, y, z)
        then
          parent[k] = cell
          queue[#queue + 1] = { x, y, z }
        end
      end
    end
    return nil
  end

  --- Move to a neighbouring cell. Never digs.
  ---@param cell table {x, y, z}
  ---@return boolean moved
  local function moveTo(cell)
    if not ensureFuel() then
      setState("no_fuel", "Out of fuel - put fuel into the follower")
      return false
    end
    local dx, dy, dz = cell[1] - pos.x, cell[2] - pos.y, cell[3] - pos.z
    local dirName
    if dy == 1 then
      dirName = "up"
    elseif dy == -1 then
      dirName = "down"
    else
      for f = 0, 3 do
        if DELTA[f][1] == dx and DELTA[f][2] == dz then
          face(f)
        end
      end
      dirName = "fwd"
    end
    local detect = ({ fwd = turtle.detect, up = turtle.detectUp, down = turtle.detectDown })[dirName]
    local inspect = ({ fwd = turtle.inspect, up = turtle.inspectUp, down = turtle.inspectDown })[dirName]
    local move = ({ fwd = turtle.forward, up = turtle.up, down = turtle.down })[dirName]
    local waited = 0
    while detect() do
      local _, data = inspect()
      local name = type(data) == "table" and tostring(data.name) or ""
      if name:find("^computercraft:turtle") and waited < WAIT_FOR_TURTLE then
        -- Most likely the miner passing by
        sleep(1)
        waited = waited + 1
      else
        -- Gravel, a torch, an ender chest or the miner not moving away
        blocked[key(cell[1], cell[2], cell[3])] = now() + BLOCK_RETRY
        return false
      end
    end
    saveJournal({ kind = "move", dir = dirName, fuel = turtle.getFuelLevel() })
    local ok = move()
    if ok then
      pos.x, pos.y, pos.z = cell[1], cell[2], cell[3]
    else
      blocked[key(cell[1], cell[2], cell[3])] = now() + BLOCK_RETRY
    end
    saveJournal(nil)
    return ok
  end

  ---@param path table[]
  ---@return boolean arrived
  local function walk(path)
    for _, cell in ipairs(path) do
      if not moveTo(cell) then
        return false
      end
      report(false)
    end
    return true
  end

  --- Chunk of a job cell, nil without GPS. Chunks are 16x16 columns.
  ---@param x integer
  ---@param z integer
  ---@return string|nil
  local function chunkOf(x, z)
    local frame = info and info.frame
    if not frame then
      return nil
    end
    local ax = frame.x + z * frame.dx + x * -frame.dz
    local az = frame.z + z * frame.dz + x * frame.dx
    return math.floor(ax / 16) .. "," .. math.floor(az / 16)
  end

  ---@return boolean|nil same nil when unknown (no GPS)
  local function inMinerChunk()
    local mine = chunkOf(pos.x, pos.z)
    if mine == nil then
      return nil
    end
    return mine == chunkOf(info.pos.x, info.pos.z)
  end

  ---@param avoid table|nil Cell {x, y, z} that must be left free
  ---@param chunkOnlyWanted boolean Only accept cells in the miner's chunk
  ---@return table[]|nil path
  local function pathToParking(avoid, chunkOnlyWanted)
    local target = info.pos
    local targetChunk = chunkOf(target.x, target.z)
    local best = nil
    local sameChunk = targetChunk ~= nil
    local function closeEnough(x, y, z)
      if sameChunk and chunkOf(x, z) ~= targetChunk then
        return false
      end
      if not lib.isParkingCell(info.job, info.bands, info.progress, x, y, z) then
        return false
      end
      if avoid and math.abs(avoid.x - x) + math.abs(avoid.y - y) + math.abs(avoid.z - z) <= 1 then
        return false
      end
      return math.abs(target.x - x) + math.abs(target.z - z) <= best
    end
    -- Widen the search until a parking cell is found, first inside the
    -- miner's chunk (with GPS), then anywhere
    local passes = chunkOnlyWanted and { true } or { true, false }
    for _, chunkOnly in ipairs(passes) do
      sameChunk = chunkOnly and targetChunk ~= nil
      if chunkOnly == sameChunk then
        -- Inside the miner's chunk only nearby cells count, a far away cell
        -- in the same chunk is worse than a close one next door
        local radii = chunkOnly and { 2, 3, 4, cfg.followDistance, 2 * cfg.followDistance }
          or { 2, 3, 4, cfg.followDistance, 2 * cfg.followDistance, 1000 }
        for _, radius in ipairs(radii) do
          best = radius
          local path = findPath(closeEnough)
          if path then
            return path
          end
        end
      end
    end
    return nil
  end

  --- The miner went silent, most likely because its chunk was unloaded.
  --- Drive next to its last known position so that its chunk loads again.
  local function rescue()
    local target = info.pos
    local distance = minerDistance()
    if distance and distance <= 2 then
      setState("waiting", "Next to the silent miner, waiting for it to wake up")
      return
    end
    local path = findPath(function(x, _, z)
      return math.abs(x - target.x) + math.abs(z - target.z) <= 2
    end)
    if not path then
      setState("waiting", "Cannot get closer to the silent miner")
      return
    end
    setState("moving", "Miner is silent - moving next to it to load its chunk")
    walk(path)
  end

  ---@param msg table
  ---@return boolean
  local function validFollow(msg)
    local job = msg.job
    local prog = msg.progress
    if type(job) ~= "table" or type(prog) ~= "table" or type(msg.pos) ~= "table" then
      return false
    end
    for _, field in ipairs({ "tunnels", "width", "height", "length", "spacing", "torchInterval" }) do
      if type(job[field]) ~= "number" or job[field] < 0 then
        return false
      end
    end
    return type(prog.done) == "number" and type(prog.index) == "number" and type(prog.phase) == "string"
  end

  --- Handle a message relayed by the monitor.
  ---@param sender integer
  ---@param msg any
  ---@return boolean handled
  function self.handleMessage(sender, msg)
    if type(msg) ~= "table" or (cfg.hubId ~= nil and sender ~= cfg.hubId) then
      return false
    end
    if msg.target ~= nil and msg.target ~= os.getComputerID() then
      return false
    end
    if msg.type == "assign" and minerId == nil and type(msg.miner) == "number" then
      minerId = msg.miner
      saveJournal(nil)
      event("Following miner #" .. minerId)
      return true
    elseif msg.type == "follow" and (minerId == nil or msg.miner == minerId) and validFollow(msg) then
      if minerId == nil then
        minerId = msg.miner
        saveJournal(nil)
      end
      info = {
        state = tostring(msg.state),
        pos = msg.pos,
        progress = { done = msg.progress.done, tunnel = msg.progress.index, phase = msg.progress.phase },
        job = {
          tunnels = msg.job.tunnels,
          width = msg.job.width,
          height = msg.job.height,
          length = msg.job.length,
          spacing = msg.job.spacing,
          side = msg.job.side == "left" and "left" or "right",
          useTorches = msg.job.useTorches ~= false,
          torchInterval = math.max(2, msg.job.torchInterval),
        },
      }
      info.bands = lib.computeBands(info.job.height)
      local frame = msg.gpsFrame
      if
        type(frame) == "table"
        and type(frame.x) == "number"
        and type(frame.z) == "number"
        and type(frame.dx) == "number"
        and type(frame.dz) == "number"
        and math.abs(frame.dx) + math.abs(frame.dz) == 1
      then
        info.frame = frame
      end
      infoAt = now()
      return true
    elseif msg.type == "release" and msg.miner == minerId then
      -- The miner runs without a follower: stop following it and wait where
      -- we are. A configured miner id is kept for the next job.
      minerId = cfg.minerId
      info = nil
      makeWay = nil
      saveJournal(nil)
      setState("waiting", "Miner #" .. tostring(msg.miner) .. " does not use a follower")
      event("Released by miner #" .. tostring(msg.miner))
      return true
    elseif msg.type == "make_way" and msg.miner == minerId and type(msg.pos) == "table" then
      local p = msg.pos
      local d = DELTA[tonumber(p.f) or 0] or DELTA[0]
      local want = { x = p.x, y = p.y, z = p.z }
      if msg.dir == "up" then
        want.y = want.y + 1
      elseif msg.dir == "down" then
        want.y = want.y - 1
      else
        want.x, want.z = want.x + d[1], want.z + d[2]
      end
      makeWay = { cell = want, untilTime = now() + MAKE_WAY_SECONDS }
      return true
    elseif msg.type == "ping" or (msg.type == "command" and msg.cmd == "ping") then
      lastReport = -math.huge
      return true
    end
    return false
  end

  --- One decision step: called every TICK seconds.
  function self.tick()
    if finished then
      return
    end
    if not info then
      setState("waiting", "Waiting for the monitor to assign a miner")
      return
    end
    if now() - infoAt > STALE_AFTER then
      if MINER_DONE[info.state] or MINER_HOLD[info.state] then
        setState("waiting", "No news from miner #" .. tostring(minerId))
      else
        rescue()
      end
      return
    end
    if MINER_DONE[info.state] then
      setState("returning", "Miner finished, moving next to it")
      if pos.x == FINISH.x and pos.y == FINISH.y and pos.z == FINISH.z then
        finished = true
        setState("done", "Job finished, waiting in front of the miner")
        return
      end
      local path = findPath(function(x, y, z)
        return x == FINISH.x and y == FINISH.y and z == FINISH.z
      end)
      if path then
        walk(path)
      end
      return
    end
    if MINER_HOLD[info.state] then
      setState("holding", "Miner state '" .. info.state .. "' - holding position")
      return
    end

    local avoid = nil
    if makeWay and makeWay.untilTime > now() then
      avoid = makeWay.cell
    else
      makeWay = nil
    end
    local here = lib.isParkingCell(info.job, info.bands, info.progress, pos.x, pos.y, pos.z)
    local distance = minerDistance() or 0
    local inTheWay = avoid ~= nil
      and math.abs(avoid.x - pos.x) + math.abs(avoid.y - pos.y) + math.abs(avoid.z - pos.z) <= 1
    local atStart = pos.x == START.x and pos.y == START.y and pos.z == START.z
    local settled = not inTheWay and distance <= cfg.followDistance and (here or atStart)
    local path
    if settled and inMinerChunk() == false then
      -- With GPS: move into the miner's chunk early, but only if there is
      -- a parking cell in it, otherwise stay
      path = pathToParking(avoid, true)
      if not path then
        setState("following", string.format("Parked %d blocks from the miner", distance))
        return
      end
    elseif settled then
      setState("following", string.format("Parked %d blocks from the miner", distance))
      return
    else
      path = pathToParking(avoid, false)
    end
    if not path then
      if inTheWay then
        setState("blocked", "In the miner's way but no free parking cell")
      else
        setState("following", "No parking cell near the miner yet")
      end
      return
    end
    setState("moving", string.format("Following the miner (%d steps)", #path))
    if walk(path) then
      makeWay = nil
    end
  end

  --- Restore the position after a reboot.
  ---@return boolean ok
  ---@return string|nil err
  local function recover()
    pos.x, pos.y, pos.z, pos.f = saved.x, saved.y, saved.z, saved.f
    if type(pos.x) ~= "number" or type(pos.f) ~= "number" then
      return false, "position journal is damaged"
    end
    minerId = minerId or saved.minerId
    restarts = (tonumber(saved.restarts) or 0) + 1
    local pending = saved.pending
    if type(pending) == "table" and pending.kind == "move" then
      local fuel = turtle.getFuelLevel()
      if fuel == "unlimited" or type(pending.fuel) ~= "number" then
        return false, "the last move cannot be verified with unlimited fuel"
      end
      if fuel == pending.fuel - 1 then
        if pending.dir == "up" then
          pos.y = pos.y + 1
        elseif pending.dir == "down" then
          pos.y = pos.y - 1
        else
          pos.x, pos.z = pos.x + DELTA[pos.f][1], pos.z + DELTA[pos.f][2]
        end
      elseif fuel ~= pending.fuel then
        return false, "fuel level changed unexpectedly during the last move"
      end
    elseif type(pending) == "table" and pending.kind == "turn" then
      return false, "the follower was turning when it stopped"
    end
    saveJournal(nil)
    return true, nil
  end

  --- Open the first wireless (or ender) modem.
  ---@return boolean
  function self.openModem()
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

  --- Prepare the follower. Returns false when it cannot run.
  ---@return boolean ok
  ---@return string|nil err
  function self.start()
    chunkLoader = startChunkLoader()
    if chunkLoader == "none" then
      event("No chunk loader upgrade found - the follower keeps nothing loaded", "warn")
    end
    if saved then
      local ok, err = recover()
      if not ok then
        setState("lost", "Position unknown after restart: " .. tostring(err))
        pcall(removeFile, STARTUP_FILE)
        report(true)
        return false, message
      end
      event(string.format("Follower resumed at %d/%d/%d", pos.x, pos.y, pos.z))
    else
      saveJournal(nil)
    end
    if not fs.exists(STARTUP_DIR) then
      fs.makeDir(STARTUP_DIR)
    end
    pcall(
      writeAtomic,
      STARTUP_FILE,
      "-- Generated by follower: restarts the chunk loading follower after a reboot.\n"
        .. "-- Deleted automatically when the job ends.\n"
        .. 'shell.run("follower", "resume")\n'
    )
    report(true)
    return true, nil
  end

  --- Remove the job files after the job.
  function self.finish()
    pcall(removeFile, STATE_FILE)
    pcall(removeFile, STARTUP_FILE)
  end

  ---@return boolean
  function self.isFinished()
    return finished
  end

  --- Main loop: decide, move, report.
  function self.workLoop()
    while not finished do
      local ok, err = pcall(self.tick)
      if not ok then
        if err == "Terminated" then
          error(err, 0)
        end
        setState("error", tostring(err))
        event(message, "error")
      end
      report(false)
      sleep(TICK)
    end
    report(true)
    event("Follower finished")
    self.finish()
  end

  --- Receive relayed messages. Runs in parallel to workLoop().
  function self.receiveLoop()
    while true do
      local sender, msg = rednet.receive(PROTOCOL)
      local isPing = type(msg) == "table" and (msg.type == "ping" or msg.cmd == "ping")
      if self.handleMessage(sender, msg) and isPing then
        report(true)
      end
    end
  end

  ---@return table
  function self.getStatus()
    return buildStatus()
  end

  ---@return table
  function self.getPosition()
    return { x = pos.x, y = pos.y, z = pos.z, f = pos.f }
  end

  return self
end

-- Program ---------------------------------------------------------------------

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

---@param base FollowerConfig
---@return FollowerConfig
local function runWizard(base)
  term.clear()
  term.setCursorPos(1, 1)
  print("Ender Follower " .. VERSION .. " setup")
  local cfg = mergeConfig(base)
  local hub = askInt("Monitor PC id (-1=any)", cfg.hubId or -1, -1, 65535)
  cfg.hubId = hub >= 0 and hub or nil
  local miner = askInt("Miner id (-1=assigned by monitor)", cfg.minerId or -1, -1, 65535)
  cfg.minerId = miner >= 0 and miner or nil
  cfg.followDistance = askInt("Follow distance", cfg.followDistance, 2, 32)
  return cfg
end

---@param cfg FollowerConfig
---@return boolean ok
---@return string|nil err
local function saveConfig(cfg)
  return writeAtomic(CONFIG_FILE, textutils.serialize(cfg))
end

---@param seconds integer
---@return boolean proceed
local function countdown(seconds)
  local timer = os.startTimer(1)
  local left = seconds
  print(string.format("Resuming the follower in %d s - press any key to cancel", left))
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

---@param argv string[]
---@param jobActive boolean
---@return boolean restarted
local function runAutoUpdate(argv, jobActive)
  if not shell or not fs.exists("update.lua") then
    return false
  end
  local chunk = loadfile("update.lua")
  if not chunk then
    return false
  end
  local ok, updater = pcall(chunk, "--lib")
  if not ok or type(updater) ~= "table" or type(updater.autoUpdate) ~= "function" then
    return false
  end
  return updater.autoUpdate({
    role = "follower",
    current = VERSION,
    stateFormat = STATE_FORMAT,
    jobActive = jobActive,
    program = shell.getRunningProgram(),
    args = argv,
    shell = shell,
  })
end

---@param rawArgs string[]
local function main(rawArgs)
  if not turtle then
    printError("This program must run on a turtle.")
    return
  end
  local argv, noUpdate = {}, false
  for _, arg in ipairs(rawArgs) do
    if arg == "--no-update" then
      noUpdate = true
    else
      argv[#argv + 1] = arg
    end
  end
  local saved = readTable(STATE_FILE)
  if saved and saved.format ~= STATE_FORMAT then
    printError("Saved follower position is from an incompatible version, starting fresh")
    saved = nil
    removeFile(STATE_FILE)
  end
  if not noUpdate and runAutoUpdate(argv, saved ~= nil) then
    return
  end
  local lib, libErr = loadLib()
  if not lib then
    printError(libErr)
    return
  end

  local cfg = mergeConfig(readTable(CONFIG_FILE))
  local valid = validateConfig(cfg)
  if argv[1] == "setup" or not fs.exists(CONFIG_FILE) or not valid then
    cfg = runWizard(cfg)
    local ok, err = saveConfig(cfg)
    if not ok then
      printError("Cannot save " .. CONFIG_FILE .. ": " .. tostring(err))
    end
  end

  if argv[1] == "resume" then
    if not saved then
      removeFile(STARTUP_FILE)
      print("No interrupted follower job found.")
      return
    end
    if not countdown(RESUME_COUNTDOWN) then
      removeFile(STARTUP_FILE)
      print("Cancelled. Run 'follower' to start again.")
      return
    end
  elseif saved then
    write("Continue the interrupted follower job? (y/n) [y]: ")
    local answer = (read() or ""):lower()
    if answer == "n" or answer == "no" then
      removeFile(STATE_FILE)
      saved = nil
    end
  end
  if not saved then
    print("Place the follower directly behind the miner's start block,")
    print("facing the same direction. Enter=start q=quit")
    if (read() or ""):lower() == "q" then
      return
    end
  end

  local follower = createFollower(cfg, lib, saved)
  if not follower.openModem() then
    printError("No ender/wireless modem - the follower needs one")
    return
  end
  local ok, err = follower.start()
  if not ok then
    printError(tostring(err))
    return
  end
  parallel.waitForAny(follower.workLoop, follower.receiveLoop)
  print("Follower stopped.")
end

local M = {
  VERSION = VERSION,
  PROTOCOL = PROTOCOL,
  DEFAULT_CONFIG = DEFAULT_CONFIG,
  STATE_FILE = STATE_FILE,
  STARTUP_FILE = STARTUP_FILE,
  mergeConfig = mergeConfig,
  validateConfig = validateConfig,
  createFollower = createFollower,
}

local args = { ... }
if args[1] == "--lib" then
  return M
end
main(args)
