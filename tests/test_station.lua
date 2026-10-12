-- Tests for the station and the dock mode of the miner

local H = require("helpers")
local Mock = require("mock_cc")
local Ores = require("test_ores")

local tests = {}

---@param name string
---@param fn function
local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local START_Y = 64
local SCANNER = "advancedperipherals:geo_scanner"
local DISK = "disk"
local DOCK_FILES = DISK .. "/endermine/"

--- Load the programs fresh, like a computer after a reboot.
---@return table station module
---@return table lib miner module
local function loadModules()
  local lib = H.loadProgram(H.SRC .. "/miner.lua")
  local S = H.loadProgram(H.SRC .. "/station.lua")
  return S, lib
end

---@param env table
---@param S table
---@param lib table
---@return table station
local function newStation(env, S, lib)
  return S.createStation({
    disk = DISK,
    lib = lib,
    dbPath = "station.db",
    now = function()
      return env.clock
    end,
  })
end

---@param env table
---@param name string
---@param data table
local function writeDisk(env, name, data)
  env.dirs[DISK] = true
  env.dirs[DISK .. "/endermine"] = true
  env.files[DOCK_FILES .. name] = Mock.serialize(data)
end

---@param env table
---@param name string
---@return table|nil
local function readDisk(env, name)
  local text = env.files[DOCK_FILES .. name]
  if text == nil then
    return nil
  end
  return Mock.unserialize(text)
end

---@param station table
---@return string
local function statuses(station)
  local parts = {}
  for _, job in ipairs(station.getJobs()) do
    parts[#parts + 1] = job.id .. "=" .. job.status
  end
  return table.concat(parts, " ")
end

--- World with a dock: chest above (output), chest below (fuel), disk drive
--- behind the turtle.
---@param mock table|nil
---@return table env
---@return string output Inventory name of the chest above
---@return string fuel Inventory name of the chest below
local function dockWorld(mock)
  mock = mock or {}
  mock.generator = mock.generator or Ores.oreWorld
  mock.requireTool = true
  mock.worldDir = mock.worldDir or "east"
  mock.fuel = mock.fuel or 20000
  local env = Mock.new(mock)
  env.install()
  env.give(1, Mock.CHEST, 1, "supply")
  env.give(2, Mock.CHEST, 1, "resources")
  env.give(3, SCANNER, 1)
  env.fillChest("supply", { { "minecraft:coal", 64 } })
  env.fillChest("resources", {})
  local output = env.placeChest(0, 1, 0)
  local fuel = env.placeChest(0, -1, 0, { { "minecraft:coal", 64 } })
  env.set(0, 0, -1, "computercraft:disk_drive")
  env.drive = { mount = DISK }
  return env, output, fuel
end

---@param env table
local function assertDockIntact(env)
  H.eq(env.get(0, 1, 0), Mock.PLAIN_CHEST, "output chest above the dock")
  H.eq(env.get(0, -1, 0), Mock.PLAIN_CHEST, "fuel chest below the dock")
  H.eq(env.get(0, 0, -1), "computercraft:disk_drive", "disk drive behind the dock")
end

---@param env table
local function assertUnloaded(env)
  for slot = 5, 16 do
    local stack = env.turtle.inv[slot]
    H.check(stack == nil, "slot " .. slot .. " must be empty after unloading, has " .. tostring(stack and stack.name))
  end
end

--- Every ore in the level bands of a job area must be gone.
---@param env table
---@param lib table
---@param config table Job configuration from the station
---@return integer ores
local function assertAreaMined(env, lib, config)
  local count = 0
  for _, band in ipairs(lib.oreLevelBands(config.oreLevels, 8)) do
    for absY = band.low, band.high do
      local y = absY - config.startY
      for ax = 0, config.areaWidth - 1 do
        for az = 1, config.areaLength do
          local x, z = config.areaOffsetX + ax, config.areaOffsetZ + az
          if Ores.oreWorld(x, y, z):find("_ore$") then
            count = count + 1
          end
          local block = env.get(x, y, z)
          if block:find("_ore$") then
            error(string.format("ore %s left at %d/%d/%d", block, x, y, z), 2)
          end
        end
      end
    end
  end
  return count
end

test("areas are handed out in a spiral without gaps or repeats", function()
  local env = Mock.new()
  env.install()
  local S = loadModules()
  local seen = {}
  for r = 0, 6 do
    local cells = S.ring(r)
    H.eq(#cells, r == 0 and 1 or 8 * r, "cells in ring " .. r)
    for i, cell in ipairs(cells) do
      H.eq(math.max(math.abs(cell[1]), math.abs(cell[2])), r, "cell in ring " .. r)
      local id = cell[1] .. "," .. cell[2]
      H.check(not seen[id], "cell " .. id .. " given out twice")
      seen[id] = true
      if i > 1 then
        local prev = cells[i - 1]
        H.eq(math.abs(prev[1] - cell[1]) + math.abs(prev[2] - cell[2]), 1, "ring " .. r .. " walks cell by cell")
      end
    end
  end
  for i = -6, 6 do
    for j = -6, 6 do
      H.check(seen[i .. "," .. j], "cell " .. i .. "," .. j .. " missing")
    end
  end
end)

test("jobs move from queued to done through the disk", function()
  local env = Mock.new()
  env.install()
  local S, lib = loadModules()
  local station = newStation(env, S, lib)
  local ok, err = station.addJobs({ 16 }, 1, 18)
  H.check(not ok and err:find("Y"), "jobs need the dock Y first")
  station.setStartY(START_Y)
  ok, err = station.addJobs({}, 1, 18)
  H.check(not ok and err:find("level"), "jobs need a level")
  ok = station.addJobs({ 999 }, 1, 18)
  H.check(not ok, "levels outside the world are rejected")
  H.eq(#station.getJobs(), 0, "nothing queued by invalid requests")

  H.check(station.addJobs({ 16, -57 }, 3, 18), "queue three jobs")
  H.eq(statuses(station), "1=queued 2=queued 3=queued", "queued")
  station.poll()
  H.eq(statuses(station), "1=sent 2=queued 3=queued", "first job sent")
  local job = readDisk(env, "job")
  H.eq(job.id, 1, "job on the disk")
  H.eq(job.config.mode, "ores", "ore mode")
  H.eq(job.config.startY, START_Y, "start Y")
  H.eq(table.concat(job.config.oreLevels, ","), "16,-57", "levels")
  H.eq(#job.config.oreGroups, 0, "every ore by default")
  H.eq(#job.config.oreNames, 0, "a filter in miner.cfg does not apply to station jobs")
  H.eq(job.config.areaOffsetX .. "," .. job.config.areaOffsetZ, "0,0", "first area at the dock")
  local cfg = lib.mergeConfig(lib.DEFAULT_CONFIG, job.config)
  H.check(lib.validateConfig(cfg), "job config is valid for the miner")

  -- Not taken yet: the disk keeps the job
  station.poll()
  H.eq(readDisk(env, "job").id, 1, "job stays until it is taken")

  writeDisk(env, "ack", { id = 1, turtle = 7, at = 1 })
  writeDisk(env, "report", { state = "working", jobId = 1, at = 1 })
  station.poll()
  H.eq(statuses(station), "1=running 2=sent 3=queued", "taken job runs, next one waits on the disk")
  local second = readDisk(env, "job")
  H.eq(second.id, 2, "second job on the disk")
  H.eq(second.config.areaOffsetX .. "," .. second.config.areaOffsetZ, "18,0", "second area east of the first")

  -- The station only reads the disk after the turtle reported "idle" again
  writeDisk(env, "report", {
    state = "idle",
    jobId = 1,
    at = 2,
    result = { jobId = 1, state = "done", message = "ok", stats = { mined = 5 } },
  })
  station.poll()
  H.eq(statuses(station), "1=done 2=sent 3=queued", "result read from the idle report")
  H.eq(station.getJobs()[1].result.stats.mined, 5, "result stored")

  H.eq(station.cancelLast(), 3, "newest queued job cancelled")
  H.eq(station.cancelLast(), 2, "sent but untaken job cancelled")
  H.eq(readDisk(env, "job"), nil, "cancelled job removed from the disk")
  H.eq(station.cancelLast(), nil, "nothing left to cancel")

  H.check(station.addJobs({ 16 }, 1, 18), "queue again")
  local jobs = station.getJobs()
  H.eq(jobs[4].cell[1] .. "," .. jobs[4].cell[2], "1,0", "area of a cancelled job is given out again")
  station.poll()
  H.eq(readDisk(env, "job").id, 4, "new job on the disk")

  -- A job the turtle took before the cancel cannot be cancelled
  writeDisk(env, "ack", { id = 4, turtle = 7, at = 3 })
  H.eq(station.cancelLast(), nil, "taken job is not cancelled")
  H.eq(jobs[4].status, "running", "taken job runs")

  writeDisk(env, "report", {
    state = "idle",
    jobId = 4,
    at = 4,
    result = { jobId = 4, state = "lost", message = "position unknown" },
  })
  station.poll()
  H.eq(jobs[4].status, "error", "failed job")

  local again = newStation(env, S, lib)
  H.eq(again.getStartY(), START_Y, "dock Y persisted")
  H.eq(statuses(again), "1=done 2=cancelled 3=cancelled 4=error", "jobs persisted")
end)

test("touch screens on a large monitor and a small screen", function()
  for _, size in ipairs({ { 79, 52 }, { 36, 24 }, { 51, 19 } }) do
    local w, h = size[1], size[2]
    local env = Mock.new()
    env.install()
    local S, lib = loadModules()
    local station = newStation(env, S, lib)
    local screen = Mock.newScreen(w, h)
    local label = w .. "x" .. h

    --- Search from the bottom, where the buttons are.
    ---@param text string
    ---@return integer|nil x
    ---@return integer|nil y
    local function find(text)
      for row = h, 1, -1 do
        local col = screen.rows[row]:find(text, 1, true)
        if col then
          return col, row
        end
      end
      return nil, nil
    end

    ---@param text string
    local function tap(text)
      local x, y = find(text)
      H.check(x, label .. ": button '" .. text .. "' not on the screen")
      H.check(station.handleTouch(x, y), label .. ": '" .. text .. "' did not react")
      station.render(screen)
    end

    station.render(screen)
    H.check(find("ENDER STATION"), label .. ": title")
    H.check(find("No jobs yet"), label .. ": empty job list")
    tap("NEW JOB")
    H.eq(station.getScreen(), "main", label .. ": no new job without the dock Y")
    H.check(find("dock Y"), label .. ": hint about the dock Y")

    station.setStartY(START_Y)
    tap("NEW JOB")
    H.eq(station.getScreen(), "new", label .. ": new job screen")
    tap("CREATE")
    H.check(find("choose at least one level"), label .. ": a level is needed")
    tap("Iron")
    H.check(find("ORES: all"), label .. ": every ore by default")
    tap("ORES: all")
    H.eq(station.getScreen(), "ores", label .. ": ore screen")
    H.check(find("Emerald"), label .. ": vanilla ores listed")
    tap("Diamond")
    tap("Redstone")
    tap("Redstone")
    tap("DONE")
    H.eq(station.getScreen(), "new", label .. ": back to the job")
    H.check(find("ORES: diamond"), label .. ": chosen ore shown")
    H.check(find("Diamond + redstone Y-57"), label .. ": preset still listed")
    -- Own level 16 - 20 = -4
    tap("--")
    tap("--")
    tap("OFF")
    H.check(find("  -4"), label .. ": own level shown")
    local _, sizeRow = find("Area size")
    local plus = screen.rows[sizeRow]:find("+", 1, true)
    H.check(station.handleTouch(plus, sizeRow), label .. ": size +")
    station.render(screen)
    H.check(find("54x54"), label .. ": size shown")
    local _, countRow = find("Areas")
    plus = screen.rows[countRow]:find("+", 1, true)
    H.check(station.handleTouch(plus, countRow), label .. ": count +")
    station.render(screen)
    tap("CREATE")
    H.eq(station.getScreen(), "main", label .. ": back on the main screen")
    local jobs = station.getJobs()
    H.eq(#jobs, 2, label .. ": two jobs")
    H.eq(table.concat(jobs[1].levels, ","), "-57,16,-4", label .. ": level of the chosen ore, preset and own level")
    H.eq(table.concat(jobs[1].ores, ","), "diamond", label .. ": ore kinds")
    H.eq(table.concat(station.jobConfig(jobs[1]).oreGroups, ","), "diamond", label .. ": sent to the turtle")
    H.eq(jobs[1].size, 54, label .. ": size")
    H.eq(jobs[1].status, "sent", label .. ": first job written to the disk at once")
    H.check(find("#2"), label .. ": job list")
    H.check(find("2 job(s) queued"), label .. ": message")
    tap("CANCEL")
    H.eq(jobs[2].status, "cancelled", label .. ": cancel from the screen")
    tap("NEW JOB")
    H.check(find("ORES: all"), label .. ": choice reset after a job")
    H.check(find("OFF"), label .. ": own level reset after a job")
    for row = 1, h do
      H.eq(#screen.rows[row], w, label .. ": row " .. row .. " width")
    end
  end
end)

---@param lib table
---@param options table|nil
---@return string reason
local function runDock(lib, options)
  local base = lib.mergeConfig(lib.DEFAULT_CONFIG, { dropJunk = true })
  return lib.runDock(base, options)
end

test("the docked turtle mines the queued areas one after the other", function()
  local env, output = dockWorld()
  local S, lib = loadModules()
  local station = newStation(env, S, lib)
  station.setStartY(START_Y)
  H.check(station.addJobs({ 16 }, 2, 18), "queue two jobs")
  local digsAt = {}
  local reason = runDock(lib, {
    maxIdle = 1,
    onPoll = function()
      station.poll()
      digsAt[#digsAt + 1] = #env.digs
    end,
  })
  H.eq(reason, "idle", "dock waits for more jobs at the end")
  H.eq(statuses(station), "1=done 2=done", "both jobs done")
  H.check(env.files["startup/endermine-dock.lua"], "dock mode resumes after a reboot")
  H.eq(env.files["startup/endermine.lua"], nil, "no single job startup in dock mode")
  H.assertJobCleared(env)
  H.assertHome(env)
  assertDockIntact(env)
  assertUnloaded(env)
  H.check(env.chestCount(output) > 0, "the mined blocks are in the chest above")

  local jobs = station.getJobs()
  local total = 0
  for _, job in ipairs(jobs) do
    total = total + assertAreaMined(env, lib, station.jobConfig(job))
  end
  H.check(total > 10, "the areas should contain ores, got " .. total)
  -- The first job never touches the second area
  for i = digsAt[1] + 1, digsAt[2] do
    local dug = env.digs[i]
    H.check(dug.x < 18, string.format("job 1 dug at %d/%d/%d inside area 2", dug.x, dug.y, dug.z))
  end
  local report = readDisk(env, "report")
  H.eq(report.state, "idle", "turtle waits")
  H.eq(report.result.jobId, 2, "last result")
  H.check(type(report.result.stats.mined) == "number", "stats of the last job")
  H.eq(env.turtle.inv[3] and env.turtle.inv[3].name, SCANNER, "scanner back in its slot")
end)

test("a reboot during a dock job resumes it and continues with the queue", function()
  local probeEnv = dockWorld()
  local S, lib = loadModules()
  local probe = newStation(probeEnv, S, lib)
  probe.setStartY(START_Y)
  probe.addJobs({ 16 }, 1, 18)
  runDock(lib, { maxIdle = 1, onPoll = probe.poll })
  local actions = probeEnv.actions
  H.check(actions > 100, "profile too short: " .. actions)

  for _, point in ipairs({ { 25, false }, { math.floor(actions / 2), true }, { actions - 15, false } }) do
    local env, output = dockWorld()
    S, lib = loadModules()
    local station = newStation(env, S, lib)
    station.setStartY(START_Y)
    station.addJobs({ 16 }, 2, 18)
    env.kill = { at = point[1], after = point[2] }
    local co = coroutine.create(function()
      return runDock(lib, { maxIdle = 1, onPoll = station.poll })
    end)
    local okRun, yielded = coroutine.resume(co)
    H.check(okRun, tostring(yielded))
    H.eq(yielded, "__kill", "unload at action " .. point[1])
    H.check(env.files["startup/endermine-dock.lua"], "dock startup present after the unload")

    -- "miner dock" again after the reboot
    env.kill = nil
    env.killed = false
    env.turtle.sel = 1
    S, lib = loadModules()
    station = newStation(env, S, lib)
    local reason = runDock(lib, { maxIdle = 1, onPoll = station.poll })
    local label = "unload at " .. point[1]
    H.eq(reason, "idle", label .. ": dock waits at the end")
    H.eq(statuses(station), "1=done 2=done", label .. ": both jobs done")
    for _, job in ipairs(station.getJobs()) do
      assertAreaMined(env, lib, station.jobConfig(job))
    end
    H.assertJobCleared(env)
    H.assertHome(env)
    assertDockIntact(env)
    assertUnloaded(env)
    H.check(env.chestCount(output) > 0, label .. ": output chest filled")
  end
end)

test("the dock unloads, refuels from the chest below and rejects bad jobs", function()
  local env, output, fuel = dockWorld({ fuel = 40 })
  local _, lib = loadModules()
  env.give(6, "minecraft:cobblestone", 20)
  env.give(9, "minecraft:raw_iron", 3)
  env.chests[fuel] = {
    { name = "minecraft:dirt", count = 2 },
    { name = "minecraft:coal", count = 64 },
    { name = "minecraft:coal", count = 64 },
  }
  writeDisk(env, "job", { id = 5, config = { startY = START_Y, oreLevels = { 999 } } })
  local base = lib.mergeConfig(lib.DEFAULT_CONFIG, { dockFuel = 1000 })
  local reason = lib.runDock(base, { maxIdle = 1 })
  H.eq(reason, "idle", "dock waits")
  H.check(env.turtle.fuel >= 1000, "refuelled to the dock level, got " .. env.turtle.fuel)
  H.eq(env.turtle.inv[4] and env.turtle.inv[4].name, "minecraft:coal", "fuel stack for the way")
  H.eq(env.turtle.inv[4].count, 64, "full fuel stack")
  H.eq(env.chestCount(output, "minecraft:cobblestone"), 20, "loot unloaded")
  H.eq(env.chestCount(output, "minecraft:raw_iron"), 3, "ores unloaded")
  H.eq(env.chestCount(output, "minecraft:dirt"), 2, "no fuel from the fuel chest goes up")
  assertUnloaded(env)
  local ack = readDisk(env, "ack")
  H.eq(ack and ack.id, 5, "job acknowledged")
  local report = readDisk(env, "report")
  H.eq(report.result.state, "rejected", "invalid job rejected")
  H.eq(report.result.jobId, 5, "rejected job id")
  H.eq(env.moves, 0, "a rejected job does not move the turtle")

  -- The same job is not taken twice, also not after a reboot
  env.files[DOCK_FILES .. "ack"] = nil
  _, lib = loadModules()
  lib.runDock(base, { maxIdle = 1 })
  H.eq(env.files[DOCK_FILES .. "ack"], nil, "old job ignored after the reboot")
end)

test("the station learns ores of other mods from the reports", function()
  local env = Mock.new()
  env.install()
  local S, lib = loadModules()
  local station = newStation(env, S, lib)
  station.setStartY(START_Y)
  local function keys()
    local list = {}
    for _, ore in ipairs(station.oreChoices()) do
      list[#list + 1] = ore.key
    end
    return table.concat(list, ",")
  end
  H.eq(keys(), "diamond,redstone,gold,lapis,iron,copper,coal,emerald", "vanilla ores only")
  writeDisk(env, "report", {
    state = "working",
    jobId = 1,
    at = 1,
    stats = { ores = { { name = "create:zinc_ore", count = 2 } } },
    result = {
      jobId = 0,
      state = "done",
      stats = { seen = { "mekanism:deepslate_osmium_ore", "minecraft:iron_ore", "mekanism:osmium_ore" } },
    },
  })
  station.poll()
  H.eq(keys(), "diamond,redstone,gold,lapis,iron,copper,coal,emerald,osmium,zinc", "found ores added once")
  H.eq(station.oreChoices()[9].label, "Osmium", "readable label")
  local again = newStation(env, S, lib)
  H.eq(#again.oreChoices(), 10, "found ores persisted")
  H.check(again.addJobs({ -16 }, 1, 18, { "zinc", "osmium" }), "job with mod ores")
  H.eq(table.concat(again.getJobs()[1].ores, ","), "osmium,zinc", "sorted kinds")
end)

test("a dock job mines only the chosen ores and reports the others", function()
  -- Gold in the test world is replaced by a modded ore
  local function world(x, y, z)
    local block = Ores.oreWorld(x, y, z)
    if block == "minecraft:deepslate_gold_ore" then
      return (x + z) % 2 == 0 and "mekanism:deepslate_osmium_ore" or "create:zinc_ore"
    end
    return block
  end
  local env = dockWorld({ generator = world })
  local S, lib = loadModules()
  local station = newStation(env, S, lib)
  station.setStartY(START_Y)
  H.check(station.addJobs({ -16 }, 1, 18, { "osmium" }), "queue the job")
  H.eq(runDock(lib, { maxIdle = 1, onPoll = station.poll }), "idle", "dock waits at the end")
  station.poll()
  H.eq(statuses(station), "1=done", "job done")
  local zinc, osmium = 0, 0
  local config = station.jobConfig(station.getJobs()[1])
  for _, band in ipairs(lib.oreLevelBands(config.oreLevels, 8)) do
    for absY = band.low, band.high do
      for x = 0, 17 do
        for z = 1, 18 do
          local block = env.get(x, absY - START_Y, z)
          if block == "create:zinc_ore" then
            zinc = zinc + 1
          elseif block == "mekanism:deepslate_osmium_ore" then
            osmium = osmium + 1
          end
        end
      end
    end
  end
  H.eq(osmium, 0, "every osmium ore mined")
  H.check(zinc > 0, "zinc was not chosen and stays")
  local found = {}
  for _, ore in ipairs(station.oreChoices()) do
    found[ore.key] = true
  end
  H.check(found.zinc and found.osmium, "the station offers the ores the turtle saw")
  H.assertHome(env)
end)

test("the dock needs a floppy disk and stops on Q", function()
  local env = dockWorld()
  local _, lib = loadModules()
  env.drive = nil
  H.eq(runDock(lib), "no disk", "no drive")
  env.drive = { mount = DISK, present = false }
  H.eq(runDock(lib), "no disk", "empty drive")
  env.drive = { mount = DISK }

  local co = coroutine.create(function()
    return runDock(lib)
  end)
  local okRun, filter = coroutine.resume(co)
  H.check(okRun, tostring(filter))
  H.eq(coroutine.status(co), "suspended", "dock waits for events")
  local timer = table.remove(env.queue, 1)
  H.eq(timer[1], "timer", "poll timer")
  okRun = coroutine.resume(co, "key", 99)
  H.check(okRun, "other keys are ignored")
  local result
  okRun, result = coroutine.resume(co, "key", keys.q)
  H.check(okRun, tostring(result))
  H.eq(result, "stopped", "stopped with Q")
  H.eq(env.files["startup/endermine-dock.lua"], nil, "dock startup removed")
  H.eq(readDisk(env, "report").state, "stopped", "station sees the stop")
end)

return tests
