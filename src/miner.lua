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
-- happens, the job progress is saved after every mined cell, and a startup
-- file restarts the program with "resume" when the turtle boots again. A
-- movement that may or may not have happened when the turtle was unloaded is
-- resolved by comparing the fuel level. Turns use no fuel, so an interrupted
-- turn is resolved with GPS when it is available; without GPS the turtle stops
-- safely instead of digging in a wrong direction.

local VERSION = "2.2.0"
local PROTOCOL = "endermine.v1"
local CONFIG_FILE = "miner.cfg"
local STATE_FILE = "miner.state"
local JOURNAL_FILE = "miner.pos"
local STARTUP_DIR = "startup"
local STARTUP_FILE = "startup/endermine.lua"
local STATE_FORMAT = 1

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

-- Blocks that fall when the block below them is removed
local FALLING = {
  ["minecraft:gravel"] = true,
  ["minecraft:sand"] = true,
  ["minecraft:red_sand"] = true,
  ["minecraft:suspicious_gravel"] = true,
  ["minecraft:suspicious_sand"] = true,
}

---@alias Direction "fwd"|"up"|"down"|"back"

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
---@field useFollower boolean Work together with a chunk loading follower turtle (optional)
---@field mode "tunnel"|"ores" Dig parallel tunnels or scan for ores on several levels
---@field startY integer|nil Absolute Y of the start block (F3), needed for the ore mode
---@field oreLevels integer[] Absolute Y levels to mine in the ore mode
---@field areaWidth integer Ore mode: width of the area to the chosen side
---@field areaLength integer Ore mode: length of the area in front of the turtle
---@field scanRadius integer Ore mode: geo scanner radius (8 is free)
---@field oreNames string[] Ore mode: only these block ids, empty means every ore
---@field oreGroups string[] Ore mode: only these ore kinds ("diamond", "osmium", ...), empty means every ore
---@field toolSide "left"|"right" Ore mode: side of the pickaxe, swapped with the geo scanner
---@field returnHome boolean Ore mode: drive back to the start block at the end
---@field areaOffsetX integer Ore mode: x of the area corner relative to the start (set by the station)
---@field areaOffsetZ integer Ore mode: z offset of the area relative to the start (set by the station)
---@field dockFuel integer Dock mode: fuel level to fill up to at the station

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
  useFollower = false,
  mode = "tunnel",
  startY = nil,
  oreLevels = { -57, 16 },
  areaWidth = 45,
  areaLength = 45,
  scanRadius = 8,
  oreNames = {},
  oreGroups = {},
  toolSide = "right",
  returnHome = true,
  areaOffsetX = 0,
  areaOffsetZ = 0,
  dockFuel = 5000,
}

local OPTIONAL_KEYS = { controllerId = true, startY = true }

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
  areaWidth = { 4, 256 },
  areaLength = { 4, 256 },
  scanRadius = { 4, 16 },
  areaOffsetX = { -100000, 100000 },
  areaOffsetZ = { -100000, 100000 },
  dockFuel = { 0, 1000000 },
}

local BOOL_KEYS = { "useTorches", "dropJunk", "refuelFromLoot", "returnOnError", "useFollower", "returnHome" }
local LIST_KEYS = { "junkItems", "fuelItems", "torchItems", "oreNames", "oreGroups" }

-- Lowest and highest Y a level may have (bedrock below -60 in 1.21)
local MIN_LEVEL_Y = -60
local MAX_LEVEL_Y = 319

--- Best levels for vanilla ores in Minecraft 1.18+ (unchanged in 1.21).
--- Each level is mined in a band of a few blocks above and below.
local ORE_PRESETS = {
  { key = "diamond", label = "Diamond + redstone", y = -57 },
  { key = "gold", label = "Gold", y = -16 },
  { key = "lapis", label = "Lapis", y = 0 },
  { key = "iron", label = "Iron", y = 16 },
  { key = "copper", label = "Copper", y = 48 },
  { key = "coal", label = "Coal", y = 96 },
}

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
  if cfg.mode ~= "tunnel" and cfg.mode ~= "ores" then
    errors[#errors + 1] = "mode must be 'tunnel' or 'ores'"
  end
  if cfg.toolSide ~= "left" and cfg.toolSide ~= "right" then
    errors[#errors + 1] = "toolSide must be 'left' or 'right'"
  end
  if cfg.mode == "ores" then
    if not isInt(cfg.startY) or cfg.startY < -64 or cfg.startY > 320 then
      errors[#errors + 1] = "startY (Y of the start block, see F3) is needed for the ore mode"
    end
    local levels = cfg.oreLevels
    local valid = type(levels) == "table" and #levels > 0
    if valid then
      for _, y in ipairs(levels) do
        if not isInt(y) or y < MIN_LEVEL_Y or y > MAX_LEVEL_Y then
          valid = false
        end
      end
    end
    if not valid then
      errors[#errors + 1] = string.format("oreLevels must list Y levels between %d and %d", MIN_LEVEL_Y, MAX_LEVEL_Y)
    end
  end
  table.sort(errors)
  return #errors == 0, errors
end

-- Persistence -----------------------------------------------------------------

--- Write a file so that a crash leaves either the old or the new content.
---@param path string
---@param text string
---@return boolean ok
---@return string|nil err
local function writeAtomic(path, text)
  local tmp = path .. ".new"
  local handle, err = fs.open(tmp, "w")
  if not handle then
    return false, tostring(err)
  end
  handle.write(text)
  handle.close()
  if fs.exists(path) then
    fs.delete(path)
  end
  fs.move(tmp, path)
  return true, nil
end

--- Read a serialized table, falling back to an unfinished atomic write.
---@param path string
---@return table|nil
local function readTable(path)
  for _, candidate in ipairs({ path, path .. ".new" }) do
    if fs.exists(candidate) then
      local handle = fs.open(candidate, "r")
      if handle then
        local content = handle.readAll()
        handle.close()
        local data = textutils.unserialize(content or "")
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

--- Remove everything that belongs to an unfinished job.
local function clearJob()
  removeFile(STATE_FILE)
  removeFile(JOURNAL_FILE)
  removeFile(STARTUP_FILE)
end

---@return boolean ok
---@return string|nil err
local function installStartup()
  if not fs.exists(STARTUP_DIR) then
    fs.makeDir(STARTUP_DIR)
  end
  return writeAtomic(
    STARTUP_FILE,
    "-- Generated by miner: continues an interrupted mining job after a reboot\n"
      .. "-- or chunk reload. Deleted automatically when the job ends.\n"
      .. 'shell.run("miner", "resume")\n'
  )
end

---@class SavedJob
---@field format integer
---@field version string
---@field cfg MinerConfig
---@field progress table
---@field journal table

--- Load an interrupted job, nil when there is none or it is unusable.
---@return SavedJob|nil job
---@return string|nil err
local function loadSavedJob()
  local progress = readTable(STATE_FILE)
  if not progress then
    return nil, nil
  end
  local journal = readTable(JOURNAL_FILE)
  if not journal then
    return nil, "position journal is missing"
  end
  if progress.format ~= STATE_FORMAT then
    return nil, "saved job was written by an incompatible version"
  end
  local cfg = mergeConfig(DEFAULT_CONFIG, progress.cfg)
  local ok, errors = validateConfig(cfg)
  if not ok then
    return nil, "saved job has an invalid configuration: " .. table.concat(errors, "; ")
  end
  return { format = progress.format, version = progress.version, cfg = cfg, progress = progress, journal = journal },
    nil
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

-- Geometry --------------------------------------------------------------------

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

-- Ore mode planning ------------------------------------------------------------

---@class OreLevel
---@field y integer Absolute Y the turtle travels on
---@field low integer Lowest absolute Y mined for this level
---@field high integer Highest absolute Y mined for this level

--- Distance between scan points. The geo scanner scans a sphere, so a cube
--- of this size around a scan point is covered completely.
---@param radius integer
---@return integer
local function scanSpacing(radius)
  return math.max(2, math.floor(2 * radius / math.sqrt(3)))
end

--- Sort the levels from top to bottom and give each one a band of Y values.
--- Bands of neighbouring levels never overlap, so no block is visited twice.
---@param levels integer[]
---@param radius integer
---@return OreLevel[]
local function oreLevelBands(levels, radius)
  local half = math.floor(scanSpacing(radius) / 2)
  local sorted, seen = {}, {}
  for _, y in ipairs(levels) do
    if not seen[y] then
      seen[y] = true
      sorted[#sorted + 1] = y
    end
  end
  table.sort(sorted, function(a, b)
    return a > b
  end)
  local result = {}
  for i, y in ipairs(sorted) do
    local low, high = y - half, y + half
    if i > 1 then
      high = math.min(high, math.floor((sorted[i - 1] + y) / 2))
    end
    if i < #sorted then
      low = math.max(low, math.floor((y + sorted[i + 1]) / 2) + 1)
    end
    result[#result + 1] = { y = y, low = math.max(low, -64), high = high }
  end
  return result
end

--- Scan point coordinates along one axis so that the whole range is covered.
---@param first integer
---@param last integer
---@param spacing integer
---@return integer[]
local function scanAxis(first, last, spacing)
  local half = math.floor(spacing / 2)
  local points = {}
  local p = first + half
  while true do
    local clamped = math.min(p, last)
    if #points == 0 or clamped ~= points[#points] then
      points[#points + 1] = clamped
    end
    if clamped + (spacing - half - 1) >= last then
      break
    end
    p = p + spacing
  end
  return points
end

---@class ScanPlan
---@field xs integer[] Scan columns (job x, before applying the side)
---@field zs integer[] Scan rows (job z)
---@field order table[] Serpentine order of {ix, iz} for the first level
---@field spacing integer

---@param job table Configuration with areaWidth, areaLength, scanRadius
---@return ScanPlan
local function scanPlan(job)
  local spacing = scanSpacing(job.scanRadius)
  local xs = scanAxis(0, job.areaWidth - 1, spacing)
  local zs = scanAxis(1, job.areaLength, spacing)
  local order = {}
  for ix = 1, #xs do
    if ix % 2 == 1 then
      for iz = 1, #zs do
        order[#order + 1] = { ix, iz }
      end
    else
      for iz = #zs, 1, -1 do
        order[#order + 1] = { ix, iz }
      end
    end
  end
  return { xs = xs, zs = zs, order = order, spacing = spacing }
end

--- Order of scan points on a level. Every second level runs backwards, so it
--- starts exactly below the point where the previous level ended.
---@param plan ScanPlan
---@param levelIndex integer
---@return table[]
local function levelOrder(plan, levelIndex)
  if levelIndex % 2 == 1 then
    return plan.order
  end
  local reversed = {}
  for i = #plan.order, 1, -1 do
    reversed[#reversed + 1] = plan.order[i]
  end
  return reversed
end

--- Index of the scan point whose cell contains a coordinate.
---@param points integer[]
---@param value integer
---@return integer
local function cellIndexOf(points, value)
  local best, bestDistance = 1, math.huge
  for i, p in ipairs(points) do
    local d = math.abs(p - value)
    if d < bestDistance then
      best, bestDistance = i, d
    end
  end
  return best
end

---@param a table {x, y, z}
---@param b table {x, y, z}
---@return integer
local function manhattan(a, b)
  return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

--- Visit order for the ores of one cell: nearest neighbour, improved with
--- 2-opt, from the turtle position to the next scan point.
---@param start table {x, y, z}
---@param ores table[] {x, y, z}
---@param finish table|nil {x, y, z} where the turtle continues afterwards
---@return table[]
local function planTour(start, ores, finish)
  local left = {}
  for i, ore in ipairs(ores) do
    left[i] = ore
  end
  local route = {}
  local current = start
  while #left > 0 do
    local bestIndex, bestDistance = 1, math.huge
    for i, ore in ipairs(left) do
      local d = manhattan(current, ore)
      if d < bestDistance then
        bestIndex, bestDistance = i, d
      end
    end
    current = table.remove(left, bestIndex)
    route[#route + 1] = current
  end
  -- 2-opt: reverse parts of the route while that makes it shorter
  local function at(i)
    if i == 0 then
      return start
    end
    if i == #route + 1 then
      return finish
    end
    return route[i]
  end
  local improved = true
  local rounds = 0
  while improved and rounds < 50 do
    improved = false
    rounds = rounds + 1
    for i = 1, #route - 1 do
      for j = i + 1, #route do
        local a, b, c, d = at(i - 1), at(i), at(j), at(j + 1)
        local before = manhattan(a, b) + (d and manhattan(c, d) or 0)
        local after = manhattan(a, c) + (d and manhattan(b, d) or 0)
        if after < before then
          local lo, hi = i, j
          while lo < hi do
            route[lo], route[hi] = route[hi], route[lo]
            lo, hi = lo + 1, hi - 1
          end
          improved = true
        end
      end
    end
  end
  return route
end

-- Words that only name the stone an ore sits in, not the ore itself
local ORE_HOST_WORDS = {
  ore = true,
  ores = true,
  deepslate = true,
  stone = true,
  nether = true,
  netherrack = true,
  ["end"] = true,
  endstone = true,
  blackstone = true,
  basalt = true,
  overworld = true,
}

--- Kind of an ore without its host stone and mod, so that all variants of an
--- ore share one key: "minecraft:deepslate_diamond_ore" -> "diamond",
--- "mekanism:osmium_ore" -> "osmium".
---@param name string Block id
---@return string
local function oreKey(name)
  local path = tostring(name):gsub("^[^:]*:", ""):lower()
  local words = {}
  for word in path:gmatch("[^_]+") do
    if not ORE_HOST_WORDS[word] then
      words[#words + 1] = word
    end
  end
  if #words == 0 then
    return path
  end
  return table.concat(words, "_")
end

--- Whether a scanned block is an ore at all (tag or name).
---@param block table {name, tags}
---@return boolean
local function isOreBlock(block)
  local name = type(block.name) == "string" and block.name or ""
  local tags = block.tags
  if type(tags) == "table" then
    for k, v in pairs(tags) do
      local tag = type(k) == "string" and k or v
      if tag == "c:ores" or tag == "forge:ores" or tag == "minecraft:ores" then
        return true
      end
    end
  end
  return name:find("_ore$") ~= nil or name == "minecraft:ancient_debris"
end

--- Whether a scanned block is an ore we want.
---@param block table {name, tags}
---@param wanted table<string, boolean>|nil Only these names, nil for every ore
---@param groups table<string, boolean>|nil Only these ore kinds (see oreKey), nil for every kind
---@return boolean
local function isWantedOre(block, wanted, groups)
  local name = type(block.name) == "string" and block.name or ""
  if wanted then
    return wanted[name] == true
  end
  if not isOreBlock(block) then
    return false
  end
  if groups then
    return groups[oreKey(name)] == true
  end
  return true
end

-- Job geometry, shared with the follower turtle ----------------------------------

---@class JobShape
---@field tunnels integer
---@field width integer
---@field height integer
---@field length integer
---@field spacing integer
---@field side "left"|"right"
---@field useTorches boolean
---@field torchInterval integer

---@class JobProgress
---@field done integer Cells finished so far (index of the last finished cell)
---@field tunnel integer Zero based tunnel the miner works on
---@field phase string "start", "tunnel", "torch" or "finish"

---@param job JobShape
---@param tunnel integer Zero based tunnel index
---@param column integer Zero based column inside the tunnel
---@return integer
local function columnX(job, tunnel, column)
  local sign = job.side == "left" and -1 or 1
  -- "+ 0" turns -0 into 0, which would otherwise show up as "-0"
  return sign * (tunnel * (job.width + job.spacing) + column) + 0
end

---@param job JobShape
---@param z integer
---@return boolean
local function torchSpot(job, z)
  return z >= 2 and z % job.torchInterval == 0
end

--- Position of a cell in the mining order, counted over the whole job.
---@param job JobShape
---@param bandCount integer
---@param tunnel integer
---@param column integer
---@param z integer
---@param bandIndex integer One based band index
---@return integer
local function cellIndex(job, bandCount, tunnel, column, z, bandIndex)
  local perBand = job.width * job.length
  local listIndex = column * job.length + (column % 2 == 0 and z or (job.length - z + 1))
  local within = bandIndex % 2 == 1 and listIndex or (perBand - listIndex + 1)
  return (tunnel * bandCount + bandIndex - 1) * perBand + within
end

--- Column and z of the last cell of a band, where the miner changes bands.
---@param job JobShape
---@param bandIndex integer
---@return integer column
---@return integer z
local function lastCellOfBand(job, bandIndex)
  if bandIndex % 2 == 1 then
    local column = job.width - 1
    return column, column % 2 == 0 and job.length or 1
  end
  return 0, 1
end

--- Tunnel and column of an x coordinate, nil between or outside the tunnels.
---@param job JobShape
---@param x integer
---@return integer|nil tunnel
---@return integer|nil column
local function locateColumn(job, x)
  local lx = x * (job.side == "left" and -1 or 1)
  if lx < 0 then
    return nil, nil
  end
  local stride = job.width + job.spacing
  local tunnel = math.floor(lx / stride)
  local column = lx - tunnel * stride
  if tunnel >= job.tunnels or column >= job.width then
    return nil, nil
  end
  return tunnel, column
end

---@param bands Band[]
---@param y integer
---@return integer|nil
local function bandOf(bands, y)
  for i, band in ipairs(bands) do
    if y >= band.low and y <= band.high then
      return i
    end
  end
  return nil
end

--- Whether the miner has already dug out a cell. Torch spots count as closed.
---@param job JobShape
---@param bands Band[]
---@param prog JobProgress
---@param x integer
---@param y integer
---@param z integer
---@return boolean
local function isOpenCell(job, bands, prog, x, y, z)
  if x == 0 and y == 0 and (z == 0 or z == -1) then
    -- Start block of the miner and the block behind it
    return true
  end
  local tunnel, column = locateColumn(job, x)
  if job.useTorches and y == 0 and column == 0 and torchSpot(job, z) then
    return false
  end
  if y == 0 and z == 1 and prog.done > 0 then
    -- Entrance corridor up to the tunnel the miner has reached
    local cellsPerTunnel = #bands * job.width * job.length
    local reached = math.floor((prog.done - 1) / cellsPerTunnel)
    local lx = x * (job.side == "left" and -1 or 1)
    if lx >= 0 and lx <= reached * (job.width + job.spacing) then
      return true
    end
  end
  if tunnel == nil or z < 1 or z > job.length or y < 0 or y >= job.height then
    return false
  end
  return cellIndex(job, #bands, tunnel, column, z, bandOf(bands, y)) <= prog.done
end

--- Cells where a second turtle can wait without ever being in the miner's
--- way: anywhere in a finished tunnel, and in the current tunnel only the top
--- row of a full three row band, which the miner never drives through, except
--- where it changes bands.
---@param job JobShape
---@param bands Band[]
---@param prog JobProgress
---@param x integer
---@param y integer
---@param z integer
---@return boolean
local function isParkingCell(job, bands, prog, x, y, z)
  if z < 2 or not isOpenCell(job, bands, prog, x, y, z) then
    return false
  end
  local tunnel, column = locateColumn(job, x)
  if tunnel == nil then
    return false
  end
  if prog.phase == "finish" or tunnel < prog.tunnel then
    return true
  end
  if tunnel ~= prog.tunnel then
    return false
  end
  local band = bands[bandOf(bands, y)]
  if band.high ~= band.center + 1 or y ~= band.high then
    return false
  end
  for bandIndex = 1, #bands do
    local lastColumn, lastZ = lastCellOfBand(job, bandIndex)
    if column == lastColumn and z == lastZ then
      return false
    end
  end
  return true
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
local function toRelative(frame, ax, ay, az)
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
local function facingOf(frame, adx, adz)
  local rz = adx * frame.dx + adz * frame.dz
  local rx = adx * -frame.dz + adz * frame.dx
  for f = 0, 3 do
    if DELTA[f][1] == rx and DELTA[f][2] == rz then
      return f
    end
  end
  return nil
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

---@class MinerOptions
---@field dock boolean|nil Runs for the station: the dock program owns the startup file

---@param cfg MinerConfig
---@param saved SavedJob|nil Interrupted job to continue
---@param options MinerOptions|nil
---@return table miner
local function createMiner(cfg, saved, options)
  options = options or {}
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

  local junkSet = toSet(cfg.junkItems)
  local fuelSet = toSet(cfg.fuelItems)
  local torchSet = toSet(cfg.torchItems)
  local bands = computeBands(cfg.height)
  local cellsPerTunnel = #bands * cfg.width * cfg.length

  -- Ore mode setup
  local oreMode = cfg.mode == "ores"
  if oreMode then
    -- The follower only understands the tunnel layout
    cfg.useFollower = false
  end
  local plan = oreMode and scanPlan(cfg) or nil
  local levels = oreMode and oreLevelBands(cfg.oreLevels, cfg.scanRadius) or {}
  local wantedOres = (oreMode and #cfg.oreNames > 0) and toSet(cfg.oreNames) or nil
  local wantedGroups = (oreMode and #cfg.oreGroups > 0) and toSet(cfg.oreGroups) or nil
  local oreSign = cfg.side == "left" and -1 or 1
  -- Cells dug or driven through during this run, so ores are not visited twice
  local cleared = {}

  local stats = {
    mined = 0,
    moved = 0,
    torchesPlaced = 0,
    dumps = 0,
    itemsDumped = 0,
    resupplies = 0,
    junkDropped = 0,
    ores = {},
    -- Every kind of ore the geo scanner saw, also the ones not mined
    seen = {},
    cellsDone = 0,
    cellsTotal = oreMode and (#plan.order * #levels) or (cfg.tunnels * cellsPerTunnel),
    tunnel = 0,
    startedAt = now(),
    restarts = 0,
  }

  -- Job progress that survives a reboot
  local progress = {
    phase = "start",
    tunnel = 0,
    gps = nil,
    torchZ = nil,
    -- Ore mode: level and scan point in progress, ores left in the current cell
    ore = { level = 1, point = 1, ores = nil },
    -- Ore mode: world direction of facing 0, measured with the geo scanner
    scanFrame = nil,
    -- Ore mode: the geo scanner is equipped instead of the pickaxe
    scanning = false,
  }
  -- Position journal, rewritten around every movement and turn
  local journal = { pending = nil, chestOut = nil }
  -- Cells below this global index were mined before the reboot
  local skipCells = 0
  -- Chunk of the turtle (needs GPS), reported at once when it changes
  local lastChunk = nil

  -- Forward declarations for mutually dependent helpers
  local report, checkpoint, ensureFuel, resupply, dumpToChest, goHome, checkChests

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
      ore = progress.ore,
      scanFrame = progress.scanFrame,
      scanning = progress.scanning,
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

  ---@return string[]
  local function seenOres()
    local list = {}
    for name in pairs(stats.seen) do
      list[#list + 1] = name
    end
    table.sort(list)
    return list
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
      role = "miner",
      progress = {
        done = stats.cellsDone,
        total = stats.cellsTotal,
        tunnel = stats.tunnel,
        tunnels = cfg.tunnels,
        -- Machine readable progress for the follower turtle
        index = progress.tunnel,
        phase = progress.phase,
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
      -- Lets the follower work out chunk borders
      gpsFrame = progress.gps,
      -- The monitor only pairs a follower with miners that want one
      followerWanted = cfg.useFollower,
      uptime = elapsed,
      eta = eta,
      ores = topOres(),
      seenOres = seenOres(),
      job = {
        tunnels = cfg.tunnels,
        width = cfg.width,
        height = cfg.height,
        length = cfg.length,
        spacing = cfg.spacing,
        side = cfg.side,
        useTorches = cfg.useTorches,
        torchInterval = cfg.torchInterval,
        mode = cfg.mode,
        oreLevels = oreMode and cfg.oreLevels or nil,
        areaWidth = oreMode and cfg.areaWidth or nil,
        areaLength = oreMode and cfg.areaLength or nil,
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
        -- Never mine other turtles. Ask the follower (via the monitor) to
        -- make way, then wait for it to move.
        if cfg.useFollower and (attempts == 1 or attempts % 10 == 0) then
          transmit({
            type = "blocked",
            id = os.getComputerID(),
            pos = { x = pos.x, y = pos.y, z = pos.z, f = pos.f },
            dir = dir,
          })
        end
        sleep(1)
      else
        local ok, reason = act(dir, "dig")
        if ok then
          if hasBlock and type(data) == "table" then
            recordBlock(data)
          end
          local cx, cy, cz = pos.x, pos.y, pos.z
          if dir == "up" then
            cy = cy + 1
          elseif dir == "down" then
            cy = cy - 1
          else
            cx, cz = cx + DELTA[pos.f][1], cz + DELTA[pos.f][2]
          end
          cleared[string.format("%d,%d,%d", cx, cy, cz)] = true
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
      if act(dir, "move") then
        applyMove(dir, 1)
        stats.moved = stats.moved + 1
        ok, reason = true, nil
        local frame = progress.gps
        if frame and cfg.useFollower then
          -- Tell the follower right away when a chunk border was crossed
          local ax = frame.x + pos.z * frame.dx + pos.x * -frame.dz
          local az = frame.z + pos.z * frame.dz + pos.x * frame.dx
          local chunk = math.floor(ax / 16) .. "," .. math.floor(az / 16)
          if lastChunk ~= nil and chunk ~= lastChunk then
            lastReport = -math.huge
          end
          lastChunk = chunk
        end
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
    -- In the ore mode slot 3 holds the geo scanner (or the pickaxe while scanning)
    local torch = not oreMode and detail(SLOT_TORCH) or nil
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
      if oreMode then
        return false
      end
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
    return columnX(cfg, tunnel, column)
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
          saveProgress()
          checkpoint()
        end
      end
    end
  end

  ---@param z integer
  ---@return boolean
  local function isTorchSpot(z)
    return torchSpot(cfg, z)
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

  -- Ore mode -------------------------------------------------------------------

  ---@return boolean
  local function scannerEquipped()
    if not peripheral or not peripheral.getType then
      return false
    end
    local kind = peripheral.getType(cfg.toolSide)
    return type(kind) == "string" and kind:lower():find("geo") ~= nil
  end

  --- Swap the item in slot 3 with the upgrade on the tool side.
  local function swapTool()
    turtle.select(SLOT_TORCH)
    local equip = cfg.toolSide == "left" and turtle.equipLeft or turtle.equipRight
    local ok, err = equip()
    turtle.select(FIRST_LOOT)
    if not ok then
      fail("Cannot swap pickaxe and geo scanner: " .. tostring(err))
    end
  end

  local function equipScanner()
    if scannerEquipped() then
      return
    end
    progress.scanning = true
    saveProgress()
    swapTool()
    if not scannerEquipped() then
      -- Put the pickaxe back before giving up
      swapTool()
      progress.scanning = false
      saveProgress()
      fail("Slot 3 must hold a geo scanner (Advanced Peripherals)")
    end
  end

  local function equipPickaxe()
    if scannerEquipped() then
      swapTool()
    end
    if progress.scanning then
      progress.scanning = false
      saveProgress()
    end
  end

  --- Scan with the geo scanner. Offsets are in world axes, relative to the turtle.
  ---@return table[]
  local function rawScan()
    equipScanner()
    local scanner = peripheral.wrap(cfg.toolSide)
    if not scanner or type(scanner.scan) ~= "function" then
      equipPickaxe()
      fail("No geo scanner found on the " .. cfg.toolSide .. " side")
    end
    local result, err = nil, nil
    for _ = 1, 30 do
      local ok, blocks, scanErr = pcall(scanner.scan, cfg.scanRadius)
      if ok and type(blocks) == "table" then
        result = blocks
        break
      end
      err = ok and scanErr or blocks
      if not tostring(err):lower():find("cooldown") then
        break
      end
      -- The scanner needs a pause between two scans
      sleep(1)
    end
    equipPickaxe()
    if not result then
      fail("Geo scan failed: " .. tostring(err))
    end
    local limit = cfg.scanRadius + 1
    for _, block in ipairs(result) do
      if
        type(block.x) ~= "number"
        or math.abs(block.x) > limit
        or math.abs(block.y) > limit
        or math.abs(block.z) > limit
      then
        fail("Geo scanner returned coordinates outside its radius - unsupported Advanced Peripherals version")
      end
    end
    return result
  end

  --- World step between two scans taken one block apart, nil if unclear.
  ---@param first table[]
  ---@param second table[]
  ---@return integer|nil dx
  ---@return integer|nil dz
  local function measureShift(first, second)
    local index = {}
    for _, block in ipairs(first) do
      index[string.format("%d,%d,%d", block.x, block.y, block.z)] = block.name
    end
    local r2 = cfg.scanRadius * cfg.scanRadius
    local results = {}
    for _, shift in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
      local compared, mismatches = 0, 0
      for _, block in ipairs(second) do
        local x, y, z = block.x + shift[1], block.y, block.z + shift[2]
        -- Only positions that the first scan covered as well
        if x * x + y * y + z * z <= r2 then
          compared = compared + 1
          if index[string.format("%d,%d,%d", x, y, z)] ~= block.name then
            mismatches = mismatches + 1
          end
        end
      end
      results[#results + 1] = { shift = shift, compared = compared, mismatches = mismatches }
    end
    table.sort(results, function(a, b)
      return a.mismatches < b.mismatches
    end)
    local best, runnerUp = results[1], results[2]
    if best.compared < 20 then
      return nil, nil
    end
    if best.mismatches > 3 + best.compared * 0.02 or runnerUp.mismatches < math.max(5, 3 * best.mismatches) then
      return nil, nil
    end
    return best.shift[1], best.shift[2]
  end

  --- Learn the world direction of facing 0 from two scans one block apart.
  local function calibrateScanner()
    setState("mining", "Calibrating the geo scanner")
    local first = rawScan()
    mustStep("fwd")
    local second = rawScan()
    local dx, dz = measureShift(first, second)
    if not dx then
      fail("Cannot work out the direction with the geo scanner, too few different blocks around")
    end
    progress.scanFrame = { dx = dx, dz = dz }
    saveProgress()
    event("Geo scanner calibrated")
  end

  ---@param x integer Area column (0 based, before applying the side)
  ---@param y integer
  ---@param z integer
  ---@return table
  local function areaCell(x, y, z)
    return { x = cfg.areaOffsetX + x * oreSign + 0, y = y, z = cfg.areaOffsetZ + z }
  end

  --- Scan at a scan point and keep the wanted ores of its cell.
  ---@param level OreLevel
  ---@param point table {ix, iz}
  ---@return table[]
  local function scanCell(level, point)
    local blocks = rawScan()
    local frame = progress.scanFrame
    local list = {}
    for _, block in ipairs(blocks) do
      if type(block.name) == "string" and not stats.seen[block.name] and isOreBlock(block) then
        stats.seen[block.name] = true
      end
      if isWantedOre(block, wantedOres, wantedGroups) then
        local rx = block.x * -frame.dz + block.z * frame.dx
        local rz = block.x * frame.dx + block.z * frame.dz
        local ox, oy, oz = pos.x + rx, pos.y + block.y, pos.z + rz
        -- Coordinates inside the area (0 based x, 1 based z)
        local ax = (ox - cfg.areaOffsetX) * oreSign
        local az = oz - cfg.areaOffsetZ
        local absY = cfg.startY + oy
        if
          ax >= 0
          and ax <= cfg.areaWidth - 1
          and az >= 1
          and az <= cfg.areaLength
          and absY >= level.low
          and absY <= level.high
          and cellIndexOf(plan.xs, ax) == point[1]
          and cellIndexOf(plan.zs, az) == point[2]
          and not cleared[string.format("%d,%d,%d", ox, oy, oz)]
        then
          list[#list + 1] = { x = ox, y = oy, z = oz, name = block.name }
        end
      end
    end
    return list
  end

  --- goTo that reports failure instead of raising, trying several axis orders.
  ---@param x integer
  ---@param y integer
  ---@param z integer
  ---@param orders string[]
  ---@return boolean ok
  ---@return string|nil err
  local function softGoTo(x, y, z, orders)
    local lastErr = nil
    for _, order in ipairs(orders) do
      local ok, err = pcall(goTo, x, y, z, order)
      if ok then
        return true, nil
      end
      if type(err) ~= "table" or not err.fatal then
        -- Abort, termination and real errors are not retried
        error(err, 0)
      end
      lastErr = err.msg
    end
    return false, lastErr
  end

  -- Neighbours of an ore: offset of the turtle and the direction to dig in
  local APPROACH = {
    { 0, 1, 0, "down" },
    { 0, -1, 0, "up" },
    { 1, 0, 0, "fwd", 3 },
    { -1, 0, 0, "fwd", 1 },
    { 0, 0, 1, "fwd", 2 },
    { 0, 0, -1, "fwd", 0 },
  }

  --- Dig one ore from the nearest neighbouring cell.
  ---@param ore table {x, y, z, name}
  local function visitOre(ore)
    if cleared[string.format("%d,%d,%d", ore.x, ore.y, ore.z)] then
      return
    end
    local candidates = {}
    for _, a in ipairs(APPROACH) do
      local cell = { x = ore.x + a[1], y = ore.y + a[2], z = ore.z + a[3] }
      candidates[#candidates + 1] = { cell = cell, dir = a[4], facing = a[5], cost = manhattan(pos, cell) }
    end
    table.sort(candidates, function(a, b)
      return a.cost < b.cost
    end)
    for _, option in ipairs(candidates) do
      local c = option.cell
      if softGoTo(c.x, c.y, c.z, { "xzy", "yxz", "zxy" }) then
        if option.facing then
          face(option.facing)
        end
        local present, data = act(option.dir, "inspect")
        if present and type(data) == "table" and data.name == ore.name then
          dig(option.dir)
        end
        cleared[string.format("%d,%d,%d", ore.x, ore.y, ore.z)] = true
        return
      end
    end
    event("Ore at " .. ore.x .. "/" .. ore.y .. "/" .. ore.z .. " is out of reach, skipped", "warn")
  end

  --- Position of a scan point on a level, in job coordinates.
  ---@param point table {ix, iz}
  ---@param level OreLevel
  ---@return table
  local function pointCell(point, level)
    return areaCell(plan.xs[point[1]], level.y - cfg.startY, plan.zs[point[2]])
  end

  local function mineOres()
    local o = progress.ore
    if progress.phase == "start" then
      checkChests({ SLOT_SUPPLY, SLOT_DUMP })
      equipPickaxe()
      local scanner = detail(SLOT_TORCH)
      if not scanner or not tostring(scanner.name):find("geo") then
        fail("Slot 3 must hold a geo scanner (Advanced Peripherals)")
      end
      sanitizeSpecialSlots()
      ensureFuel(1)
      report(true)
      if not progress.scanFrame then
        calibrateScanner()
      end
      o.level, o.point, o.ores = 1, 1, nil
      setPhase("ores")
    end
    while progress.phase == "ores" and o.level <= #levels do
      local level = levels[o.level]
      local order = levelOrder(plan, o.level)
      stats.tunnel = o.level
      while o.point <= #order do
        local point = order[o.point]
        setState("mining", string.format("Level %d/%d (Y %d), scan %d/%d", o.level, #levels, level.y, o.point, #order))
        if o.ores == nil then
          local target = pointCell(point, level)
          local reached, err = softGoTo(target.x, target.y, target.z, { "yxz", "xzy", "zxy" })
          if reached then
            o.ores = scanCell(level, point)
            if #o.ores > 0 then
              event(string.format("Found %d ores at scan %d", #o.ores, o.point))
            end
          else
            event("Scan point unreachable, skipped: " .. tostring(err), "warn")
            o.ores = {}
          end
          saveProgress()
        end
        -- Where the turtle continues afterwards: the next scan point, or the
        -- same column on the next level
        local finish = nil
        if o.point < #order then
          finish = pointCell(order[o.point + 1], level)
        elseif o.level < #levels then
          finish = pointCell(point, levels[o.level + 1])
        end
        for _, ore in ipairs(planTour(pos, o.ores, finish)) do
          visitOre(ore)
          for i, left in ipairs(o.ores) do
            if left == ore then
              table.remove(o.ores, i)
              break
            end
          end
          saveProgress()
          checkpoint()
        end
        o.point = o.point + 1
        o.ores = nil
        stats.cellsDone = stats.cellsDone + 1
        saveProgress()
        checkpoint()
      end
      o.level = o.level + 1
      o.point = 1
      saveProgress()
    end
    setPhase("finish")
    manageInventory(true)
    if cfg.returnHome then
      goHome("Job finished, returning")
    else
      setState("done", "Job finished, waiting at the last scan point")
    end
  end

  --- Way back in the ore mode: up or down to the top level, along it to the
  --- start column and up the first shaft.
  local function oreHomeRoute()
    local topY = (levels[1] and levels[1].y or cfg.startY) - cfg.startY
    goTo(pos.x, topY, pos.z, "y")
    goTo(0, topY, 1, "xz")
    goTo(0, 0, 1, "y")
    goTo(0, 0, 0, "z")
    face(0)
  end

  --- Direct way back: along the tunnel to the entrance corridor, down to the
  --- floor, along the corridor and back onto the start block.
  local function homeRoute()
    if oreMode then
      equipPickaxe()
      oreHomeRoute()
      return
    end
    if pos.z > 1 then
      goTo(pos.x, pos.y, 1, "z")
    end
    goTo(pos.x, 0, pos.z, "y")
    goTo(0, 0, pos.z, "x")
    goTo(0, 0, 0, "z")
    face(0)
  end

  ---@param msg string|nil
  goHome = function(msg)
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
  checkChests = function(slots)
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
    if oreMode then
      mineOres()
      return
    end
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
    if type(p.ore) == "table" then
      progress.ore = {
        level = tonumber(p.ore.level) or 1,
        point = tonumber(p.ore.point) or 1,
        ores = type(p.ore.ores) == "table" and p.ore.ores or nil,
      }
    end
    progress.scanFrame = type(p.scanFrame) == "table" and p.scanFrame or nil
    progress.scanning = p.scanning == true
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

    -- Rebooted while scanning: put the pickaxe back first, everything below
    -- may need to dig
    if oreMode then
      local okTool, toolErr = pcall(equipPickaxe)
      if not okTool then
        return false, type(toolErr) == "table" and toolErr.msg or tostring(toolErr)
      end
    end

    local isTurn = type(pending) == "table" and pending.kind == "turn"
    if unsure and isTurn and not progress.gps and oreMode and progress.scanFrame then
      -- No GPS needed: two geo scans one block apart show which way the
      -- turtle faces
      local okProbe, probeResult = pcall(function()
        local first = rawScan()
        local moved = 0
        if not turtle.detect() and turtle.forward() then
          moved = 1
        elseif turtle.back() then
          moved = -1
        elseif dig("fwd") and turtle.forward() then
          moved = 1
        end
        if moved == 0 then
          return "the turtle cannot move to measure its facing"
        end
        local second = rawScan()
        local dx, dz = measureShift(first, second)
        if not dx then
          return "the geo scans were not clear enough"
        end
        local f = facingOf(progress.scanFrame, dx * moved, dz * moved)
        if f == nil then
          return "the geo scans gave an unexpected direction"
        end
        pos.f = f
        pos.x = pos.x + moved * DELTA[f][1]
        pos.z = pos.z + moved * DELTA[f][2]
        return nil
      end)
      if not okProbe then
        return false, type(probeResult) == "table" and probeResult.msg or tostring(probeResult)
      end
      if probeResult then
        return false, "Facing unknown after restart: " .. probeResult
      end
      event("Facing recovered with the geo scanner")
      unsure = nil
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
        return false, type(pickupErr) == "table" and pickupErr.msg or tostring(pickupErr)
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
        self.handleCommand(tostring(msg.cmd), sender)
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
        local text = type(checkErr) == "table" and checkErr.msg or tostring(checkErr)
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
      local okCall, okWrite, startupErr = true, true, nil
      if not options.dock then
        okCall, okWrite, startupErr = pcall(installStartup)
      end
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
        local text = type(homeErr) == "table" and homeErr.msg or tostring(homeErr)
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

---@param text string
---@param default string
---@return "left"|"right"
local function askSide(text, default)
  while true do
    local side = prompt(text .. " (left/right)", default):lower()
    if side == "l" or side == "left" then
      return "left"
    elseif side == "r" or side == "right" then
      return "right"
    end
    printError("Enter left or right")
  end
end

--- Pick ore levels from the presets or enter them by hand.
---@param current integer[]
---@return integer[]
local function askOreLevels(current)
  print("Ore levels (Minecraft 1.18+):")
  local defaults = {}
  for i, preset in ipairs(ORE_PRESETS) do
    print(string.format("  %d  %-20s Y %d", i, preset.label, preset.y))
    for _, y in ipairs(current) do
      if y == preset.y then
        defaults[#defaults + 1] = tostring(i)
      end
    end
  end
  print("  c  own Y levels")
  local default = #defaults == #current and #defaults > 0 and table.concat(defaults, ",") or "c"
  while true do
    local answer = prompt("Choose (e.g. 1,4)", default):lower()
    local levels = {}
    local valid = true
    if answer == "c" then
      local text = prompt("Y levels, comma separated", table.concat(current, ","))
      for part in text:gmatch("[^,%s]+") do
        local y = tonumber(part)
        if not y or y ~= math.floor(y) or y < MIN_LEVEL_Y or y > MAX_LEVEL_Y then
          valid = false
        else
          levels[#levels + 1] = y
        end
      end
    else
      for part in answer:gmatch("[^,%s]+") do
        local preset = ORE_PRESETS[tonumber(part) or 0]
        if preset then
          levels[#levels + 1] = preset.y
        else
          valid = false
        end
      end
    end
    if valid and #levels > 0 then
      return levels
    end
    printError(string.format("Enter preset numbers or Y levels between %d and %d", MIN_LEVEL_Y, MAX_LEVEL_Y))
  end
end

---@param base MinerConfig
---@return MinerConfig
--- Ask for the kinds of ore to mine, e.g. "diamond, iron". "*" means all.
---@param current string[]
---@return string[]
local function askOreGroups(current)
  local shown = #current > 0 and table.concat(current, ",") or "*"
  local answer = prompt("Ores, e.g. diamond,osmium (*=all)", shown)
  local groups = {}
  for word in answer:gmatch("[^,%s]+") do
    if word ~= "*" then
      groups[#groups + 1] = oreKey(word)
    end
  end
  return groups
end

local function runWizard(base)
  local cfg = deepCopy(base)
  term.clear()
  term.setCursorPos(1, 1)
  print("Ender Miner " .. VERSION .. " setup")
  while true do
    local mode = prompt("Mode: ores or tunnel", cfg.mode):lower()
    if mode == "o" or mode == "ores" or mode == "ore" then
      cfg.mode = "ores"
      break
    elseif mode == "t" or mode == "tunnel" then
      cfg.mode = "tunnel"
      break
    end
    printError("Enter ores or tunnel")
  end

  if cfg.mode == "ores" then
    cfg.startY = askInt("Y of this turtle (F3)", cfg.startY or 64, -64, 320)
    cfg.oreLevels = askOreLevels(cfg.oreLevels)
    cfg.oreGroups = askOreGroups(cfg.oreGroups)
    cfg.areaWidth = askInt("Area width", cfg.areaWidth, INT_RULES.areaWidth[1], INT_RULES.areaWidth[2])
    cfg.areaLength = askInt("Area length", cfg.areaLength, INT_RULES.areaLength[1], INT_RULES.areaLength[2])
    cfg.side = askSide("Area side", cfg.side)
    cfg.toolSide = askSide("Pickaxe side", cfg.toolSide)
    cfg.returnHome = askBool("Return home at the end", cfg.returnHome)
    cfg.dropJunk = askBool("Drop cobble etc.", cfg.dropJunk)
    cfg.useFollower = false
  else
    cfg.tunnels = askInt("Tunnels", cfg.tunnels, INT_RULES.tunnels[1], INT_RULES.tunnels[2])
    cfg.width = askInt("Width", cfg.width, INT_RULES.width[1], INT_RULES.width[2])
    cfg.height = askInt("Height", cfg.height, INT_RULES.height[1], INT_RULES.height[2])
    cfg.length = askInt("Length", cfg.length, INT_RULES.length[1], INT_RULES.length[2])
    if cfg.tunnels > 1 then
      cfg.spacing = askInt("Blocks between", cfg.spacing, INT_RULES.spacing[1], INT_RULES.spacing[2])
    end
    if cfg.tunnels > 1 or cfg.width > 1 then
      cfg.side = askSide("Side", cfg.side)
    end
    cfg.useTorches = askBool("Place torches", cfg.useTorches)
    if cfg.useTorches then
      cfg.torchInterval =
        askInt("Torch distance", cfg.torchInterval, INT_RULES.torchInterval[1], INT_RULES.torchInterval[2])
    end
    cfg.dropJunk = askBool("Drop cobble etc.", cfg.dropJunk)
    cfg.useFollower = askBool("Chunk loader follower", cfg.useFollower)
  end
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
  if cfg.mode == "ores" then
    local levels = {}
    for _, y in ipairs(cfg.oreLevels) do
      levels[#levels + 1] = tostring(y)
    end
    print(
      string.format("Ores at Y %s, area %dx%d %s", table.concat(levels, ", "), cfg.areaWidth, cfg.areaLength, cfg.side)
    )
    print(string.format("Start Y %s  Return home: %s", tostring(cfg.startY), cfg.returnHome and "yes" or "no"))
    print("Ores: " .. (#cfg.oreGroups > 0 and table.concat(cfg.oreGroups, ", ") or "all"))
    print("")
    print("1: supply ender chest (coal)")
    print("2: resource ender chest")
    print("3: geo scanner  4: fuel  5-16: empty")
    print(cfg.toolSide .. " side: pickaxe, other side: chunky upgrade")
    print("")
    return
  end
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
  print("Follower: " .. (cfg.useFollower and "on (start 'follower' on the 2nd turtle)" or "off"))
  print("")
  print("1: supply ender chest (torches)")
  print("2: resource ender chest")
  print("3: torches  4: fuel  5-16: empty")
  print("")
end

--- Count down before an automatic resume, any key cancels.
---@param seconds integer
---@return boolean proceed
local function countdown(seconds)
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

---@param miner table
---@param miner table
---@return boolean success
---@return string state
---@return string message
local function runMiner(miner)
  local telemetry = miner.openTelemetry()
  local success, finalState, finalMessage = false, "error", ""
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
  return success, finalState, finalMessage
end

-- Dock mode: jobs from the station -------------------------------------------
--
-- The station computer and the docked turtle share a disk drive behind the
-- turtle. Files in <disk>/endermine/:
--   job     written by the station: { id, config }
--   ack     written by the turtle when it takes a job: { id }
--   report  written by the turtle: { jobId, state, message, ... }
-- At the dock the turtle unloads into a chest above and takes fuel from a
-- chest below.

local DOCK_DIR = "endermine"
local DOCK_STATE = "dock.state"
local DOCK_STARTUP = "startup/endermine-dock.lua"
local DOCK_POLL = 5

---@return string|nil path Mount path of the disk in the drive next to the turtle
---@return string|nil err
local function findDockDisk()
  if not peripheral then
    return nil, "no peripheral API"
  end
  local drive = peripheral.find("drive", function(_, wrapped)
    return wrapped.isDiskPresent() and wrapped.hasData()
  end)
  if not drive then
    return nil, "no disk drive with a floppy disk next to the turtle"
  end
  local path = drive.getMountPath()
  if not path then
    return nil, "the disk in the drive cannot be mounted"
  end
  return path, nil
end

---@param disk string
---@param name string
---@return table|nil
local function readDock(disk, name)
  return readTable(disk .. "/" .. DOCK_DIR .. "/" .. name)
end

---@param disk string
---@param name string
---@param data table
---@return boolean ok
local function writeDock(disk, name, data)
  local dir = disk .. "/" .. DOCK_DIR
  if not fs.exists(dir) then
    fs.makeDir(dir)
  end
  local ok = pcall(writeAtomic, dir .. "/" .. name, textutils.serialize(data))
  return ok
end

---@class DockOptions
---@field maxIdle integer|nil Stop after this many idle checks (tests)
---@field onPoll fun()|nil Called before every check for a new job (tests)

---@param baseCfg MinerConfig Hardware settings of this turtle (tool side, junk, ...)
---@param options DockOptions|nil
---@return string reason Why the dock loop ended
local function runDock(baseCfg, options)
  options = options or {}
  local disk, diskErr = findDockDisk()
  if not disk then
    printError("Dock mode: " .. tostring(diskErr))
    return "no disk"
  end
  if not fs.exists(STARTUP_DIR) then
    fs.makeDir(STARTUP_DIR)
  end
  pcall(
    writeAtomic,
    DOCK_STARTUP,
    "-- Generated by 'miner dock': waits at the station for jobs after a reboot.\n"
      .. "-- Delete this file to stop the dock mode.\n"
      .. 'shell.run("miner", "dock")\n'
  )
  local dockState = readTable(DOCK_STATE) or { lastJobId = 0 }
  local id = os.getComputerID()
  local lastStats = nil

  local function saveDockState()
    pcall(writeAtomic, DOCK_STATE, textutils.serialize(dockState))
  end

  ---@param state string
  ---@param message string
  ---@param jobId integer|nil
  local function report(state, message, jobId)
    local fuel = turtle.getFuelLevel()
    writeDock(disk, "report", {
      turtle = id,
      label = os.getComputerLabel(),
      version = VERSION,
      state = state,
      message = message,
      jobId = jobId or dockState.lastJobId,
      fuel = fuel == "unlimited" and -1 or fuel,
      stats = lastStats,
      -- The outcome of the last job stays in every report, so the station
      -- sees it even when it reads the disk only after the next "idle"
      result = dockState.lastResult,
      at = now(),
    })
    print(string.format("[%s] %s", state, message))
  end

  --- Unload into the chest above and fill up with fuel from the chest below.
  ---@return boolean ok
  local function service()
    for slot = FIRST_LOOT, LAST_SLOT do
      while turtle.getItemCount(slot) > 0 do
        turtle.select(slot)
        if not turtle.dropUp() then
          report("output_full", "Chest above the dock is full or missing")
          sleep(DOCK_POLL)
        end
      end
    end
    local target = baseCfg.dockFuel
    local limit = turtle.getFuelLimit()
    if limit ~= "unlimited" then
      target = math.min(target, limit)
      turtle.select(SLOT_FUEL)
      local waited = false
      while turtle.getFuelLevel() < target do
        if turtle.getItemCount(SLOT_FUEL) == 0 and not turtle.suckDown() then
          if not waited then
            report("waiting_fuel", "Put fuel into the chest below the dock")
            waited = true
          end
          sleep(DOCK_POLL)
        elseif not turtle.refuel(1) then
          -- Not fuel: move it to the chest above with the loot
          if not turtle.dropUp() then
            sleep(DOCK_POLL)
          end
        end
      end
      -- Keep a stack of fuel for the way
      turtle.suckDown(64 - turtle.getItemCount(SLOT_FUEL))
    end
    turtle.select(FIRST_LOOT)
    return true
  end

  ---@param jobId integer
  ---@param state string
  ---@param message string
  local function finish(jobId, state, message)
    dockState.lastResult = { jobId = jobId, state = state, message = message, stats = lastStats }
    saveDockState()
    report(state, message, jobId)
  end

  ---@param miner table
  ---@param jobId integer
  ---@return boolean success
  local function runJob(miner, jobId)
    local success, state, message = runMiner(miner)
    local status = miner.getStatus()
    lastStats = {
      mined = status.mined,
      ores = status.ores,
      dumps = status.dumps,
      uptime = status.uptime,
      restarts = status.restarts,
      seen = status.seenOres,
    }
    finish(jobId, success and "done" or tostring(state), tostring(message))
    return success
  end

  local idle = 0
  while true do
    local saved = loadSavedJob()
    if saved then
      report("working", "Job " .. tostring(dockState.lastJobId) .. " resumed", dockState.lastJobId)
      if not runJob(createMiner(saved.cfg, saved, { dock = true }), dockState.lastJobId) then
        return "job failed"
      end
    end
    service()
    if options.onPoll then
      options.onPoll()
    end
    local job = readDock(disk, "job")
    if type(job) == "table" and type(job.id) == "number" and job.id > (dockState.lastJobId or 0) then
      idle = 0
      dockState.lastJobId = job.id
      saveDockState()
      writeDock(disk, "ack", { id = job.id, turtle = id, at = now() })
      local cfg = mergeConfig(baseCfg, type(job.config) == "table" and job.config or {})
      cfg.mode = "ores"
      cfg.returnHome = true
      local valid, errors = validateConfig(cfg)
      if not valid then
        lastStats = nil
        finish(job.id, "rejected", "Invalid job: " .. table.concat(errors, "; "))
      else
        report("working", "Job " .. job.id .. " started", job.id)
        lastStats = nil
        if not runJob(createMiner(cfg, nil, { dock = true }), job.id) then
          return "job failed"
        end
      end
    else
      idle = idle + 1
      if idle == 1 then
        report("idle", "Waiting at the station for a job")
      end
      if options.maxIdle and idle >= options.maxIdle then
        return "idle"
      end
      local timer = os.startTimer(DOCK_POLL)
      while true do
        local ev, arg = os.pullEvent()
        if ev == "timer" and arg == timer then
          break
        elseif ev == "key" and arg == keys.q then
          report("stopped", "Dock mode stopped by hand")
          removeFile(DOCK_STARTUP)
          return "stopped"
        end
      end
    end
  end
end

--- Run the auto updater when it is installed.
---@param argv string[] Arguments without "--no-update"
---@param jobActive boolean
---@return boolean restarted A newer version ran, this one has to stop
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
    role = "miner",
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
    printError("This program must run on a mining turtle.")
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

  local saved, savedErr = loadSavedJob()
  if savedErr then
    printError("Cannot resume the last job: " .. savedErr)
    clearJob()
  end
  if not noUpdate and runAutoUpdate(argv, saved ~= nil) then
    return
  end

  if argv[1] == "dock" then
    print("Dock mode - press Q while waiting to stop it")
    if saved and not countdown(RESUME_COUNTDOWN) then
      print("Cancelled.")
      return
    end
    local base = loadConfig(CONFIG_FILE) or deepCopy(DEFAULT_CONFIG)
    runDock(base)
    return
  end

  if argv[1] == "resume" then
    if not saved then
      -- Nothing to do, make sure the startup file does not linger
      removeFile(STARTUP_FILE)
      print("No interrupted mining job found.")
      return
    end
    if not countdown(RESUME_COUNTDOWN) then
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
    if askBool("Resume it", true) then
      pcall(installStartup)
      runMiner(createMiner(saved.cfg, saved))
      return
    end
    clearJob()
    print("Job discarded.")
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
  validateConfig = validateConfig,
  loadConfig = loadConfig,
  saveConfig = saveConfig,
  loadSavedJob = loadSavedJob,
  toRelative = toRelative,
  facingOf = facingOf,
  DELTA = DELTA,
  STATE_FORMAT = STATE_FORMAT,
  columnX = columnX,
  torchSpot = torchSpot,
  cellIndex = cellIndex,
  lastCellOfBand = lastCellOfBand,
  locateColumn = locateColumn,
  isOpenCell = isOpenCell,
  isParkingCell = isParkingCell,
  ORE_PRESETS = ORE_PRESETS,
  scanSpacing = scanSpacing,
  oreLevelBands = oreLevelBands,
  scanAxis = scanAxis,
  scanPlan = scanPlan,
  levelOrder = levelOrder,
  planTour = planTour,
  isWantedOre = isWantedOre,
  isOreBlock = isOreBlock,
  oreKey = oreKey,
  createMiner = createMiner,
  runWizard = runWizard,
  runDock = runDock,
  DOCK_DIR = DOCK_DIR,
  DOCK_STARTUP = DOCK_STARTUP,
}

local args = { ... }
if args[1] == "--lib" then
  return M
end
main(args)
