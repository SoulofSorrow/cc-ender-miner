-- Minimal CC: Tweaked environment for offline tests.
-- Simulates a voxel world, a turtle, EnderStorage-like ender chests,
-- rednet and a cooperative scheduler for parallel.waitForAny.

local Mock = {}

local unpackFn = table.unpack or unpack

local CHEST = "enderstorage:ender_chest"
local MAX_STACK = 64
local CHEST_SLOTS = 27

local DROPS = {
  ["minecraft:stone"] = "minecraft:cobblestone",
  ["minecraft:deepslate"] = "minecraft:cobbled_deepslate",
  ["minecraft:coal_ore"] = "minecraft:coal",
  ["minecraft:iron_ore"] = "minecraft:raw_iron",
  ["minecraft:diamond_ore"] = "minecraft:diamond",
}

local FUEL_VALUES = {
  ["minecraft:coal"] = 80,
  ["minecraft:charcoal"] = 80,
  ["minecraft:coal_block"] = 800,
  ["minecraft:oak_planks"] = 15,
}

local GRAVITY = { ["minecraft:gravel"] = true, ["minecraft:sand"] = true }

local DELTA = { [0] = { 0, 1 }, [1] = { 1, 0 }, [2] = { 0, -1 }, [3] = { -1, 0 } }

Mock.CHEST = CHEST

Mock.colors = {
  white = 1,
  orange = 2,
  magenta = 4,
  lightBlue = 8,
  yellow = 16,
  lime = 32,
  pink = 64,
  gray = 128,
  lightGray = 256,
  cyan = 512,
  purple = 1024,
  blue = 2048,
  brown = 4096,
  green = 8192,
  red = 16384,
  black = 32768,
}

---@param value any
---@param indent string|nil
---@return string
local function serialize(value, indent)
  indent = indent or ""
  local kind = type(value)
  if kind == "string" then
    return string.format("%q", value)
  elseif kind == "number" or kind == "boolean" or kind == "nil" then
    return tostring(value)
  elseif kind == "table" then
    local parts = {}
    local keys = {}
    for k in pairs(value) do
      keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(keys) do
      local keyText
      if type(k) == "string" and k:match("^[%a_][%w_]*$") then
        keyText = k
      else
        keyText = "[" .. serialize(k) .. "]"
      end
      parts[#parts + 1] = indent .. "  " .. keyText .. " = " .. serialize(value[k], indent .. "  ")
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
  end
  error("cannot serialize " .. kind)
end

---@param text string
---@return any
local function unserialize(text)
  local chunk = load("return " .. text, "unserialize", "t", {})
  if not chunk then
    return nil
  end
  local ok, value = pcall(chunk)
  if ok then
    return value
  end
  return nil
end

Mock.serialize = serialize
Mock.unserialize = unserialize

---@param width integer
---@param height integer
---@return table
function Mock.newScreen(width, height)
  local screen = { w = width, h = height, x = 1, y = 1, fg = 1, bg = 32768, rows = {}, scale = 1 }
  local function blank()
    for row = 1, screen.h do
      screen.rows[row] = string.rep(" ", screen.w)
    end
  end
  blank()
  function screen.getSize()
    return screen.w, screen.h
  end
  function screen.setCursorPos(x, y)
    screen.x, screen.y = math.floor(x), math.floor(y)
  end
  function screen.getCursorPos()
    return screen.x, screen.y
  end
  function screen.write(text)
    text = tostring(text)
    local row = screen.rows[screen.y]
    if row then
      for i = 1, #text do
        local col = screen.x + i - 1
        if col >= 1 and col <= screen.w then
          row = row:sub(1, col - 1) .. text:sub(i, i) .. row:sub(col + 1)
        end
      end
      screen.rows[screen.y] = row
    end
    screen.x = screen.x + #text
  end
  function screen.clear()
    blank()
  end
  function screen.clearLine()
    if screen.rows[screen.y] then
      screen.rows[screen.y] = string.rep(" ", screen.w)
    end
  end
  function screen.setTextColor(c)
    screen.fg = c
  end
  function screen.setBackgroundColor(c)
    screen.bg = c
  end
  function screen.isColor()
    return true
  end
  function screen.setTextScale(s)
    screen.scale = s
  end
  function screen.text()
    return table.concat(screen.rows, "\n")
  end
  ---@param needle string
  ---@return integer|nil x
  ---@return integer|nil y
  function screen.find(needle)
    for y, row in ipairs(screen.rows) do
      local x = row:find(needle, 1, true)
      if x then
        return x, y
      end
    end
    return nil, nil
  end
  screen.setTextColour = screen.setTextColor
  screen.setBackgroundColour = screen.setBackgroundColor
  screen.isColour = screen.isColor
  return screen
end

---@class MockOptions
---@field fuel integer|nil
---@field unlimited boolean|nil
---@field generator (fun(x: integer, y: integer, z: integer): string)|nil
---@field modem boolean|nil
---@field id integer|nil
---@field label string|nil
---@field gps table|nil Absolute GPS frame {x, y, z, dir}

---@param opts MockOptions|nil
---@return table env
function Mock.new(opts)
  opts = opts or {}
  local env = {
    blocks = {},
    chestFreq = {},
    chests = {},
    chestCapacity = CHEST_SLOTS,
    dropped = {},
    digs = {},
    broadcasts = {},
    sent = {},
    queue = {},
    files = {},
    dirs = {},
    clock = 0,
    moves = 0,
    turns = 0,
    actions = 0,
    actionKinds = {},
    killed = false,
    kill = nil,
    sleeps = 0,
    hooks = {},
    inScheduler = false,
  }
  local generator = opts.generator or function()
    return "minecraft:stone"
  end
  local t = { x = 0, y = 0, z = 0, f = 0, inv = {}, sel = 1, fuel = opts.fuel or 5000, limit = 20000 }
  env.turtle = t

  -- %d keeps -0 and 0 on the same key
  local function key(x, y, z)
    return string.format("%d,%d,%d", x, y, z)
  end

  function env.get(x, y, z)
    if x == t.x and y == t.y and z == t.z then
      return "turtle"
    end
    local value = env.blocks[key(x, y, z)]
    if value == nil then
      value = generator(x, y, z)
      if x == 0 and y == 0 and z == 0 then
        value = "air"
      end
    end
    return value
  end

  function env.set(x, y, z, name)
    env.blocks[key(x, y, z)] = name
  end

  local function isEmpty(name)
    return name == "air"
  end

  --- Let gravity blocks above (x, y, z) fall down into the free space.
  local function settle(x, y, z)
    local above = y + 1
    while GRAVITY[env.get(x, above, z)] and isEmpty(env.get(x, above - 1, z)) do
      env.set(x, above - 1, z, env.get(x, above, z))
      env.set(x, above, z, "air")
      above = above + 1
    end
  end

  local function dirPos(dir)
    if dir == "up" then
      return t.x, t.y + 1, t.z
    elseif dir == "down" then
      return t.x, t.y - 1, t.z
    elseif dir == "back" then
      return t.x - DELTA[t.f][1], t.y, t.z - DELTA[t.f][2]
    end
    return t.x + DELTA[t.f][1], t.y, t.z + DELTA[t.f][2]
  end

  --- Store items like CC does: start at the selected slot and wrap around.
  ---@return integer leftover
  local function store(name, count, nbt)
    for i = 0, 15 do
      local slot = (t.sel - 1 + i) % 16 + 1
      local stack = t.inv[slot]
      if stack == nil then
        local add = math.min(MAX_STACK, count)
        t.inv[slot] = { name = name, count = add, nbt = nbt }
        count = count - add
      elseif stack.name == name and stack.nbt == nbt then
        local add = math.min(MAX_STACK - stack.count, count)
        stack.count = stack.count + add
        count = count - add
      end
      if count == 0 then
        return 0
      end
    end
    return count
  end

  local function yieldPoint()
    if env.inScheduler and coroutine.running() then
      coroutine.yield("__tick")
    end
  end

  --- Simulate a chunk unload: the program stops for good at this point.
  --- env.kill = { at = <action number>, after = <bool> } kills before or
  --- after the world was changed by that action.
  ---@param phase "before"|"after"
  local function maybeKill(phase)
    local kill = env.kill
    if kill and not env.killed and env.actions == kill.at and (phase == "after") == (kill.after == true) then
      env.killed = true
      coroutine.yield("__kill")
      error("killed coroutine was resumed", 0)
    end
  end

  ---@param kind "move"|"turn"|"place"
  local function beginAction(kind)
    env.actions = env.actions + 1
    env.actionKinds[env.actions] = kind
    maybeKill("before")
  end

  local function chestAt(x, y, z)
    if env.get(x, y, z) ~= CHEST then
      return nil
    end
    local freq = env.chestFreq[key(x, y, z)] or "default"
    env.chests[freq] = env.chests[freq] or {}
    return env.chests[freq]
  end

  local api = {}

  local function digDir(dir)
    local x, y, z = dirPos(dir)
    local block = env.get(x, y, z)
    if isEmpty(block) then
      return false, "Nothing to dig here"
    end
    if block == "minecraft:bedrock" then
      return false, "Cannot break unbreakable block"
    end
    local nbt = nil
    if block == CHEST then
      nbt = env.chestFreq[key(x, y, z)]
      env.chestFreq[key(x, y, z)] = nil
    end
    env.set(x, y, z, "air")
    env.digs[#env.digs + 1] = { x = x, y = y, z = z, name = block }
    local item = DROPS[block] or block
    local left = store(item, 1, nbt)
    if left > 0 then
      env.dropped[#env.dropped + 1] = { name = item, count = left, lost = true }
    end
    settle(x, y, z)
    return true
  end

  local function detectDir(dir)
    return not isEmpty(env.get(dirPos(dir)))
  end

  local function inspectDir(dir)
    local block = env.get(dirPos(dir))
    if isEmpty(block) then
      return false, "No block to inspect"
    end
    return true, { name = block, tags = {} }
  end

  local moveInner

  local function moveDir(dir)
    beginAction("move")
    local ok, err = moveInner(dir)
    maybeKill("after")
    if ok then
      yieldPoint()
    end
    return ok, err
  end

  moveInner = function(dir)
    if t.fuel <= 0 and not opts.unlimited then
      return false, "Out of fuel"
    end
    local x, y, z = dirPos(dir)
    if not isEmpty(env.get(x, y, z)) then
      return false, "Movement obstructed"
    end
    local ox, oy, oz = t.x, t.y, t.z
    t.x, t.y, t.z = x, y, z
    if not opts.unlimited then
      t.fuel = t.fuel - 1
    end
    env.moves = env.moves + 1
    env.set(ox, oy, oz, "air")
    settle(ox, oy, oz)
    if env.hooks.move then
      env.hooks.move(env)
    end
    return true
  end

  local placeInner

  local function placeDir(dir)
    beginAction("place")
    local ok, err = placeInner(dir)
    maybeKill("after")
    return ok, err
  end

  placeInner = function(dir)
    local stack = t.inv[t.sel]
    if not stack then
      return false, "No items to place"
    end
    local x, y, z = dirPos(dir)
    if not isEmpty(env.get(x, y, z)) then
      return false, "Cannot place block here"
    end
    if stack.name == CHEST then
      env.set(x, y, z, CHEST)
      env.chestFreq[key(x, y, z)] = stack.nbt
    elseif stack.name == "minecraft:torch" then
      if isEmpty(env.get(x, y - 1, z)) then
        return false, "Cannot place block here"
      end
      env.set(x, y, z, "minecraft:torch")
    else
      env.set(x, y, z, stack.name)
    end
    stack.count = stack.count - 1
    if stack.count == 0 then
      t.inv[t.sel] = nil
    end
    return true
  end

  local function dropDir(dir, count)
    local stack = t.inv[t.sel]
    if not stack then
      return false, "No items to drop"
    end
    count = math.min(count or stack.count, stack.count)
    local chest = chestAt(dirPos(dir))
    if chest then
      local moved = 0
      for i = 1, env.chestCapacity do
        local slot = chest[i]
        if slot == nil then
          chest[i] = { name = stack.name, count = 0, nbt = stack.nbt }
          slot = chest[i]
        end
        if slot.name == stack.name and slot.nbt == stack.nbt then
          local add = math.min(MAX_STACK - slot.count, count - moved)
          slot.count = slot.count + add
          moved = moved + add
        end
        if moved == count then
          break
        end
      end
      for i = env.chestCapacity, 1, -1 do
        if chest[i] and chest[i].count == 0 then
          chest[i] = nil
        end
      end
      if moved == 0 then
        return false, "No space for items"
      end
      stack.count = stack.count - moved
    else
      env.dropped[#env.dropped + 1] = { name = stack.name, count = count }
      stack.count = stack.count - count
    end
    if stack.count == 0 then
      t.inv[t.sel] = nil
    end
    return true
  end

  local function suckDir(dir, count)
    local chest = chestAt(dirPos(dir))
    if not chest then
      return false, "No items to take"
    end
    for i = 1, env.chestCapacity do
      local slot = chest[i]
      if slot and slot.count > 0 then
        local wanted = math.min(count or MAX_STACK, slot.count)
        local left = store(slot.name, wanted, slot.nbt)
        local taken = wanted - left
        slot.count = slot.count - taken
        if slot.count == 0 then
          chest[i] = nil
        end
        if taken == 0 then
          return false, "No space for items"
        end
        return true
      end
    end
    return false, "No items to take"
  end

  for _, spec in ipairs({ { "", "fwd" }, { "Up", "up" }, { "Down", "down" } }) do
    local suffix, dir = spec[1], spec[2]
    api["dig" .. suffix] = function()
      return digDir(dir)
    end
    api["detect" .. suffix] = function()
      return detectDir(dir)
    end
    api["inspect" .. suffix] = function()
      return inspectDir(dir)
    end
    api["place" .. suffix] = function()
      return placeDir(dir)
    end
    api["drop" .. suffix] = function(count)
      return dropDir(dir, count)
    end
    api["suck" .. suffix] = function(count)
      return suckDir(dir, count)
    end
    api["attack" .. suffix] = function()
      return false, "Nothing to attack here"
    end
  end
  api.forward = function()
    return moveDir("fwd")
  end
  api.up = function()
    return moveDir("up")
  end
  api.down = function()
    return moveDir("down")
  end
  api.back = function()
    return moveDir("back")
  end
  api.turnRight = function()
    beginAction("turn")
    t.f = (t.f + 1) % 4
    env.turns = env.turns + 1
    maybeKill("after")
    return true
  end
  api.turnLeft = function()
    beginAction("turn")
    t.f = (t.f + 3) % 4
    env.turns = env.turns + 1
    maybeKill("after")
    return true
  end
  api.select = function(slot)
    assert(type(slot) == "number" and slot >= 1 and slot <= 16, "bad slot " .. tostring(slot))
    t.sel = slot
    return true
  end
  api.getSelectedSlot = function()
    return t.sel
  end
  api.getItemCount = function(slot)
    slot = slot or t.sel
    return t.inv[slot] and t.inv[slot].count or 0
  end
  api.getItemSpace = function(slot)
    slot = slot or t.sel
    return t.inv[slot] and (MAX_STACK - t.inv[slot].count) or MAX_STACK
  end
  api.getItemDetail = function(slot)
    slot = slot or t.sel
    local stack = t.inv[slot]
    if not stack then
      return nil
    end
    return { name = stack.name, count = stack.count, nbt = stack.nbt }
  end
  api.transferTo = function(slot, count)
    local stack = t.inv[t.sel]
    if not stack or slot == t.sel then
      return false
    end
    local target = t.inv[slot]
    if target and (target.name ~= stack.name or target.nbt ~= stack.nbt) then
      return false
    end
    local space = MAX_STACK - (target and target.count or 0)
    local moved = math.min(count or stack.count, stack.count, space)
    if moved <= 0 then
      return false
    end
    if not target then
      t.inv[slot] = { name = stack.name, count = 0, nbt = stack.nbt }
      target = t.inv[slot]
    end
    target.count = target.count + moved
    stack.count = stack.count - moved
    if stack.count == 0 then
      t.inv[t.sel] = nil
    end
    return true
  end
  api.refuel = function(count)
    local stack = t.inv[t.sel]
    if not stack then
      return false, "No items to combust"
    end
    local value = FUEL_VALUES[stack.name]
    if not value then
      return false, "Items not combustible"
    end
    if count == 0 then
      return true
    end
    local burn = math.min(count or stack.count, stack.count)
    for _ = 1, burn do
      if t.fuel >= t.limit then
        break
      end
      t.fuel = math.min(t.limit, t.fuel + value)
      stack.count = stack.count - 1
    end
    if stack.count == 0 then
      t.inv[t.sel] = nil
    end
    return true
  end
  api.getFuelLevel = function()
    if opts.unlimited then
      return "unlimited"
    end
    return t.fuel
  end
  api.getFuelLimit = function()
    if opts.unlimited then
      return "unlimited"
    end
    return t.limit
  end
  env.api = api

  --- Put an item stack into a turtle slot.
  function env.give(slot, name, count, nbt)
    t.inv[slot] = { name = name, count = count, nbt = nbt }
  end

  --- Put stacks into an ender chest frequency.
  function env.fillChest(freq, stacks)
    env.chests[freq] = {}
    for i, stack in ipairs(stacks) do
      env.chests[freq][i] = { name = stack[1], count = stack[2] }
    end
  end

  --- Count items of a name in an ender chest frequency.
  function env.chestCount(freq, name)
    local total = 0
    for _, stack in pairs(env.chests[freq] or {}) do
      if name == nil or stack.name == name then
        total = total + stack.count
      end
    end
    return total
  end

  ---@param msg table
  ---@param sender integer
  ---@param protocol string
  function env.queueMessage(sender, msg, protocol)
    env.queue[#env.queue + 1] = { "rednet_message", sender, msg, protocol }
  end

  --- Last broadcast payload of a given type.
  function env.lastBroadcast(kind)
    for i = #env.broadcasts, 1, -1 do
      local entry = env.broadcasts[i]
      if type(entry.msg) == "table" and entry.msg.type == kind then
        return entry.msg
      end
    end
    return nil
  end

  local function waitForAny(...)
    local fns = { ... }
    local routines = {}
    for i, fn in ipairs(fns) do
      routines[i] = { co = coroutine.create(fn), filter = nil }
    end
    env.inScheduler = true
    local ev = {}
    local guard = 0
    while true do
      for i, routine in ipairs(routines) do
        if routine.filter == nil or routine.filter == ev[1] then
          local result = { coroutine.resume(routine.co, unpackFn(ev)) }
          if not result[1] then
            env.inScheduler = false
            error(result[2], 0)
          end
          if coroutine.status(routine.co) == "dead" then
            env.inScheduler = false
            return i
          end
          routine.filter = result[2]
        end
      end
      ev = table.remove(env.queue, 1) or { "__tick" }
      guard = guard + 1
      if guard > 5000000 then
        env.inScheduler = false
        error("scheduler runaway", 0)
      end
    end
  end

  --- Install the simulated APIs as globals.
  function env.install()
    _G.turtle = api
    _G.colors = Mock.colors
    _G.colours = Mock.colors
    _G.window = nil
    _G.keys = { q = 16 }
    _G.sleep = function(seconds)
      env.clock = env.clock + (seconds or 0)
      env.sleeps = env.sleeps + 1
      if env.hooks.sleep then
        env.hooks.sleep(env)
      end
      if env.sleeps > 100000 then
        error("sleep runaway", 0)
      end
      yieldPoint()
    end
    os.epoch = function()
      return math.floor(env.clock * 1000)
    end
    os.getComputerID = function()
      return opts.id or 7
    end
    os.getComputerLabel = function()
      return opts.label
    end
    os.pullEvent = function(filter)
      return coroutine.yield(filter)
    end
    _G.fs = {
      exists = function(path)
        return env.files[path] ~= nil or env.dirs[path] == true
      end,
      isDir = function(path)
        return env.dirs[path] == true
      end,
      makeDir = function(path)
        env.dirs[path] = true
      end,
      delete = function(path)
        env.files[path] = nil
        env.dirs[path] = nil
      end,
      move = function(from, to)
        if env.files[from] == nil then
          error("No such file: " .. from, 0)
        end
        if env.files[to] ~= nil then
          error("File exists: " .. to, 0)
        end
        env.files[to] = env.files[from]
        env.files[from] = nil
      end,
      open = function(path, mode)
        if mode == "r" then
          if env.files[path] == nil then
            return nil, "No such file"
          end
          local content = env.files[path]
          return {
            readAll = function()
              return content
            end,
            close = function() end,
          }
        end
        local parts = {}
        return {
          write = function(text)
            parts[#parts + 1] = text
          end,
          close = function()
            env.files[path] = table.concat(parts)
          end,
        }
      end,
    }
    _G.textutils = { serialize = serialize, unserialize = unserialize }
    _G.term = Mock.newScreen(39, 13)
    local modem = {
      isWireless = function()
        return true
      end,
    }
    _G.peripheral = {
      find = function(kind, filter)
        if kind == "modem" and opts.modem and (filter == nil or filter("back", modem)) then
          return modem
        end
        return nil
      end,
      getName = function()
        return "back"
      end,
    }
    local open = {}
    _G.rednet = {
      open = function(name)
        open[name] = true
      end,
      isOpen = function(name)
        return open[name] == true
      end,
      broadcast = function(msg, protocol)
        env.broadcasts[#env.broadcasts + 1] = { msg = msg, protocol = protocol }
      end,
      send = function(id, msg, protocol)
        env.sent[#env.sent + 1] = { id = id, msg = msg, protocol = protocol }
        return true
      end,
      receive = function(protocol)
        while true do
          local ev = { os.pullEvent("rednet_message") }
          if protocol == nil or ev[4] == protocol then
            return ev[2], ev[3], ev[4]
          end
        end
      end,
    }
    _G.parallel = { waitForAny = waitForAny }
    if opts.gps then
      -- Absolute world frame: start block at opts.gps.{x,y,z}, relative
      -- facing 0 points to compass direction opts.gps.dir
      local compass = { north = { 0, -1 }, east = { 1, 0 }, south = { 0, 1 }, west = { -1, 0 } }
      local d = compass[opts.gps.dir or "north"]
      _G.gps = {
        locate = function()
          if env.gpsDown then
            return nil
          end
          local ax = opts.gps.x + t.z * d[1] + t.x * -d[2]
          local az = opts.gps.z + t.z * d[2] + t.x * d[1]
          return ax, opts.gps.y + t.y, az
        end,
      }
    else
      _G.gps = nil
    end
    _G.write = function() end
    _G.print = function() end
    _G.printError = function() end
    _G.read = function()
      return ""
    end
  end

  return env
end

return Mock
