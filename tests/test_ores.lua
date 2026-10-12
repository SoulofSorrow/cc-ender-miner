-- Tests for the ore mode: geo scanner, levels, tours and restart safety

local H = require("helpers")
local Mock = require("mock_cc")

local tests = {}

---@param name string
---@param fn function
local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local START_Y = 64
local SCANNER = "advancedperipherals:geo_scanner"

---@param x integer
---@param y integer
---@param z integer
---@param salt integer
---@return integer
local function noise(x, y, z, salt)
  local v = (x * 92837111 + y * 689287499 + z * 283923481 + salt * 1000003) % 2147483647
  return (v * 48271) % 2147483647
end

--- Surface at job y 0, stone and deepslate below with blobs of other rock,
--- ore veins in 2x2x2 clusters that depend on the height, bedrock at the
--- bottom of the world.
---@return string
local function oreWorld(x, y, z)
  if y >= 1 then
    return "air"
  end
  if y == 0 then
    return "minecraft:grass_block"
  end
  local absY = START_Y + y
  if absY <= -61 then
    return "minecraft:bedrock"
  end
  if noise(math.floor(x / 2), math.floor(y / 2), math.floor(z / 2), 1) % 37 == 0 then
    if absY <= -40 then
      return noise(x, y, z, 2) % 3 == 0 and "minecraft:deepslate_redstone_ore" or "minecraft:deepslate_diamond_ore"
    elseif absY <= 0 then
      return "minecraft:deepslate_gold_ore"
    elseif absY <= 30 then
      return "minecraft:iron_ore"
    end
    return "minecraft:copper_ore"
  end
  local rock = noise(math.floor(x / 3), math.floor(y / 3), math.floor(z / 3), 3) % 11
  if rock == 0 then
    return "minecraft:granite"
  elseif rock == 1 then
    return "minecraft:diorite"
  elseif rock == 2 then
    return "minecraft:andesite"
  end
  return absY < 0 and "minecraft:deepslate" or "minecraft:stone"
end

local BASE_CONFIG = {
  mode = "ores",
  startY = START_Y,
  oreLevels = { 16, -48 },
  areaWidth = 20,
  areaLength = 20,
  dropJunk = true,
}

---@param config table|nil
---@param mock table|nil
---@return table env
---@return table miner
---@return table cfg
---@return table M
local function oreSetup(config, mock)
  mock = mock or {}
  mock.generator = mock.generator or oreWorld
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
  local M = H.loadProgram(H.SRC .. "/miner.lua")
  local merged = {}
  for k, v in pairs(BASE_CONFIG) do
    merged[k] = v
  end
  for k, v in pairs(config or {}) do
    merged[k] = v
  end
  local cfg = M.mergeConfig(M.DEFAULT_CONFIG, merged)
  local ok, errors = M.validateConfig(cfg)
  H.check(ok, "invalid ore config: " .. table.concat(errors, "; "))
  return env, M.createMiner(cfg), cfg, M
end

--- Every ore inside the area and the level bands must be gone.
---@param env table
---@param cfg table
---@param M table
---@return integer ores Number of ore blocks that were in the region
local function assertOresMined(env, cfg, M)
  local sign = cfg.side == "left" and -1 or 1
  local bands = M.oreLevelBands(cfg.oreLevels, cfg.scanRadius)
  local count = 0
  for _, band in ipairs(bands) do
    for absY = band.low, band.high do
      local y = absY - cfg.startY
      for ax = 0, cfg.areaWidth - 1 do
        for z = 1, cfg.areaLength do
          local x = ax * sign
          if oreWorld(x, y, z):find("_ore$") then
            count = count + 1
          end
          local block = env.get(x, y, z)
          if block:find("_ore$") then
            error(string.format("ore %s left at %d/%d/%d (Y %d)", block, x, y, z, absY), 2)
          end
        end
      end
    end
  end
  return count
end

---@param env table
local function assertEquipment(env)
  local t = env.turtle
  H.check(tostring(t.right):find("pickaxe"), "pickaxe must be equipped again, got " .. tostring(t.right))
  H.check(t.inv[3] and t.inv[3].name == SCANNER, "geo scanner must be back in slot 3")
end

--- Record moves into cells the turtle had already been in while mining.
---@param env table
---@param miner table
---@return table stats {moves, revisits}
local function trackRevisits(env, miner)
  local visited = { ["0,0,0"] = true }
  local result = { moves = 0, revisits = 0 }
  local previous = env.hooks.move
  env.hooks.move = function(e)
    if previous then
      previous(e)
    end
    if miner.getStatus().state == "returning" then
      return
    end
    local t = e.turtle
    local k = string.format("%d,%d,%d", t.x, t.y, t.z)
    result.moves = result.moves + 1
    if visited[k] then
      result.revisits = result.revisits + 1
    end
    visited[k] = true
  end
  return result
end

test("level bands, scan grid and tour planning", function()
  Mock.new().install()
  local M = H.loadProgram(H.SRC .. "/miner.lua")
  H.eq(M.scanSpacing(8), 9, "spacing for radius 8")
  local bands = M.oreLevelBands({ 16, -57, 0, 16 }, 8)
  H.eq(#bands, 3, "duplicate levels removed")
  H.eq(bands[1].y, 16, "sorted from the top")
  H.eq(bands[3].y, -57, "deepest last")
  for i = 2, #bands do
    H.check(bands[i].high < bands[i - 1].low, "bands must not overlap")
  end
  local close = M.oreLevelBands({ 10, 4 }, 8)
  H.eq(close[1].low, close[2].high + 1, "close levels split the gap")
  -- Every column of the area lies within half a spacing of a scan point
  for _, size in ipairs({ 4, 9, 10, 20, 45, 64 }) do
    local points = M.scanAxis(0, size - 1, 9)
    for x = 0, size - 1 do
      local nearest = math.huge
      for _, p in ipairs(points) do
        nearest = math.min(nearest, math.abs(p - x))
      end
      H.check(nearest <= 4, string.format("size %d: column %d is %d from a scan point", size, x, nearest))
    end
  end
  local start = { x = 0, y = 0, z = 0 }
  local ores = {
    { x = 5, y = 0, z = 0 },
    { x = 1, y = 0, z = 0 },
    { x = 3, y = 0, z = 0 },
    { x = 2, y = 1, z = 0 },
  }
  local route = M.planTour(start, ores, { x = 6, y = 0, z = 0 })
  H.eq(#route, 4, "all ores in the tour")
  H.eq(route[1].x, 1, "starts with the nearest")
  H.eq(route[4].x, 5, "ends towards the next point")
  H.check(M.isWantedOre({ name = "mekanism:osmium_ore", tags = { "c:ores" } }), "modded ores by tag")
  H.check(M.isWantedOre({ name = "x:y", tags = { ["c:ores"] = true } }), "tags as a set")
  H.check(not M.isWantedOre({ name = "minecraft:stone", tags = {} }), "stone is no ore")
  H.check(
    not M.isWantedOre({ name = "minecraft:iron_ore", tags = { "c:ores" } }, { ["minecraft:diamond_ore"] = true }),
    "filter by name"
  )
  local keys = {
    ["minecraft:deepslate_diamond_ore"] = "diamond",
    ["minecraft:diamond_ore"] = "diamond",
    ["minecraft:nether_gold_ore"] = "gold",
    ["minecraft:deepslate_lapis_ore"] = "lapis",
    ["mekanism:osmium_ore"] = "osmium",
    ["mekanism:deepslate_osmium_ore"] = "osmium",
    ["somemod:ore_tin_deepslate"] = "tin",
    ["alltheores:raw_silver_ore"] = "raw_silver",
    ["minecraft:ancient_debris"] = "ancient_debris",
    ["x:deepslate_ore"] = "deepslate_ore",
  }
  for name, key in pairs(keys) do
    H.eq(M.oreKey(name), key, "ore key of " .. name)
  end
  local groups = { diamond = true, osmium = true }
  H.check(M.isWantedOre({ name = "minecraft:deepslate_diamond_ore", tags = {} }, nil, groups), "group: diamond")
  H.check(M.isWantedOre({ name = "mekanism:deepslate_osmium_ore", tags = { "c:ores" } }, nil, groups), "group: mod")
  H.check(not M.isWantedOre({ name = "minecraft:iron_ore", tags = {} }, nil, groups), "group: other ore")
  H.check(not M.isWantedOre({ name = "x:diamond", tags = {} }, nil, groups), "group: not an ore at all")
end)

test("ore mode needs the start height", function()
  Mock.new().install()
  local M = H.loadProgram(H.SRC .. "/miner.lua")
  local cfg = M.mergeConfig(M.DEFAULT_CONFIG, { mode = "ores" })
  local ok, errors = M.validateConfig(cfg)
  H.check(not ok, "startY missing must be rejected")
  H.check(table.concat(errors, " "):find("startY"), "error names startY")
  local bad = M.mergeConfig(M.DEFAULT_CONFIG, { mode = "ores", startY = 70, oreLevels = { -64 } })
  H.check(not M.validateConfig(bad), "levels in the bedrock must be rejected")
end)

test("mines every ore of the levels and returns home", function()
  local env, miner, cfg, M = oreSetup()
  local track = trackRevisits(env, miner)
  local ok, state, msg = miner.run()
  H.check(ok, "run failed: " .. tostring(state) .. " " .. tostring(msg))
  local ores = assertOresMined(env, cfg, M)
  H.check(ores > 50, "test world should contain ores, got " .. ores)
  H.assertHome(env)
  H.assertChests(env)
  assertEquipment(env)
  H.check(env.chestCount("resources") > ores * 0.9, "ores must reach the resource chest")
  local volume = cfg.areaWidth * cfg.areaLength * 9 * #cfg.oreLevels
  H.check(#env.digs < volume * 0.35, string.format("dug %d blocks of %d", #env.digs, volume))
  local share = track.revisits / track.moves
  H.check(share < 0.25, string.format("%.0f%% of the moves went through cells visited before", share * 100))
  H.eq(env.scans >= 2 * 9 + 2, true, "one scan per point plus calibration")
end)

test("works for every facing and both sides", function()
  for _, dir in ipairs({ "north", "east", "south", "west" }) do
    for _, side in ipairs({ "right", "left" }) do
      local env, miner, cfg, M = oreSetup(
        { side = side, areaWidth = 12, areaLength = 12, oreLevels = { -48 } },
        { worldDir = dir }
      )
      local ok, state, msg = miner.run()
      local label = dir .. "/" .. side
      H.check(ok, label .. ": run failed: " .. tostring(state) .. " " .. tostring(msg))
      local okMined, err = pcall(assertOresMined, env, cfg, M)
      H.check(okMined, label .. ": " .. tostring(err))
      H.assertHome(env)
    end
  end
end)

test("only selected ores and staying at the end", function()
  local env, miner, cfg = oreSetup({
    oreNames = { "minecraft:deepslate_diamond_ore" },
    oreLevels = { -48 },
    areaWidth = 12,
    areaLength = 12,
    returnHome = false,
  })
  H.check(miner.run(), "run failed")
  local redstoneLeft = 0
  for x = 0, cfg.areaWidth - 1 do
    for z = 1, cfg.areaLength do
      for y = -116, -108 do
        local block = env.get(x, y, z)
        H.check(block ~= "minecraft:deepslate_diamond_ore", "diamond left at " .. x .. "/" .. y .. "/" .. z)
        if block == "minecraft:deepslate_redstone_ore" then
          redstoneLeft = redstoneLeft + 1
        end
      end
    end
  end
  H.check(redstoneLeft > 0, "redstone was not selected and should stay")
  H.check(env.turtle.y < -100, "turtle stays at the last level")
  assertEquipment(env)
end)

test("only selected kinds of ore, all variants of a kind", function()
  local env, miner, cfg = oreSetup({
    oreGroups = { "redstone" },
    oreLevels = { -48 },
    areaWidth = 12,
    areaLength = 12,
  })
  H.check(miner.run(), "run failed")
  local diamondLeft = 0
  for x = 0, cfg.areaWidth - 1 do
    for z = 1, cfg.areaLength do
      for y = -116, -108 do
        local block = env.get(x, y, z)
        H.check(block ~= "minecraft:deepslate_redstone_ore", "redstone left at " .. x .. "/" .. y .. "/" .. z)
        if block == "minecraft:deepslate_diamond_ore" then
          diamondLeft = diamondLeft + 1
        end
      end
    end
  end
  H.check(diamondLeft > 0, "diamond was not selected and should stay")
  local status = miner.getStatus()
  -- Other ores only end up in the statistics when they are in the way
  H.eq(status.ores[1].name, "minecraft:deepslate_redstone_ore", "mostly the chosen kind")
  H.eq(
    table.concat(status.seenOres, ","),
    "minecraft:deepslate_diamond_ore,minecraft:deepslate_redstone_ore",
    "the scanner also reports the ores it left"
  )
  H.assertHome(env)
end)

test("ores out of reach next to bedrock are skipped", function()
  local env, miner = oreSetup({ oreLevels = { -57 }, areaWidth = 10, areaLength = 10 })
  local ok, state, msg = miner.run()
  H.check(ok, "run failed: " .. tostring(state) .. " " .. tostring(msg))
  H.assertHome(env)
end)

---@return table kinds Action kinds of an undisturbed run
local function profile()
  local env, miner = oreSetup({ areaWidth = 12, areaLength = 12, oreLevels = { 16, -48 } })
  H.check(miner.run(), "profile run failed")
  return env.actionKinds
end

---@param at integer
---@param after boolean
---@return string state
---@return table env
---@return table cfg
---@return table M
local function killAndResume(at, after)
  local env, miner, cfg, M = oreSetup({ areaWidth = 12, areaLength = 12, oreLevels = { 16, -48 } })
  env.kill = { at = at, after = after }
  H.check(H.runUntilKilled(miner), "action " .. at .. " was never reached")
  local resumed = H.reboot(env)
  local _, state, msg = resumed.run()
  return state .. (msg and (" " .. msg) or ""), env, cfg, M
end

test("survives an unload at any action, also while scanning, without GPS", function()
  local kinds = profile()
  local checked, turns, equips = 0, 0, 0
  for at, kind in ipairs(kinds) do
    if kind ~= "move" or at % 9 == 0 then
      if kind == "turn" then
        turns = turns + 1
      elseif kind == "equip" then
        equips = equips + 1
      end
      for _, after in ipairs({ false, true }) do
        if kind ~= "turn" or (turns % 3 == 0) then
          local label = string.format("%s #%d %s", kind, at, after and "after" or "before")
          local state, env, cfg, M = killAndResume(at, after)
          H.check(state:find("^done"), label .. ": final state " .. state)
          local okMined, err = pcall(assertOresMined, env, cfg, M)
          H.check(okMined, label .. ": " .. tostring(err))
          local okHome, homeErr = pcall(H.assertHome, env)
          H.check(okHome, label .. ": " .. tostring(homeErr))
          local okEquip, equipErr = pcall(assertEquipment, env)
          H.check(okEquip, label .. ": " .. tostring(equipErr))
          H.assertJobCleared(env)
          checked = checked + 1
        end
      end
    end
  end
  H.check(equips > 10, "profile should swap tools often, got " .. equips)
  H.check(turns > 10, "profile should contain turns, got " .. turns)
  H.check(checked > 150, "too few kill points: " .. checked)
end)

test("an interrupted turn is recovered with the geo scanner instead of GPS", function()
  local kinds = profile()
  local turnAt = nil
  for at, kind in ipairs(kinds) do
    if kind == "turn" and at > 60 then
      turnAt = at
      break
    end
  end
  H.check(turnAt, "no turn after the calibration")
  for _, after in ipairs({ false, true }) do
    local env, miner = oreSetup(
      { areaWidth = 12, areaLength = 12, oreLevels = { 16, -48 } },
      { modem = true, worldDir = "south" }
    )
    H.eq(gps, nil, "no GPS in this world")
    env.kill = { at = turnAt, after = after }
    H.check(H.runUntilKilled(miner), "should be killed")
    local resumed = H.reboot(env)
    H.check(resumed.openTelemetry(), "telemetry")
    local ok, state, msg = resumed.run()
    H.check(ok, "resume failed: " .. tostring(state) .. " " .. tostring(msg))
    local recovered = false
    for _, entry in ipairs(env.broadcasts) do
      if entry.msg.type == "event" and entry.msg.text == "Facing recovered with the geo scanner" then
        recovered = true
      end
    end
    H.check(recovered, "facing must be measured with the scanner (" .. (after and "after" or "before") .. ")")
    H.assertHome(env)
  end
end)

test("a reboot while the scanner is equipped puts the pickaxe back", function()
  local kinds = profile()
  local equipAt = nil
  for at, kind in ipairs(kinds) do
    if kind == "equip" and at > 80 then
      equipAt = at
      break
    end
  end
  local env, miner = oreSetup({ areaWidth = 12, areaLength = 12, oreLevels = { 16, -48 } })
  env.kill = { at = equipAt, after = true }
  H.check(H.runUntilKilled(miner), "should be killed")
  H.check(tostring(env.turtle.right):find("geo_scanner"), "scanner equipped at the unload")
  local resumed = H.reboot(env)
  H.check(resumed.run(), "resume failed")
  assertEquipment(env)
end)

test("setup wizard for the ore mode", function()
  local env = Mock.new()
  env.install()
  local answers =
    { "erz", "ores", "70", "9", "1,4", "Deepslate_Diamond_Ore, iron", "20", "24", "left", "right", "n", "y", "-1" }
  _G.read = function()
    return table.remove(answers, 1)
  end
  local errors = 0
  _G.printError = function()
    errors = errors + 1
  end
  local M = H.loadProgram(H.SRC .. "/miner.lua")
  local cfg = M.runWizard(M.DEFAULT_CONFIG)
  H.eq(#answers, 0, "all answers used")
  H.eq(errors, 2, "invalid mode and invalid preset are rejected")
  H.eq(cfg.mode, "ores", "mode")
  H.eq(cfg.startY, 70, "start Y")
  H.eq(table.concat(cfg.oreLevels, ","), "-57,16", "levels from presets")
  H.eq(table.concat(cfg.oreGroups, ","), "diamond,iron", "ore kinds")
  H.eq(cfg.areaWidth .. "x" .. cfg.areaLength, "20x24", "area")
  H.eq(cfg.side, "left", "area side")
  H.eq(cfg.toolSide, "right", "pickaxe side")
  H.eq(cfg.returnHome, false, "return home")
  H.check(M.validateConfig(cfg), "wizard result must be valid")
  answers = { "ores", "", "c", "12, -30", "", "", "", "", "", "", "", "" }
  local custom = M.runWizard(cfg)
  H.eq(table.concat(custom.oreLevels, ","), "12,-30", "own levels")
  H.eq(table.concat(custom.oreGroups, ","), "diamond,iron", "ore kinds kept")
  answers = { "ores", "", "", "", "*", "", "", "", "", "", "", "" }
  H.eq(#M.runWizard(custom).oreGroups, 0, "* means every ore")
end)

tests.oreSetup = oreSetup
tests.oreWorld = oreWorld
tests.trackRevisits = trackRevisits
tests.assertOresMined = assertOresMined
return tests
