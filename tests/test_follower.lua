-- Tests for the shared job geometry and the follower turtle

local H = require("helpers")
local Mock = require("mock_cc")

local tests = {}

---@param name string
---@param fn function
local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

---@param status table Miner status payload
---@return table
local function progressOf(status)
  return { done = status.progress.done, tunnel = status.progress.index, phase = status.progress.phase }
end

---@param cfg table
---@return integer minX
---@return integer maxX
local function xRange(cfg)
  local span = cfg.tunnels * (cfg.width + cfg.spacing)
  if cfg.side == "left" then
    return -span - 1, 1
  end
  return -1, span + 1
end

local SHAPES = {
  { width = 3, height = 3, spacing = 2 },
  { width = 1, height = 3, spacing = 1 },
  { width = 2, height = 6, spacing = 1 },
  { width = 4, height = 5, spacing = 0 },
  { width = 3, height = 7, spacing = 2 },
  { width = 2, height = 2, spacing = 1 },
  { width = 1, height = 1, spacing = 1 },
}

test("open and parking cells match the simulated miner", function()
  for _, side in ipairs({ "right", "left" }) do
    for _, shape in ipairs(SHAPES) do
      for _, torches in ipairs({ true, false }) do
        local config = {
          tunnels = 3,
          width = shape.width,
          height = shape.height,
          length = 12,
          spacing = shape.spacing,
          side = side,
          useTorches = torches,
          torchInterval = 4,
          dropJunk = false,
        }
        local env, miner, cfg, M = H.setup({ config = config })
        local bands = M.computeBands(cfg.height)
        local parked = {}
        local label = string.format("%s %dx%d torches=%s", side, cfg.width, cfg.height, tostring(torches))
        local minX, maxX = xRange(cfg)
        local checks = 0
        env.hooks.move = function(e)
          local t = e.turtle
          local here = string.format("%d,%d,%d", t.x, t.y, t.z)
          if parked[here] then
            error(string.format("%s: miner entered parking cell %s (marked at move %d)", label, here, parked[here]), 0)
          end
          if e.moves % 7 ~= 0 then
            return
          end
          checks = checks + 1
          local prog = progressOf(miner.getStatus())
          for x = minX, maxX do
            for y = -1, cfg.height do
              for z = -1, cfg.length + 1 do
                -- 0/0/-1 is the follower's own start block, solid in a miner-only world
                if z ~= -1 and M.isOpenCell(cfg, bands, prog, x, y, z) then
                  local block = e.get(x, y, z)
                  if block ~= "air" and block ~= "turtle" and block ~= "enderstorage:ender_chest" then
                    error(string.format("%s: cell %d/%d/%d claimed open but is %s", label, x, y, z, block), 0)
                  end
                end
                if M.isParkingCell(cfg, bands, prog, x, y, z) then
                  local key = string.format("%d,%d,%d", x, y, z)
                  parked[key] = parked[key] or e.moves
                end
              end
            end
          end
        end
        local ok, state, msg = miner.run()
        H.check(ok, label .. ": run failed: " .. tostring(state) .. " " .. tostring(msg))
        H.check(checks > 3, label .. ": too few checks")
        local count = 0
        for _ in pairs(parked) do
          count = count + 1
        end
        if cfg.height >= 3 then
          H.check(count > 10, label .. ": expected parking cells, got " .. count)
        end
      end
    end
  end
end)

test("cell index follows the mining order", function()
  local env, miner, cfg, M = H.setup({ config = { tunnels = 2, width = 3, height = 4, length = 6, spacing = 1 } })
  local bands = M.computeBands(cfg.height)
  local last = 0
  env.hooks.move = function()
    local done = miner.getStatus().progress.done
    H.check(done >= last, "progress must never go backwards")
    last = done
  end
  H.check(miner.run(), "run failed")
  H.eq(miner.getStatus().progress.done, cfg.tunnels * #bands * cfg.width * cfg.length, "all cells done")
  local total = cfg.tunnels * #bands * cfg.width * cfg.length
  local indices = {}
  for tunnel = 0, cfg.tunnels - 1 do
    for column = 0, cfg.width - 1 do
      for z = 1, cfg.length do
        for b = 1, #bands do
          local index = M.cellIndex(cfg, #bands, tunnel, column, z, b)
          H.check(index >= 1 and index <= total, "index out of range")
          H.check(not indices[index], "index used twice: " .. index)
          indices[index] = true
        end
      end
    end
  end
  for i = 1, total do
    H.check(indices[i], "index missing: " .. i)
  end
end)

local HUB_ID, MINER_ID, FOLLOWER_ID = 50, 7, 8
local PROTOCOL = "endermine.v1"

---@param value any
---@return any
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = copy(v)
  end
  return out
end

--- Ender modem network between the simulated computers.
---@return table
local function newNet()
  local net = { inbox = { [HUB_ID] = {}, [MINER_ID] = {}, [FOLLOWER_ID] = {} }, log = {} }
  ---@param id integer
  ---@return table rednet API of one computer
  function net.rednetFor(id)
    return {
      open = function() end,
      isOpen = function()
        return true
      end,
      send = function(to, msg, protocol)
        net.log[#net.log + 1] = { from = id, to = to, msg = copy(msg) }
        if net.inbox[to] then
          table.insert(net.inbox[to], { from = id, msg = copy(msg), protocol = protocol })
        end
        return true
      end,
      broadcast = function(msg, protocol)
        for to, box in pairs(net.inbox) do
          if to ~= id then
            table.insert(box, { from = id, msg = copy(msg), protocol = protocol })
          end
        end
      end,
      receive = function()
        error("rednet.receive is not used in the co-simulation", 0)
      end,
    }
  end
  return net
end

---@param id integer
---@param label string
---@return table
local function osFor(id, label)
  return setmetatable({
    getComputerID = function()
      return id
    end,
    getComputerLabel = function()
      return label
    end,
  }, { __index = os })
end

---@param chunkLoader boolean
---@param loader table|nil Receives the active flag
---@return table
local function peripheralFor(chunkLoader, loader)
  local modem = {
    isWireless = function()
      return true
    end,
  }
  return {
    find = function(kind, filter)
      if kind == "modem" and (filter == nil or filter("left", modem)) then
        return modem
      end
      return nil
    end,
    getName = function()
      return "left"
    end,
    getType = function(side)
      if chunkLoader and side == "right" then
        return "chunk_loader"
      end
      return nil
    end,
    wrap = function(side)
      if chunkLoader and side == "right" then
        return {
          setActive = function(value)
            loader.active = value
          end,
        }
      end
      return nil
    end,
  }
end

--- Run miner, follower and monitor together in one world.
---@param config table Miner configuration
---@param opts table|nil {followDistance, followerFuel, hook}
---@return table result
local function coSimulate(config, opts)
  opts = opts or {}
  local env = Mock.new({ generator = H.oreWorld })
  env.install()
  env.give(1, Mock.CHEST, 1, "supply")
  env.give(2, Mock.CHEST, 1, "resources")
  env.give(3, "minecraft:torch", 64)
  env.fillChest("supply", { { "minecraft:torch", 64 }, { "minecraft:torch", 64 } })
  env.fillChest("resources", {})
  local followerState, followerApi = env.addTurtle({ x = 0, y = 0, z = -1, f = 0, fuel = opts.followerFuel or 3000 })
  env.set(0, 0, -1, "air")

  local net = newNet()
  local gpsApi = nil
  if opts.gps then
    -- GPS for the miner only: start block at opts.gps, facing east
    gpsApi = {
      locate = function()
        local m = env.turtle
        return opts.gps.x + m.z, opts.gps.y + m.y, opts.gps.z + m.x
      end,
    }
  end
  local minerLib = H.loadProgramEnv(H.SRC .. "/miner.lua", {
    turtle = env.api,
    os = osFor(MINER_ID, "Digger"),
    rednet = net.rednetFor(MINER_ID),
    peripheral = peripheralFor(false),
    gps = gpsApi or false,
  })
  local merged = {}
  for k, v in pairs(config) do
    merged[k] = v
  end
  merged.controllerId = HUB_ID
  if merged.useFollower == nil then
    merged.useFollower = true
  end
  local cfg = minerLib.mergeConfig(minerLib.DEFAULT_CONFIG, merged)
  H.check(minerLib.validateConfig(cfg), "invalid co-simulation config")
  local miner = minerLib.createMiner(cfg)
  H.check(miner.openTelemetry(), "miner modem")

  local loader = { active = false }
  local followerEnv = {
    turtle = followerApi,
    os = osFor(FOLLOWER_ID, "Loader"),
    rednet = net.rednetFor(FOLLOWER_ID),
    peripheral = peripheralFor(true, loader),
  }
  local geometry = H.loadProgramEnv(H.SRC .. "/miner.lua", copy(followerEnv))
  local F = H.loadProgramEnv(H.SRC .. "/follower.lua", followerEnv)
  local fcfg = F.mergeConfig({ hubId = HUB_ID, followDistance = opts.followDistance or 6 })
  local follower = F.createFollower(fcfg, geometry, nil)
  H.check(follower.openModem(), "follower modem")

  local Mon = H.loadProgram(H.SRC .. "/minermon.lua")
  local hubNet = net.rednetFor(HUB_ID)
  local app = Mon.createApp(Mock.newScreen(79, 52), {
    now = function()
      return env.clock
    end,
    send = function(to, msg)
      hubNet.send(to, msg, PROTOCOL)
    end,
  })

  local function deliver()
    for id, box in pairs(net.inbox) do
      while #box > 0 do
        local m = table.remove(box, 1)
        if m.protocol == PROTOCOL then
          if id == HUB_ID then
            app.handleMessage(m.from, m.msg)
          elseif id == FOLLOWER_ID then
            follower.handleMessage(m.from, m.msg)
          elseif id == MINER_ID and type(m.msg) == "table" and m.msg.type == "command" then
            miner.handleCommand(tostring(m.msg.cmd), m.from)
          end
        end
      end
    end
  end

  local bands = minerLib.computeBands(cfg.height)
  local result = { distances = {}, minerBlocked = 0, followerMoves = 0 }
  local coMiner = coroutine.create(miner.run)
  local coFollower = coroutine.create(function()
    H.check(follower.start(), "follower start")
    follower.workLoop()
  end)
  -- Event driven: each turtle has its own clock, every action takes 0.4 s
  local busy = { miner = 0, follower = 0 }
  local routines = { miner = coMiner, follower = coFollower }
  env.inScheduler = true
  env.timed = true
  local lastFollower = string.format("%d,%d,%d", followerState.x, followerState.y, followerState.z)
  local parkedOnce = false

  ---@param name string
  local function step(name)
    local co = routines[name]
    local before = env.actions + #env.digs
    env.pendingSleep = 0
    local r = { coroutine.resume(co) }
    if not r[1] then
      env.inScheduler = false
      env.timed = false
      error(r[2], 0)
    end
    if name == "miner" and coroutine.status(co) == "dead" then
      result.minerOk, result.minerState, result.minerMessage = r[2], r[3], r[4]
      result.minerEndClock = env.clock
    end
    local cost = 0.4 * (env.actions + #env.digs - before) + env.pendingSleep
    busy[name] = env.clock + math.max(cost, 0.05)
  end

  for _ = 1, 400000 do
    local alive = {}
    for name, co in pairs(routines) do
      if coroutine.status(co) ~= "dead" then
        alive[#alive + 1] = name
      end
    end
    if #alive == 0 then
      break
    end
    table.sort(alive, function(a, b)
      if busy[a] == busy[b] then
        return a < b
      end
      return busy[a] < busy[b]
    end)
    local name = alive[1]
    env.clock = math.max(env.clock, busy[name])
    if name == "miner" and opts.freezeWhen and not result.freezeStart and opts.freezeWhen(env, miner) then
      -- Simulated chunk unload: the miner stops and sends nothing
      result.freezeStart = env.clock
      result.minerChunkAtFreeze = { x = env.turtle.x, z = env.turtle.z }
    end
    if name == "miner" and result.freezeStart and not result.freezeEnd then
      if env.clock < result.freezeStart + (opts.freezeSeconds or 60) then
        busy.miner = env.clock + 1
        if opts.onFrozen then
          opts.onFrozen(env, result)
        end
      else
        result.freezeEnd = env.clock
      end
    else
      step(name)
    end
    deliver()

    local here = string.format("%d,%d,%d", followerState.x, followerState.y, followerState.z)
    if here ~= lastFollower then
      lastFollower = here
      result.followerMoves = result.followerMoves + 1
      local status = miner.getStatus()
      local prog = { done = status.progress.done, tunnel = status.progress.index, phase = status.progress.phase }
      local atStart = followerState.x == 0 and followerState.y == 0 and followerState.z == -1
      if
        not atStart and not minerLib.isOpenCell(cfg, bands, prog, followerState.x, followerState.y, followerState.z)
      then
        env.inScheduler = false
        env.timed = false
        error("follower entered a cell the miner had not dug: " .. here, 0)
      end
    end
    if coroutine.status(coMiner) ~= "dead" and name == "miner" then
      local status = miner.getStatus()
      if status.state == "mining" then
        local prog = { done = status.progress.done, tunnel = status.progress.index, phase = status.progress.phase }
        if minerLib.isParkingCell(cfg, bands, prog, followerState.x, followerState.y, followerState.z) then
          parkedOnce = true
        end
        if parkedOnce then
          local d = math.abs(env.turtle.x - followerState.x) + math.abs(env.turtle.z - followerState.z)
          result.distances[#result.distances + 1] = d
          if opts.gps then
            -- Facing east: absolute x = start x + job z, absolute z = start z + job x
            local function chunk(x, z)
              return math.floor((opts.gps.x + z) / 16) .. "," .. math.floor((opts.gps.z + x) / 16)
            end
            result.chunkSamples = (result.chunkSamples or 0) + 1
            if chunk(env.turtle.x, env.turtle.z) == chunk(followerState.x, followerState.z) then
              result.sameChunk = (result.sameChunk or 0) + 1
            end
            local mcx = math.floor((opts.gps.x + env.turtle.z) / 16)
            local mcz = math.floor((opts.gps.z + env.turtle.x) / 16)
            local fcx = math.floor((opts.gps.x + followerState.z) / 16)
            local fcz = math.floor((opts.gps.z + followerState.x) / 16)
            if math.abs(mcx - fcx) <= 1 and math.abs(mcz - fcz) <= 1 then
              result.nearChunk = (result.nearChunk or 0) + 1
            end
          end
        end
      end
    end
    if opts.hook then
      opts.hook(env, miner, follower)
    end
    if result.minerEndClock and env.clock > result.minerEndClock + 600 then
      break
    end
  end
  env.timed = false
  env.inScheduler = false
  for _, entry in ipairs(net.log) do
    if type(entry.msg) == "table" and entry.msg.type == "blocked" then
      result.minerBlocked = result.minerBlocked + 1
    end
  end
  result.env, result.cfg, result.follower, result.followerState = env, cfg, follower, followerState
  result.loader, result.app, result.net = loader, app, net
  result.followerDone = coroutine.status(coFollower) == "dead"
  return result
end

---@param result table
---@param label string
---@param maxDistance integer
local function assertCoSim(result, label, maxDistance)
  H.eq(result.minerBlocked, 0, label .. ": the follower should never stand in the miner's way")
  H.check(
    result.minerOk,
    label .. ": miner failed: " .. tostring(result.minerState) .. " " .. tostring(result.minerMessage)
  )
  local okCleared, err = pcall(H.assertCleared, result.env, result.cfg)
  H.check(okCleared, label .. ": " .. tostring(err))
  local okHome, homeErr = pcall(H.assertHome, result.env)
  H.check(okHome, label .. ": " .. tostring(homeErr))
  H.check(result.followerDone, label .. ": follower did not finish")
  local f = result.followerState
  H.eq(f.x .. "/" .. f.y .. "/" .. f.z, "0/0/1", label .. ": follower end position")
  H.eq(result.loader.active, true, label .. ": chunk loader switched on")
  H.check(result.followerMoves > 10, label .. ": follower hardly moved")
  local close = 0
  for _, d in ipairs(result.distances) do
    if d <= maxDistance then
      close = close + 1
    end
  end
  local share = #result.distances > 0 and close / #result.distances or 0
  H.check(
    share >= 0.75,
    string.format("%s: follower was close to the miner only %.0f%% of the time", label, share * 100)
  )
  H.eq(result.env.files["follower.pos"], nil, label .. ": follower files removed")
  H.eq(result.env.files["startup/endermine-follower.lua"], nil, label .. ": follower startup removed")
end

test("follower keeps up with the miner and never blocks it for good", function()
  local result = coSimulate({
    tunnels = 2,
    width = 3,
    height = 3,
    length = 32,
    spacing = 2,
    torchInterval = 6,
    dropJunk = false,
  })
  assertCoSim(result, "3x3", 10)
end)

test("follower on the left side and in taller tunnels", function()
  local result = coSimulate({
    tunnels = 2,
    width = 2,
    height = 6,
    length = 24,
    spacing = 1,
    side = "left",
    torchInterval = 4,
  })
  assertCoSim(result, "left 2x6", 10)
end)

test("with GPS the follower stays in or next to the miner's chunk", function()
  local result = coSimulate({
    tunnels = 3,
    width = 3,
    height = 3,
    length = 48,
    spacing = 3,
    torchInterval = 8,
  }, { gps = { x = 1007, y = 30, z = -1991 } })
  assertCoSim(result, "gps", 12)
  H.check(result.chunkSamples and result.chunkSamples > 100, "chunk samples")
  local near = result.nearChunk / result.chunkSamples
  H.check(near >= 0.95, string.format("follower next to the miner's chunk only %.0f%% of the time", near * 100))
end)

test("follower drives into the chunk of a silent miner", function()
  local origin = { x = 1007, y = 30, z = -1991 }
  -- Facing east: absolute x = origin.x + job z, absolute z = origin.z + job x
  local function chunk(x, z)
    return math.floor((origin.x + z) / 16) .. "," .. math.floor((origin.z + x) / 16)
  end
  local reached = nil
  local result = coSimulate({
    tunnels = 2,
    width = 3,
    height = 3,
    length = 48,
    spacing = 2,
    torchInterval = 8,
  }, {
    gps = origin,
    freezeSeconds = 90,
    freezeWhen = function(env, miner)
      local f = env.turtles[2]
      return miner.getStatus().state == "mining"
        and miner.getStatus().progress.done > 40
        and chunk(env.turtle.x, env.turtle.z) ~= chunk(f.x, f.z)
    end,
    onFrozen = function(env, res)
      local f = env.turtles[2]
      local frozen = res.minerChunkAtFreeze
      -- Next to the miner means its chunk is the follower's or a neighbour
      if not reached and math.abs(f.x - frozen.x) + math.abs(f.z - frozen.z) <= 4 then
        reached = env.clock - res.freezeStart
      end
    end,
  })
  H.check(result.freezeStart, "the situation never occurred")
  H.check(reached, "follower never came close to the silent miner")
  H.check(reached < 60, "follower took too long: " .. tostring(reached))
  H.check(result.minerOk, "miner failed after the freeze: " .. tostring(result.minerMessage))
  H.check(result.followerDone, "follower did not finish")
end)

test("follower with low tunnels waits in finished tunnels", function()
  local result = coSimulate({
    tunnels = 3,
    width = 2,
    height = 2,
    length = 16,
    spacing = 1,
    torchInterval = 4,
  })
  H.check(result.minerOk, "miner failed: " .. tostring(result.minerMessage))
  H.check(result.followerDone, "follower did not finish")
  H.eq(result.followerState.z, 1, "follower ends in front of the miner")
end)

test("hub assigns the follower and relays follow messages", function()
  local result = coSimulate({ tunnels = 1, width = 2, height = 3, length = 10, spacing = 1 })
  local assigned, follows, makeWays = 0, 0, 0
  for _, entry in ipairs(result.net.log) do
    local msg = entry.msg
    if type(msg) == "table" and entry.from == HUB_ID then
      if msg.type == "assign" then
        assigned = assigned + 1
        H.eq(msg.miner, MINER_ID, "assigned miner")
        H.eq(entry.to, FOLLOWER_ID, "assign target")
      elseif msg.type == "follow" then
        follows = follows + 1
        H.eq(entry.to, FOLLOWER_ID, "follow target")
      elseif msg.type == "make_way" then
        makeWays = makeWays + 1
      end
    end
  end
  H.eq(assigned, 1, "exactly one assignment")
  H.check(follows > 5, "follow messages relayed")
  H.eq(makeWays, result.minerBlocked, "every blocked message is relayed")
  H.eq(result.follower.getStatus().follow, MINER_ID, "follower reports its miner")
end)

test("without useFollower the follower is never assigned and stays put", function()
  local result = coSimulate({ tunnels = 1, width = 2, height = 3, length = 10, spacing = 1, useFollower = false })
  H.check(result.minerOk, "miner failed: " .. tostring(result.minerMessage))
  for _, entry in ipairs(result.net.log) do
    local msg = entry.msg
    if type(msg) == "table" and entry.from == HUB_ID then
      H.check(msg.type ~= "assign" and msg.type ~= "follow", "hub must not pair: " .. tostring(msg.type))
    end
    if type(msg) == "table" and entry.from == MINER_ID then
      H.check(msg.type ~= "blocked", "miner must not ask for a follower")
    end
  end
  local f = result.followerState
  H.eq(f.x .. "/" .. f.y .. "/" .. f.z, "0/0/-1", "follower did not move")
  H.eq(result.follower.getStatus().follow, nil, "not paired")
end)

test("a released follower stops following", function()
  local env = Mock.new()
  env.install()
  local geometry = H.loadProgram(H.SRC .. "/miner.lua")
  local F = H.loadProgram(H.SRC .. "/follower.lua")
  local follower = F.createFollower(F.mergeConfig({ hubId = HUB_ID }), geometry, nil)
  local job = { tunnels = 1, width = 3, height = 3, length = 10, spacing = 1, side = "right", torchInterval = 8 }
  H.check(follower.handleMessage(HUB_ID, { type = "assign", miner = MINER_ID }), "assign")
  H.check(
    follower.handleMessage(HUB_ID, {
      type = "follow",
      miner = MINER_ID,
      state = "mining",
      pos = { x = 0, y = 1, z = 5, f = 0 },
      progress = { done = 5, index = 0, phase = "tunnel" },
      job = job,
    }),
    "follow"
  )
  H.eq(follower.getStatus().follow, MINER_ID, "paired")
  H.eq(follower.handleMessage(99, { type = "release", miner = MINER_ID }), false, "only the hub may release")
  H.check(follower.handleMessage(HUB_ID, { type = "release", miner = MINER_ID }), "release")
  H.eq(follower.getStatus().follow, nil, "released")
  local moves = env.moves
  follower.tick()
  H.eq(env.moves, moves, "a released follower does not move")
  H.eq(follower.getStatus().state, "waiting", "waiting state")
end)

tests.coSimulate = coSimulate
return tests
