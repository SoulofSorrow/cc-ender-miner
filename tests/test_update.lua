-- Tests for src/update.lua

local H = require("helpers")
local Mock = require("mock_cc")

local tests = {}

---@param name string
---@param fn function
local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local BASE = "https://raw.githubusercontent.com/SoulofSorrow/cc-ender-miner/main/"

---@param version string
---@param stateFormat integer|nil
---@return string
local function manifest(version, stateFormat)
  return string.format(
    [[{
  "version": "%s",
  "stateFormat": %d,
  "files": {
    "miner.lua": "src/miner.lua",
    "minermon.lua": "src/minermon.lua",
    "follower.lua": "src/follower.lua",
    "update.lua": "src/update.lua"
  },
  "roles": {
    "miner": ["miner.lua", "update.lua"],
    "monitor": ["minermon.lua", "update.lua"],
    "follower": ["follower.lua", "miner.lua", "update.lua"]
  }
}]],
    version,
    stateFormat or 1
  )
end

---@return table env
---@return table U
local function setup()
  local env = Mock.new()
  env.install()
  local U = H.loadProgram(H.SRC .. "/update.lua")
  env.http[BASE .. "manifest.json"] = { 200, manifest("9.0.0") }
  env.http[BASE .. "src/miner.lua"] = { 200, 'local VERSION = "9.0.0"\nreturn VERSION\n' }
  env.http[BASE .. "src/minermon.lua"] = { 200, 'local VERSION = "9.0.0"\n' }
  env.http[BASE .. "src/follower.lua"] = { 200, 'local VERSION = "9.0.0"\n' }
  env.http[BASE .. "src/update.lua"] = { 200, "return {}\n" }
  env.files["miner.lua"] = 'local VERSION = "1.0.0"\n'
  env.files["update.lua"] = "-- old updater\n"
  return env, U
end

test("version comparison", function()
  Mock.new().install()
  local U = H.loadProgram(H.SRC .. "/update.lua")
  H.eq(U.compareVersions("1.2.0", "1.10.0"), -1, "minor numeric")
  H.eq(U.compareVersions("2.0.0", "1.99.99"), 1, "major")
  H.eq(U.compareVersions("1.3.0", "1.3.0"), 0, "equal")
  H.eq(U.compareVersions("1.3", "1.3.0"), 0, "missing patch")
end)

test("newer version installs the files of the role", function()
  local env, U = setup()
  local status, msg, version = U.check({ role = "miner", current = "1.0.0" })
  H.eq(status, "updated", "status: " .. tostring(msg))
  H.eq(version, "9.0.0", "installed version")
  H.check(env.files["miner.lua"]:find("9.0.0", 1, true), "miner.lua replaced")
  H.eq(env.files["update.lua"], "return {}\n", "updater replaced")
  H.eq(env.files["minermon.lua"], nil, "files of other roles are not installed")
  H.eq(env.files["miner.lua.new"], nil, "no temporary files left")
end)

test("same version does nothing", function()
  local env, U = setup()
  env.http[BASE .. "manifest.json"] = { 200, manifest("1.0.0") }
  local status = U.check({ role = "miner", current = "1.0.0" })
  H.eq(status, "current", "status")
  H.eq(env.files["miner.lua"], 'local VERSION = "1.0.0"\n', "untouched")
end)

test("a broken download changes nothing", function()
  local env, U = setup()
  env.http[BASE .. "src/update.lua"] = { 200, "<html>Rate limit</html>" }
  local status, msg = U.check({ role = "miner", current = "1.0.0" })
  H.eq(status, "failed", "status")
  H.check(msg:find("not valid Lua"), "message: " .. msg)
  H.eq(env.files["miner.lua"], 'local VERSION = "1.0.0"\n', "miner.lua must stay")
  env.http[BASE .. "src/update.lua"] = { 404, "Not Found" }
  H.eq((U.check({ role = "miner", current = "1.0.0" })), "failed", "404")
  H.eq(env.files["miner.lua"], 'local VERSION = "1.0.0"\n', "miner.lua must stay after 404")
end)

test("no network and a bad manifest are reported", function()
  local env, U = setup()
  env.http[BASE .. "manifest.json"] = nil
  local status, msg = U.check({ role = "miner", current = "1.0.0" })
  H.eq(status, "failed", "offline")
  H.check(msg:find("manifest"), "message: " .. msg)
  env.http[BASE .. "manifest.json"] = { 200, "{ not json" }
  H.eq((U.check({ role = "miner", current = "1.0.0" })), "failed", "invalid json")
  env.http[BASE .. "manifest.json"] = {
    200,
    '{"version":"9.0.0","files":{"../startup.lua":"x"},"roles":{"miner":["../startup.lua"]}}',
  }
  local _, evil = U.check({ role = "miner", current = "1.0.0" })
  H.check(evil:find("invalid file"), "path traversal must be refused: " .. evil)
  _G.http = nil
  H.eq((U.check({ role = "miner", current = "1.0.0" })), "skipped", "http disabled")
end)

test("a running job is only updated by a compatible version", function()
  local env, U = setup()
  env.http[BASE .. "manifest.json"] = { 200, manifest("9.0.0", 2) }
  local status, msg = U.check({ role = "miner", current = "1.0.0", jobActive = true, stateFormat = 1 })
  H.eq(status, "skipped", "incompatible save format")
  H.check(msg:find("job"), "message: " .. msg)
  env.http[BASE .. "manifest.json"] = { 200, manifest("9.0.0", 1) }
  H.eq((U.check({ role = "miner", current = "1.0.0", jobActive = true, stateFormat = 1 })), "updated", "compatible")
end)

test("custom update url and switch", function()
  local env, U = setup()
  env.settings["endermine.update_url"] = "https://example.org/mirror"
  env.http["https://example.org/mirror/manifest.json"] = { 200, manifest("1.0.0") }
  H.eq((U.check({ role = "miner", current = "1.0.0" })), "current", "mirror used")
  H.eq(env.httpRequests[#env.httpRequests], "https://example.org/mirror/manifest.json", "request url")
  env.settings["endermine.auto_update"] = false
  local before = #env.httpRequests
  H.eq(U.autoUpdate({ role = "miner", current = "1.0.0", shell = {} }), false, "disabled")
  H.eq(#env.httpRequests, before, "no request when disabled")
end)

test("auto update restarts the program without checking again", function()
  local env, U = setup()
  local runs = {}
  local shell = {
    run = function(...)
      runs[#runs + 1] = { ... }
      return true
    end,
  }
  local restarted = U.autoUpdate({
    role = "miner",
    current = "1.0.0",
    program = "miner.lua",
    args = { "resume" },
    shell = shell,
  })
  H.eq(restarted, true, "restarted")
  H.eq(#runs, 1, "one restart")
  H.eq(runs[1][1], "miner.lua", "program")
  H.eq(runs[1][2], "--no-update", "loop guard")
  H.eq(runs[1][3], "resume", "arguments passed on")
  H.eq(env.files["miner.lua"], 'local VERSION = "9.0.0"\nreturn VERSION\n', "new version installed")
end)

test("manifest in the repository matches the programs", function()
  local handle = assert(io.open("manifest.json", "r"))
  local data = Mock.decodeJSON(handle:read("*a"))
  handle:close()
  Mock.new().install()
  local U = H.loadProgram(H.SRC .. "/update.lua")
  H.check(U.validateManifest(data), "repository manifest is invalid")
  for name, path in pairs(data.files) do
    local file = io.open(path, "r")
    H.check(file, "manifest points to a missing file: " .. path)
    local text = file:read("*a")
    file:close()
    local version = text:match('local VERSION = "([%d%.]+)"')
    if version then
      H.eq(version, data.version, name .. " version")
    end
  end
  local M = H.loadProgram(H.SRC .. "/miner.lua")
  H.eq(data.stateFormat, M.STATE_FORMAT, "stateFormat")
end)

return tests
