-- cc-ender-miner - updater
-- Copyright (C) 2026 Julian Schäfer
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Usage:  update [miner|monitor|follower|station] [--force]
--
-- The other programs load this file as a library ("--lib") and call
-- autoUpdate() when they start. Updates come from manifest.json in the
-- repository. Settings (set with the "set" command):
--   endermine.auto_update  false disables the automatic check (default true)
--   endermine.update_url   base URL of the repository files

local VERSION = "2.2.0"
local DEFAULT_URL = "https://raw.githubusercontent.com/SoulofSorrow/cc-ender-miner/main/"
local MANIFEST = "manifest.json"
local SETTING_URL = "endermine.update_url"
local SETTING_AUTO = "endermine.auto_update"

---@class Manifest
---@field version string
---@field stateFormat integer
---@field files table<string, string> Local file name -> path in the repository
---@field roles table<string, string[]> Role -> local file names

--- Compare two "major.minor.patch" versions.
---@param a string
---@param b string
---@return integer -1, 0 or 1
local function compareVersions(a, b)
  local pa, pb = {}, {}
  for part in tostring(a):gmatch("%d+") do
    pa[#pa + 1] = tonumber(part)
  end
  for part in tostring(b):gmatch("%d+") do
    pb[#pb + 1] = tonumber(part)
  end
  for i = 1, math.max(#pa, #pb, 3) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then
      return x < y and -1 or 1
    end
  end
  return 0
end

---@return string
local function baseUrl()
  local url = settings and settings.get(SETTING_URL) or nil
  if type(url) ~= "string" or url == "" then
    url = DEFAULT_URL
  end
  if url:sub(-1) ~= "/" then
    url = url .. "/"
  end
  return url
end

---@param url string
---@return string|nil body
---@return string|nil err
local function download(url)
  if not http then
    return nil, "the http API is disabled in the CC: Tweaked config"
  end
  -- The query string avoids stale copies from caches between updates
  local stamp = os.epoch and os.epoch("utc") or 0
  local ok, response, err = pcall(http.get, url .. "?t=" .. tostring(stamp), nil, true)
  if not ok then
    return nil, tostring(response)
  end
  if not response then
    return nil, tostring(err)
  end
  local code = response.getResponseCode()
  local body = response.readAll()
  response.close()
  if code ~= 200 then
    return nil, "HTTP " .. tostring(code)
  end
  if not body or body == "" then
    return nil, "empty response"
  end
  return body, nil
end

---@param data any
---@return boolean ok
---@return string|nil err
local function validateManifest(data)
  if type(data) ~= "table" then
    return false, "manifest is not a JSON object"
  end
  if type(data.version) ~= "string" or not data.version:match("^%d+%.%d+%.%d+$") then
    return false, "manifest has no valid version"
  end
  if type(data.files) ~= "table" or type(data.roles) ~= "table" then
    return false, "manifest lists no files"
  end
  for name, path in pairs(data.files) do
    if type(name) ~= "string" or type(path) ~= "string" or name:find("[/\\]") or name:find("%.%.") then
      return false, "manifest contains an invalid file entry"
    end
  end
  for role, list in pairs(data.roles) do
    if type(role) ~= "string" or type(list) ~= "table" then
      return false, "manifest contains an invalid role"
    end
    for _, name in ipairs(list) do
      if data.files[name] == nil then
        return false, "role " .. role .. " needs unknown file " .. tostring(name)
      end
    end
  end
  return true, nil
end

---@return Manifest|nil
---@return string|nil err
local function fetchManifest()
  local body, err = download(baseUrl() .. MANIFEST)
  if not body then
    return nil, "cannot download the manifest: " .. tostring(err)
  end
  local decode = textutils.unserialiseJSON or textutils.unserializeJSON
  if not decode then
    return nil, "this CC: Tweaked version cannot read JSON"
  end
  local okDecode, data = pcall(decode, body)
  if not okDecode then
    return nil, "manifest is not valid JSON"
  end
  local ok, validateErr = validateManifest(data)
  if not ok then
    return nil, validateErr
  end
  return data, nil
end

--- Replace several files so that either all or none are updated.
---@param contents table<string, string>
---@return boolean ok
---@return string|nil err
local function writeAll(contents)
  local written = {}
  for name, body in pairs(contents) do
    local handle, err = fs.open(name .. ".new", "w")
    if not handle then
      for _, done in ipairs(written) do
        fs.delete(done .. ".new")
      end
      return false, "cannot write " .. name .. ": " .. tostring(err)
    end
    handle.write(body)
    handle.close()
    written[#written + 1] = name
  end
  for _, name in ipairs(written) do
    if fs.exists(name) then
      fs.delete(name)
    end
    fs.move(name .. ".new", name)
  end
  return true, nil
end

---@class UpdateOptions
---@field role string "miner", "monitor", "follower" or "station"
---@field current string Version of the calling program
---@field stateFormat integer|nil Save format of a running job
---@field jobActive boolean|nil A job is saved and waits to be resumed
---@field force boolean|nil Reinstall even if the version is the same

--- Check for a newer version and install it.
---@param opts UpdateOptions
---@return string status "updated", "current", "skipped" or "failed"
---@return string message
---@return string|nil version Version that was installed
local function check(opts)
  if not http then
    return "skipped", "http API is disabled", nil
  end
  local manifest, err = fetchManifest()
  if not manifest then
    return "failed", tostring(err), nil
  end
  if not opts.force and compareVersions(manifest.version, opts.current) <= 0 then
    return "current", "version " .. opts.current .. " is up to date", nil
  end
  if opts.jobActive and manifest.stateFormat ~= opts.stateFormat then
    return "skipped",
      "version " .. manifest.version .. " cannot continue the running job, it is installed when the job is finished",
      nil
  end
  local names = manifest.roles[opts.role]
  if type(names) ~= "table" or #names == 0 then
    return "failed", "manifest has no files for role " .. tostring(opts.role), nil
  end
  local contents = {}
  for _, name in ipairs(names) do
    local body, downloadErr = download(baseUrl() .. manifest.files[name])
    if not body then
      return "failed", "cannot download " .. name .. ": " .. tostring(downloadErr), nil
    end
    -- Never install a file that does not even compile (e.g. an error page)
    local chunk, syntaxErr = load(body, "=" .. name, "t", {})
    if not chunk then
      return "failed", name .. " is not valid Lua: " .. tostring(syntaxErr), nil
    end
    contents[name] = body
  end
  local ok, writeErr = writeAll(contents)
  if not ok then
    return "failed", tostring(writeErr), nil
  end
  return "updated", "installed version " .. manifest.version, manifest.version
end

---@class AutoUpdateOptions : UpdateOptions
---@field program string Path of the running program, restarted after an update
---@field args string[] Arguments to pass on to the restarted program
---@field shell table The calling program's shell API

--- Called by the programs on start. Restarts the program after an update.
---@param opts AutoUpdateOptions
---@return boolean restarted The new version ran and the caller must stop
local function autoUpdate(opts)
  if settings and settings.get(SETTING_AUTO) == false then
    return false
  end
  print("Checking for updates ...")
  local ok, status, message = pcall(check, opts)
  if not ok then
    printError("Update check failed: " .. tostring(status))
    return false
  end
  if status == "updated" then
    print("Updated: " .. message .. ", restarting")
    local args = { "--no-update" }
    for _, arg in ipairs(opts.args or {}) do
      args[#args + 1] = arg
    end
    local unpackArgs = rawget(table, "unpack") or unpack
    opts.shell.run(opts.program, unpackArgs(args))
    return true
  elseif status == "failed" then
    printError("Update failed: " .. message)
  elseif status == "skipped" then
    print("Update skipped: " .. message)
  end
  return false
end

--- Remove "--no-update" from an argument list.
---@param argv string[]
---@return string[] args
---@return boolean noUpdate
local function stripFlag(argv)
  local args, noUpdate = {}, false
  for _, arg in ipairs(argv) do
    if arg == "--no-update" then
      noUpdate = true
    else
      args[#args + 1] = arg
    end
  end
  return args, noUpdate
end

---@return string
local function detectRole()
  if fs.exists("follower.lua") then
    return "follower"
  elseif fs.exists("station.lua") then
    return "station"
  elseif turtle then
    return "miner"
  end
  return "monitor"
end

---@param argv string[]
local function main(argv)
  local role, force = nil, false
  for _, arg in ipairs(argv) do
    if arg == "--force" then
      force = true
    elseif arg == "miner" or arg == "monitor" or arg == "follower" or arg == "station" then
      role = arg
    else
      printError("Unknown argument: " .. arg)
      print("Usage: update [miner|monitor|follower|station] [--force]")
      return
    end
  end
  role = role or detectRole()
  local current = "0.0.0"
  if not force then
    -- The version of the installed main program decides
    local files = { miner = "miner.lua", monitor = "minermon.lua", follower = "follower.lua", station = "station.lua" }
    local handle = fs.exists(files[role]) and fs.open(files[role], "r") or nil
    if handle then
      local text = handle.readAll() or ""
      handle.close()
      current = text:match('local VERSION = "([%d%.]+)"') or current
    end
  end
  -- A saved miner job must stay readable for the new version
  local jobActive, stateFormat = false, nil
  if fs.exists("miner.state") then
    local handle = fs.open("miner.state", "r")
    if handle then
      local saved = textutils.unserialize(handle.readAll() or "")
      handle.close()
      if type(saved) == "table" then
        jobActive, stateFormat = true, saved.format
      end
    end
  end
  print("Updating role '" .. role .. "' (installed " .. current .. ")")
  local status, message = check({
    role = role,
    current = current,
    force = force,
    jobActive = jobActive,
    stateFormat = stateFormat,
  })
  if status == "failed" then
    printError(message)
  else
    print(message)
  end
end

local M = {
  VERSION = VERSION,
  compareVersions = compareVersions,
  validateManifest = validateManifest,
  check = check,
  autoUpdate = autoUpdate,
  stripFlag = stripFlag,
}

local args = { ... }
if args[1] == "--lib" then
  return M
end
main(args)
