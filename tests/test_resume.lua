-- Resume tests: the turtle is stopped at arbitrary points like during a chunk
-- unload or server restart and must finish the job after booting again.

local H = require("helpers")

local tests = {}

---@param name string
---@param fn function
local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

-- Small job that still unloads, resupplies, turns and places torches
local JOB = {
  tunnels = 2,
  width = 2,
  height = 3,
  length = 10,
  spacing = 1,
  torchInterval = 4,
  dropJunk = false,
}
local SUPPLY = { { "minecraft:torch", 64 } }
local GPS = { x = 120, y = 40, z = -300, dir = "east" }

---@param mock table|nil
---@return table env
---@return table miner
---@return table cfg
local function newJob(mock)
  return H.setup({ torches = 0, config = JOB, supply = SUPPLY, mock = mock })
end

--- Count actions of a complete undisturbed run.
---@param mock table|nil
---@return table kinds Action kind per action number
---@return integer torches Torches placed in a clean run
local function profile(mock)
  local env, miner, cfg = newJob(mock)
  local ok, state, msg = miner.run()
  H.check(ok, "profile run failed: " .. tostring(state) .. " " .. tostring(msg))
  return env.actionKinds, H.assertTorches(env, cfg)
end

---@param env table
---@param cfg table
---@param torches integer
---@param label string
local function assertFinished(env, cfg, torches, label)
  local okCleared, clearedErr = pcall(H.assertCleared, env, cfg)
  H.check(okCleared, label .. ": " .. tostring(clearedErr))
  local okHome, homeErr = pcall(H.assertHome, env)
  H.check(okHome, label .. ": " .. tostring(homeErr))
  local okChests, chestErr = pcall(H.assertChests, env)
  H.check(okChests, label .. ": " .. tostring(chestErr))
  local okTorches, placed = pcall(H.assertTorches, env, cfg)
  H.check(okTorches, label .. ": " .. tostring(placed))
  H.eq(placed, torches, label .. ": torch count")
  H.check(H.countExtraDigs(env, cfg) <= 4, label .. ": too many blocks dug outside the tunnels")
  local okFiles, filesErr = pcall(H.assertJobCleared, env)
  H.check(okFiles, label .. ": " .. tostring(filesErr))
end

--- Kill the turtle at one action, reboot it and let it finish.
---@param mock table|nil
---@param at integer
---@param after boolean
---@return string state Final state after the reboot
---@return table env
---@return table cfg
local function killAndResume(mock, at, after)
  local env, miner, cfg = newJob(mock)
  env.kill = { at = at, after = after }
  local killed = H.runUntilKilled(miner)
  H.check(killed, "action " .. at .. " was never reached")
  local resumed = H.reboot(env)
  local _, state = resumed.run()
  return state, env, cfg
end

test("a fresh job creates the startup file and removes it at the end", function()
  local env, miner = newJob()
  env.kill = { at = 5, after = true }
  H.check(H.runUntilKilled(miner), "should be killed")
  H.check(env.files["startup/endermine.lua"]:find('shell.run("miner", "resume")', 1, true), "startup content")
  H.check(env.files["miner.state"] and env.files["miner.pos"], "job files missing")
  local resumed = H.reboot(env)
  H.check(resumed.run(), "resumed run failed")
  H.assertJobCleared(env)
end)

test("moves and chest placements survive an unload without GPS", function()
  local kinds, torches = profile(nil)
  local checked = 0
  for at, kind in ipairs(kinds) do
    if kind ~= "turn" and (kind == "place" or at % 2 == 0) then
      for _, after in ipairs({ false, true }) do
        local label = string.format("%s #%d %s", kind, at, after and "after" or "before")
        local state, env, cfg = killAndResume(nil, at, after)
        H.eq(state, "done", label .. ": final state")
        assertFinished(env, cfg, torches, label)
        checked = checked + 1
      end
    end
  end
  H.check(checked > 100, "too few kill points: " .. checked)
end)

test("an interrupted turn without GPS stops safely", function()
  local kinds = profile(nil)
  local turnAt = nil
  for at, kind in ipairs(kinds) do
    if kind == "turn" and at > 20 then
      turnAt = at
      break
    end
  end
  H.check(turnAt, "profile has no turn")
  for _, after in ipairs({ false, true }) do
    local env, miner = newJob()
    env.kill = { at = turnAt, after = after }
    H.check(H.runUntilKilled(miner), "should be killed")
    local moves = env.moves
    local resumed = H.reboot(env)
    local ok, state, msg = resumed.run()
    H.check(not ok, "must not continue blindly")
    H.eq(state, "lost", "state")
    H.check(msg:find("GPS"), "message should suggest GPS: " .. msg)
    H.eq(env.moves, moves, "a lost turtle must not move")
    H.eq(env.files["startup/endermine.lua"], nil, "a lost turtle must not restart on every boot")
  end
end)

test("every action survives an unload with GPS", function()
  local kinds, torches = profile({ gps = GPS })
  local checked = 0
  for at, kind in ipairs(kinds) do
    if kind == "turn" or kind == "place" or at % 4 == 0 then
      for _, after in ipairs({ false, true }) do
        local label = string.format("%s #%d %s", kind, at, after and "after" or "before")
        local state, env, cfg = killAndResume({ gps = GPS }, at, after)
        H.eq(state, "done", label .. ": final state")
        assertFinished(env, cfg, torches, label)
        checked = checked + 1
      end
    end
  end
  H.check(checked > 100, "too few kill points: " .. checked)
end)

test("unlimited fuel moves are recovered with GPS", function()
  local mock = { gps = GPS, unlimited = true }
  local kinds, torches = profile(mock)
  for at = 7, #kinds, 23 do
    local state, env, cfg = killAndResume(mock, at, at % 2 == 0)
    H.eq(state, "done", "action " .. at)
    assertFinished(env, cfg, torches, "unlimited #" .. at)
  end
end)

test("unlimited fuel without GPS stops safely", function()
  local env, miner = newJob({ unlimited = true })
  env.kill = { at = 40, after = true }
  H.check(H.runUntilKilled(miner), "should be killed")
  local resumed = H.reboot(env)
  local ok, state = resumed.run()
  H.check(not ok and state == "lost", "must stop when a move cannot be verified")
end)

test("several unloads in a row", function()
  -- Profile first: it installs its own simulated world
  local _, torches = profile({ gps = GPS })
  local env, miner, cfg = newJob({ gps = GPS })
  local restarts = 0
  local killAt = 13
  local current = miner
  while true do
    env.kill = { at = env.actions + killAt, after = restarts % 2 == 0 }
    local killed, ok, state = H.runUntilKilled(current)
    if not killed then
      H.check(ok, "final run failed: " .. tostring(state))
      break
    end
    restarts = restarts + 1
    H.check(restarts < 200, "job never finishes")
    current = H.reboot(env)
  end
  H.check(restarts > 5, "expected many restarts, got " .. restarts)
  assertFinished(env, cfg, torches, "chain")
  H.eq(current.getStatus().restarts, restarts, "restart counter")
end)

test("progress and statistics continue after a resume", function()
  local env, miner = newJob({ gps = GPS })
  env.kill = { at = 150, after = true }
  H.check(H.runUntilKilled(miner), "should be killed")
  local before = miner.getStatus()
  local resumed = H.reboot(env)
  local status = resumed.getStatus()
  H.check(resumed.run(), "resumed run failed")
  local final = resumed.getStatus()
  H.check(before.progress.done > 0, "progress before the unload")
  H.eq(status.progress.total, before.progress.total, "same job")
  H.check(final.mined >= before.mined, "mined counter must continue")
  H.eq(final.progress.done, final.progress.total, "job complete")
end)

test("paused state survives a reboot", function()
  local env, miner = newJob()
  local paused = false
  env.hooks.move = function(e)
    if e.moves == 20 and not paused then
      paused = true
      miner.handleCommand("pause")
    end
  end
  -- Unload the chunk while the turtle waits in the paused state
  env.hooks.sleep = function(e)
    if paused and not e.killed then
      e.killed = true
      coroutine.yield("__kill")
    end
  end
  H.check(H.runUntilKilled(miner), "should be killed while paused")
  env.hooks.move = nil
  local resumed = H.reboot(env)
  local sawPaused = false
  local sleeps = 0
  env.hooks.sleep = function()
    sleeps = sleeps + 1
    if resumed.getStatus().state == "paused" then
      sawPaused = true
    end
    if sleeps == 3 then
      resumed.handleCommand("resume")
    end
  end
  H.check(resumed.run(), "resumed run failed")
  H.check(sawPaused, "turtle must stay paused after the reboot")
end)

test("a damaged state file is rejected", function()
  local env, miner = newJob()
  env.kill = { at = 25, after = false }
  H.check(H.runUntilKilled(miner), "should be killed")
  env.files["miner.pos"] = "garbage"
  local M = H.loadProgram(H.SRC .. "/miner.lua")
  local saved, err = M.loadSavedJob()
  H.eq(saved, nil, "damaged journal must not load")
  H.check(err and err:find("journal"), "error should mention the journal: " .. tostring(err))
end)

test("an unfinished atomic write is recovered", function()
  local env, miner = newJob()
  env.kill = { at = 60, after = true }
  H.check(H.runUntilKilled(miner), "should be killed")
  -- Simulate a crash between deleting the old file and renaming the new one
  env.files["miner.pos.new"] = env.files["miner.pos"]
  env.files["miner.pos"] = nil
  local resumed = H.reboot(env)
  H.check(resumed.run(), "resume from the .new file failed")
end)

test("gps coordinate conversion", function()
  local M = H.loadProgram(H.SRC .. "/miner.lua")
  -- Facing 0 points east: relative +z is absolute +x, relative +x is absolute +z
  local frame = { x = 10, y = 64, z = 20, dx = 1, dz = 0 }
  local x, y, z = M.toRelative(frame, 13, 66, 22)
  H.eq(x .. "/" .. y .. "/" .. z, "2/2/3", "east frame")
  H.eq(M.facingOf(frame, 1, 0), 0, "east is forward")
  H.eq(M.facingOf(frame, 0, 1), 1, "south is right")
  H.eq(M.facingOf(frame, -1, 0), 2, "west is back")
  H.eq(M.facingOf(frame, 0, -1), 3, "north is left")
  H.eq(M.facingOf(frame, 1, 1), nil, "diagonal is invalid")
  local north = { x = 0, y = 0, z = 0, dx = 0, dz = -1 }
  local nx, _, nz = M.toRelative(north, 1, 0, -5)
  H.eq(nx .. "/" .. nz, "1/5", "north frame")
end)

return tests
