-- Shared helpers for the offline test suite

local Mock = require("mock_cc")

local H = {}

H.SRC = os.getenv("SRC_DIR") or "src"

---@param path string
---@return table module
function H.loadProgram(path)
  local chunk, err = loadfile(path)
  if not chunk then
    error("cannot load " .. path .. ": " .. tostring(err), 0)
  end
  return chunk("--lib")
end

---@param cond any
---@param msg string
function H.check(cond, msg)
  if not cond then
    error(msg, 2)
  end
end

---@param actual any
---@param expected any
---@param msg string
function H.eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)), 2)
  end
end

--- Deterministic stone world with some ores.
---@return string
function H.oreWorld(x, y, z)
  local v = (x * 7 + y * 13 + z * 3) % 41
  if v == 0 then
    return "minecraft:coal_ore"
  elseif v == 17 then
    return "minecraft:iron_ore"
  elseif v == 33 and (x + z) % 5 == 0 then
    return "minecraft:diamond_ore"
  end
  return "minecraft:stone"
end

---@class SetupOptions
---@field mock MockOptions|nil
---@field config table|nil
---@field torches integer|nil
---@field supply table|nil
---@field slot1 table|nil
---@field slot2 table|nil

---@param opts SetupOptions|nil
---@return table env
---@return table miner
---@return table cfg
---@return table M
function H.setup(opts)
  opts = opts or {}
  local mockOpts = opts.mock or {}
  if mockOpts.generator == nil then
    mockOpts.generator = H.oreWorld
  end
  local env = Mock.new(mockOpts)
  env.install()
  local slot1 = opts.slot1 or { Mock.CHEST, 1, "supply" }
  local slot2 = opts.slot2 or { Mock.CHEST, 1, "resources" }
  env.give(1, slot1[1], slot1[2], slot1[3])
  env.give(2, slot2[1], slot2[2], slot2[3])
  local torches = opts.torches
  if torches == nil then
    torches = 64
  end
  if torches > 0 then
    env.give(3, "minecraft:torch", torches)
  end
  env.fillChest("supply", opts.supply or { { "minecraft:torch", 64 }, { "minecraft:torch", 64 } })
  env.fillChest("resources", {})
  local M = H.loadProgram(H.SRC .. "/miner.lua")
  local cfg = M.mergeConfig(M.DEFAULT_CONFIG, opts.config or {})
  local ok, errors = M.validateConfig(cfg)
  H.check(ok, "invalid test config: " .. table.concat(errors, "; "))
  return env, M.createMiner(cfg), cfg, M
end

--- Verify every block inside every tunnel volume is gone.
---@param env table
---@param cfg table
function H.assertCleared(env, cfg)
  local side = cfg.side == "left" and -1 or 1
  for tunnel = 0, cfg.tunnels - 1 do
    for column = 0, cfg.width - 1 do
      local x = side * (tunnel * (cfg.width + cfg.spacing) + column)
      for y = 0, cfg.height - 1 do
        for z = 1, cfg.length do
          local block = env.get(x, y, z)
          if block ~= "air" and block ~= "minecraft:torch" then
            error(string.format("block %s left at %d/%d/%d (tunnel %d)", block, x, y, z, tunnel + 1), 2)
          end
        end
      end
    end
  end
end

--- Count dug blocks outside the planned tunnels and the entrance corridor.
---@param env table
---@param cfg table
---@return integer
function H.countExtraDigs(env, cfg)
  local side = cfg.side == "left" and -1 or 1
  local stride = cfg.width + cfg.spacing
  local maxX = (cfg.tunnels - 1) * stride + cfg.width - 1
  local extra = 0
  for _, dug in ipairs(env.digs) do
    local lx = dug.x * side
    local inside = false
    if lx >= 0 and lx <= maxX and dug.z >= 1 and dug.z <= cfg.length and dug.y >= 0 and dug.y < cfg.height then
      inside = (lx % stride) < cfg.width
    end
    local corridor = dug.y == 0 and dug.z == 1 and lx >= 0 and lx <= maxX
    local fallen = dug.name == "minecraft:gravel" or dug.name == "minecraft:sand"
    if not inside and not corridor and not fallen and dug.name ~= Mock.CHEST then
      extra = extra + 1
    end
  end
  return extra
end

---@param env table
function H.assertHome(env)
  local t = env.turtle
  H.eq(t.x .. "/" .. t.y .. "/" .. t.z, "0/0/0", "turtle position")
  H.eq(t.f, 0, "turtle facing")
end

---@param env table
function H.assertChests(env)
  local t = env.turtle
  H.check(t.inv[1] and t.inv[1].name == Mock.CHEST and t.inv[1].nbt == "supply", "supply chest missing in slot 1")
  H.check(t.inv[2] and t.inv[2].name == Mock.CHEST and t.inv[2].nbt == "resources", "resource chest missing in slot 2")
end

return H
