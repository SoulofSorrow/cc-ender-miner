-- Simulation tests for src/miner.lua

local H = require("helpers")
local Mock = require("mock_cc")

local tests = {}

---@param name string
---@param fn function
local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

test("computeBands covers every height exactly once", function()
  local M = H.loadProgram(H.SRC .. "/miner.lua")
  for height = 1, 20 do
    local covered = {}
    for _, band in ipairs(M.computeBands(height)) do
      H.check(band.center >= band.low and band.center <= band.high, "center outside band")
      H.check(band.high - band.center <= 1 and band.center - band.low <= 1, "band too thick")
      for y = band.low, band.high do
        H.check(not covered[y], "row covered twice")
        covered[y] = true
      end
    end
    for y = 0, height - 1 do
      H.check(covered[y], "row " .. y .. " not covered for height " .. height)
    end
  end
end)

test("validateConfig rejects bad values", function()
  local M = H.loadProgram(H.SRC .. "/miner.lua")
  local ok = M.validateConfig(M.DEFAULT_CONFIG)
  H.check(ok, "defaults must be valid")
  local bad = M.mergeConfig(M.DEFAULT_CONFIG, { width = 0, side = "up", length = 1.5, junkItems = { 3 } })
  local valid, errors = M.validateConfig(bad)
  H.check(not valid, "bad config accepted")
  H.eq(#errors, 4, "error count")
  local unknown = M.mergeConfig(M.DEFAULT_CONFIG, { evil = true, controllerId = 12 })
  H.eq(unknown.evil, nil, "unknown keys must be ignored")
  H.eq(unknown.controllerId, 12, "controllerId")
end)

test("config round trip through fs", function()
  local env = Mock.new()
  env.install()
  local M = H.loadProgram(H.SRC .. "/miner.lua")
  local cfg = M.mergeConfig(M.DEFAULT_CONFIG, { tunnels = 5, side = "left", controllerId = 3 })
  M.saveConfig("miner.cfg", cfg)
  local loaded, err = M.loadConfig("miner.cfg")
  H.check(loaded, "load failed: " .. tostring(err))
  H.eq(loaded.tunnels, 5, "tunnels")
  H.eq(loaded.side, "left", "side")
  H.eq(loaded.controllerId, 3, "controllerId")
  env.files["broken.cfg"] = "{ width = -4 }"
  local broken, brokenErr = M.loadConfig("broken.cfg")
  H.eq(broken, nil, "invalid config must not load")
  H.check(brokenErr:find("width"), "error should mention width")
  env.files["garbage.cfg"] = "not lua at all"
  H.eq((M.loadConfig("garbage.cfg")), nil, "garbage config")
  H.eq((M.loadConfig("missing.cfg")), nil, "missing config")
end)

test("default job clears all tunnels, unloads and returns home", function()
  local env, miner, cfg = H.setup({ config = { dropJunk = false } })
  local ok, state, msg = miner.run()
  H.check(ok, "run failed: " .. tostring(state) .. " " .. tostring(msg))
  H.eq(state, "done", "final state")
  H.assertCleared(env, cfg)
  H.assertHome(env)
  H.assertChests(env)
  local status = miner.getStatus()
  H.eq(status.progress.done, status.progress.total, "progress complete")
  H.check(status.dumps >= 2, "expected several unloads, got " .. status.dumps)
  H.check(env.chestCount("resources", "minecraft:cobblestone") > 1000, "cobblestone not in resource chest")
  H.check(env.chestCount("resources", "minecraft:coal") > 0, "coal not in resource chest")
  for i = 5, 16 do
    H.eq(env.turtle.inv[i], nil, "loot slot " .. i .. " should be empty at the end")
  end
  local lost = 0
  for _, entry in ipairs(env.dropped) do
    if entry.lost then
      lost = lost + entry.count
    end
  end
  H.eq(lost, 0, "items lost because of a full inventory")
  H.check(H.countExtraDigs(env, cfg) <= status.dumps + status.resupplies, "too many blocks dug outside the tunnels")
end)

test("torches are placed at the configured interval", function()
  local env, miner, cfg = H.setup({ config = { length = 40, torchInterval = 8, tunnels = 2 } })
  local ok = miner.run()
  H.check(ok, "run failed")
  for tunnel = 0, cfg.tunnels - 1 do
    local x = tunnel * (cfg.width + cfg.spacing)
    for z = 2, cfg.length do
      local expected = z % cfg.torchInterval == 0
      local actual = env.get(x, 0, z) == "minecraft:torch"
      H.eq(actual, expected, string.format("torch at %d/0/%d", x, z))
    end
  end
  H.eq(miner.getStatus().torchesPlaced, 10, "torches placed")
end)

test("odd sizes on both sides", function()
  local shapes = {
    { width = 1, height = 1 },
    { width = 1, height = 2 },
    { width = 2, height = 4 },
    { width = 4, height = 5 },
    { width = 3, height = 7 },
    { width = 2, height = 3, spacing = 0 },
  }
  for _, side in ipairs({ "right", "left" }) do
    for _, shape in ipairs(shapes) do
      local config = {
        width = shape.width,
        height = shape.height,
        spacing = shape.spacing or 1,
        length = 9,
        tunnels = 2,
        side = side,
        torchInterval = 4,
      }
      local env, miner, cfg = H.setup({ config = config })
      local ok, state, msg = miner.run()
      local label = string.format("%s %dx%d", side, shape.width, shape.height)
      H.check(ok, label .. " failed: " .. tostring(state) .. " " .. tostring(msg))
      H.assertCleared(env, cfg)
      H.assertHome(env)
      H.assertChests(env)
      H.eq(H.countExtraDigs(env, cfg) <= 2, true, label .. " extra digs")
    end
  end
end)

test("junk is dropped instead of unloaded", function()
  local env, miner = H.setup({ config = { dropJunk = true } })
  H.check(miner.run(), "run failed")
  H.eq(env.chestCount("resources", "minecraft:cobblestone"), 0, "cobblestone must not reach the chest")
  H.check(env.chestCount("resources", "minecraft:coal") > 0, "ores must reach the chest")
  H.check(miner.getStatus().junkDropped > 1000, "junk counter")
end)

test("torches are restocked from the supply chest", function()
  local env, miner = H.setup({
    torches = 0,
    config = { length = 96, torchInterval = 4, tunnels = 3 },
    supply = { { "minecraft:torch", 20 }, { "minecraft:torch", 64 }, { "minecraft:torch", 64 } },
  })
  H.check(miner.run(), "run failed")
  local status = miner.getStatus()
  H.eq(status.torchesPlaced, 72, "torches placed")
  H.check(status.resupplies >= 2, "expected several resupplies")
  H.eq(env.chestCount("supply") + status.torchesPlaced + env.turtle.inv[3].count, 148, "no torch may get lost")
  H.assertChests(env)
end)

test("supply chest is not polluted with mined blocks", function()
  local env, miner = H.setup({
    torches = 0,
    config = { tunnels = 1, length = 16, torchInterval = 4 },
    supply = { { "minecraft:torch", 64 } },
  })
  H.check(miner.run(), "run failed")
  for _, stack in pairs(env.chests.supply) do
    H.eq(stack.name, "minecraft:torch", "only torches may be in the supply chest")
  end
end)

test("fuel behind a stack of torches is reachable", function()
  local env, miner = H.setup({
    mock = { fuel = 0 },
    supply = { { "minecraft:torch", 64 }, { "minecraft:torch", 64 }, { "minecraft:coal", 64 } },
    config = { tunnels = 1, length = 8, refuelFromLoot = false },
  })
  local ok, state, msg = miner.run()
  H.check(ok, "run failed: " .. tostring(state) .. " " .. tostring(msg))
  H.check(env.chestCount("supply", "minecraft:coal") < 64, "coal was not taken")
  -- The torch slot starts full, so both torch stacks have to go back
  H.eq(env.chestCount("supply", "minecraft:torch"), 128, "unused torches must go back into the chest")
end)

test("detour home around an unbreakable block", function()
  local env, miner = H.setup({
    mock = {
      generator = function(x, y, z)
        if x == 1 and y == 1 and z == 6 then
          return "minecraft:bedrock"
        end
        return "minecraft:stone"
      end,
    },
    config = { tunnels = 1, width = 3, length = 10 },
  })
  local ok = miner.run()
  H.check(not ok, "run should fail at the bedrock")
  H.assertHome(env)
end)

test("fuel is pulled from the supply chest", function()
  local env, miner, cfg = H.setup({
    mock = { fuel = 0 },
    supply = { { "minecraft:coal", 64 }, { "minecraft:coal", 64 } },
    config = { refuelFromLoot = false },
  })
  local ok, state, msg = miner.run()
  H.check(ok, "run failed: " .. tostring(state) .. " " .. tostring(msg))
  H.assertCleared(env, cfg)
  H.check(env.chestCount("supply", "minecraft:coal") < 128, "coal was not taken")
end)

test("waits for fuel and continues once refuelled", function()
  local env, miner = H.setup({ mock = { fuel = 0, modem = true }, supply = {} })
  H.check(miner.openTelemetry(), "telemetry should open")
  local fed = false
  env.hooks.sleep = function(e)
    if not fed and e.sleeps >= 3 then
      fed = true
      e.give(4, "minecraft:coal_block", 16)
    end
  end
  local ok = miner.run()
  H.check(ok, "run failed")
  H.check(fed, "turtle never waited")
  local sawNoFuel = false
  for _, entry in ipairs(env.broadcasts) do
    if entry.msg.type == "status" and entry.msg.state == "no_fuel" then
      sawNoFuel = true
    end
    H.eq(entry.protocol, "endermine.v1", "protocol")
  end
  H.check(sawNoFuel, "no_fuel status was never reported")
end)

test("burns mined coal when the fuel runs low", function()
  local env, miner = H.setup({
    mock = {
      fuel = 400,
      generator = function(x, y, z)
        if (x + y + z) % 3 == 0 then
          return "minecraft:coal_ore"
        end
        return "minecraft:stone"
      end,
    },
    supply = { { "minecraft:torch", 64 } },
    config = { fuelReserve = 50, fuelBuffer = 200 },
  })
  local ok, state, msg = miner.run()
  H.check(ok, "run failed: " .. tostring(state) .. " " .. tostring(msg))
  H.check(env.turtle.fuel > 0, "fuel should not be empty")
end)

test("waits while the resource chest is full", function()
  local env, miner = H.setup({ config = { dropJunk = false, tunnels = 1 } })
  env.chestCapacity = 4
  local cleared = 0
  env.hooks.sleep = function(e)
    cleared = cleared + 1
    e.chests.resources = {}
  end
  H.check(miner.run(), "run failed")
  H.check(cleared > 0, "turtle never waited for chest space")
  H.assertChests(env)
end)

test("telemetry status payload is complete", function()
  local env, miner = H.setup({ mock = { modem = true, label = "Digger" }, config = { tunnels = 1, length = 8 } })
  H.check(miner.openTelemetry(), "telemetry")
  H.check(miner.run(), "run failed")
  local status = env.lastBroadcast("status")
  H.check(status, "no status broadcast")
  H.eq(status.label, "Digger", "label")
  H.eq(status.state, "done", "state")
  H.eq(status.inventory.total, 12, "inventory slots")
  H.check(type(status.ores) == "table" and #status.ores > 0, "ores missing")
  H.check(type(status.job) == "table", "job missing")
  H.check(env.lastBroadcast("event"), "no event broadcast")
end)

test("controller id sends directly", function()
  local env, miner = H.setup({ mock = { modem = true }, config = { tunnels = 1, length = 4, controllerId = 42 } })
  miner.openTelemetry()
  H.check(miner.run(), "run failed")
  H.eq(#env.broadcasts, 0, "no broadcasts with controllerId")
  H.check(#env.sent > 0 and env.sent[1].id == 42, "direct send to controller")
end)

test("home command aborts and returns", function()
  local env, miner, cfg = H.setup({ mock = { modem = true } })
  miner.openTelemetry()
  env.hooks.move = function(e)
    if e.moves == 150 then
      e.queueMessage(99, { type = "command", cmd = "home" }, "endermine.v1")
    end
  end
  local result = {}
  parallel.waitForAny(function()
    result = { miner.run() }
  end, miner.commandLoop)
  H.eq(result[2], "aborted", "final state")
  H.assertHome(env)
  H.assertChests(env)
  H.check(miner.getStatus().progress.done < miner.getStatus().progress.total, "should stop early")
  H.check(env.moves < 400, "should not keep mining")
  H.eq(cfg.tunnels, 3, "config untouched")
end)

test("commands for other turtles or from strangers are ignored", function()
  local env, miner = H.setup({ mock = { modem = true }, config = { tunnels = 1, length = 10, controllerId = 5 } })
  miner.openTelemetry()
  env.hooks.move = function(e)
    if e.moves == 10 then
      e.queueMessage(5, { type = "command", cmd = "home", target = 1234 }, "endermine.v1")
      e.queueMessage(6, { type = "command", cmd = "home" }, "endermine.v1")
      e.queueMessage(5, { type = "command", cmd = "home" }, "other.protocol")
      e.queueMessage(5, "garbage", "endermine.v1")
    end
  end
  local result = {}
  parallel.waitForAny(function()
    result = { miner.run() }
  end, miner.commandLoop)
  H.eq(result[2], "done", "foreign commands must be ignored")
end)

test("pause and resume", function()
  local env, miner = H.setup({ mock = { modem = true }, config = { tunnels = 1, length = 12 } })
  miner.openTelemetry()
  env.hooks.move = function(e)
    if e.moves == 20 then
      e.queueMessage(3, { type = "command", cmd = "pause" }, "endermine.v1")
    end
  end
  local resumed = false
  env.hooks.sleep = function(e)
    if not resumed and e.sleeps >= 10 then
      resumed = true
      e.queueMessage(3, { type = "command", cmd = "resume" }, "endermine.v1")
    end
  end
  local result = {}
  parallel.waitForAny(function()
    result = { miner.run() }
  end, miner.commandLoop)
  H.eq(result[2], "done", "final state")
  H.check(resumed, "never paused")
  local sawPaused = false
  for _, entry in ipairs(env.broadcasts) do
    if entry.msg.type == "status" and entry.msg.state == "paused" then
      sawPaused = true
    end
  end
  H.check(sawPaused, "paused state not reported")
end)

test("unbreakable block stops the job and returns home", function()
  local env, miner = H.setup({
    mock = {
      generator = function(x, y, z)
        if x == 1 and y == 1 and z == 6 then
          return "minecraft:bedrock"
        end
        return "minecraft:stone"
      end,
    },
  })
  local ok, state, msg = miner.run()
  H.check(not ok, "run should fail")
  H.eq(state, "error", "state")
  H.check(msg:find("unbreakable"), "message should mention the block: " .. msg)
  H.assertHome(env)
  H.assertChests(env)
end)

test("falling gravel is cleared", function()
  local env, miner, cfg = H.setup({
    mock = {
      generator = function(x, y, z)
        if y >= 2 and y <= 6 and (x + z) % 4 == 0 then
          return "minecraft:gravel"
        end
        return "minecraft:stone"
      end,
    },
    config = { tunnels = 2, length = 16 },
  })
  local ok, state, msg = miner.run()
  H.check(ok, "run failed: " .. tostring(state) .. " " .. tostring(msg))
  H.assertCleared(env, cfg)
  H.assertHome(env)
end)

test("vanilla ender chests are rejected before moving", function()
  local env, miner = H.setup({ slot1 = { "minecraft:ender_chest", 1 } })
  local ok, state, msg = miner.run()
  H.check(not ok, "must fail")
  H.eq(state, "error", "state")
  H.check(msg:find("EnderStorage"), "message: " .. msg)
  H.eq(env.moves, 0, "must not move")
end)

test("missing chest is reported", function()
  local env, miner = H.setup({})
  env.turtle.inv[2] = nil
  local ok, state = miner.run()
  H.check(not ok and state == "error", "must fail without resource chest")
  H.eq(env.moves, 0, "must not move")
end)

test("unlimited fuel works", function()
  local env, miner, cfg = H.setup({ mock = { unlimited = true }, config = { tunnels = 1, length = 6 } })
  H.check(miner.run(), "run failed")
  H.assertCleared(env, cfg)
  local status = miner.getStatus()
  H.eq(status.fuel, -1, "unlimited fuel encoded as -1")
end)

test("foreign items in torch and fuel slots are moved away", function()
  local env, miner = H.setup({ torches = 0, config = { tunnels = 1, length = 8 } })
  env.give(3, "minecraft:dirt", 5)
  env.give(4, "minecraft:stick", 3)
  H.check(miner.run(), "run failed")
  H.check(env.turtle.inv[3] and env.turtle.inv[3].name == "minecraft:torch", "slot 3 should hold torches")
  H.check(env.turtle.inv[4] == nil or env.turtle.inv[4].name ~= "minecraft:stick", "slot 4 cleaned")
end)

test("lava ahead stops the job and returns home", function()
  local env, miner = H.setup({
    mock = {
      generator = function(x, y, z)
        if x == 1 and y == 1 and z == 6 then
          return "minecraft:lava"
        end
        return "minecraft:stone"
      end,
    },
  })
  local ok, state, msg = miner.run()
  H.check(not ok, "run should fail")
  H.eq(state, "error", "state")
  H.check(msg:find("lava"), "message should mention lava: " .. msg)
  H.eq(env.get(1, 1, 6), "minecraft:lava", "lava must stay untouched")
  H.assertHome(env)
end)

test("home command interrupts the wait for fuel", function()
  local env, miner = H.setup({ mock = { fuel = 0, modem = true }, supply = {} })
  miner.openTelemetry()
  local sent = false
  env.hooks.sleep = function(e)
    if not sent and e.sleeps >= 3 then
      sent = true
      e.queueMessage(99, { type = "command", cmd = "home" }, "endermine.v1")
    end
  end
  local result = {}
  parallel.waitForAny(function()
    result = { miner.run() }
  end, miner.commandLoop)
  H.check(sent, "turtle never waited for fuel")
  H.eq(result[2], "aborted", "final state")
end)

test("commands need the shared secret when one is configured", function()
  local env, miner = H.setup({
    mock = { modem = true },
    config = { tunnels = 1, length = 30, secret = "pairing-code" },
  })
  miner.openTelemetry()
  env.hooks.move = function(e)
    if e.moves == 10 then
      e.queueMessage(5, { type = "command", cmd = "home" }, "endermine.v1")
      e.queueMessage(5, { type = "command", cmd = "home", secret = "wrong" }, "endermine.v1")
    elseif e.moves == 40 then
      e.queueMessage(5, { type = "command", cmd = "home", secret = "pairing-code" }, "endermine.v1")
    end
  end
  local result = {}
  parallel.waitForAny(function()
    result = { miner.run() }
  end, miner.commandLoop)
  H.eq(result[2], "aborted", "only the command with the secret may abort the job")
  H.check(env.moves > 40, "commands without the secret must be ignored")
end)

test("secret validation", function()
  local M = H.loadProgram(H.SRC .. "/miner.lua")
  H.check(M.validateConfig(M.mergeConfig(M.DEFAULT_CONFIG, { secret = "x" })), "plain secret must be valid")
  H.check(not M.validateConfig(M.mergeConfig(M.DEFAULT_CONFIG, { secret = "" })), "empty secret")
  H.check(not M.validateConfig(M.mergeConfig(M.DEFAULT_CONFIG, { secret = 5 })), "numeric secret")
end)

test("unknown config keys are reported", function()
  local env = Mock.new()
  env.install()
  local M = H.loadProgram(H.SRC .. "/miner.lua")
  local _, unknown = M.mergeConfig(M.DEFAULT_CONFIG, { tunel = 2, width = 2, evil = true })
  H.eq(table.concat(unknown, ","), "evil,tunel", "unknown keys")
  env.files["typo.cfg"] = "{ tunel = 2 }"
  local cfg, err, ignored = M.loadConfig("typo.cfg")
  H.check(cfg, "config with typos still loads: " .. tostring(err))
  H.eq(ignored[1], "tunel", "ignored key")
end)

test("an incomplete write keeps the last good file", function()
  local env = Mock.new()
  env.install()
  local store = require("endermine.store")
  H.check(store.writeAtomic("data.txt", "old content"), "first write")
  local realOpen = fs.open
  fs.open = function(path, mode)
    local handle, err = realOpen(path, mode)
    if mode == "w" and handle then
      return {
        write = function(text)
          handle.write(text:sub(1, #text - 3))
        end,
        close = handle.close,
      }
    end
    return handle, err
  end
  local ok, err = store.writeAtomic("data.txt", "new content")
  fs.open = realOpen
  H.check(not ok, "truncated write must be reported")
  H.check(err ~= nil, "error text expected")
  H.eq(env.files["data.txt"], "old content", "last good file")
  H.eq(env.files["data.txt.new"], nil, "temporary file must be removed")
end)

test("progress saves are throttled but the journal keeps the cell count", function()
  local env, miner = H.setup({ config = { tunnels = 1, length = 24, useTorches = false } })
  local writes = 0
  local realOpen = fs.open
  fs.open = function(path, mode)
    if mode == "w" and path == "miner.state.new" then
      writes = writes + 1
    end
    return realOpen(path, mode)
  end
  local ok = miner.run()
  fs.open = realOpen
  H.check(ok, "run failed")
  local cells = miner.getStatus().progress.total
  H.check(writes < cells / 2, string.format("%d progress saves for %d cells", writes, cells))
  H.eq(env.files["miner.state"], nil, "job files are removed at the end")
end)

return tests
