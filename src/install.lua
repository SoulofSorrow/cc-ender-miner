-- cc-ender-miner - installer
-- Copyright (C) 2026 Julian Schäfer
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Usage:  install [miner|monitor|follower|station] [--startup]
-- Without a role, turtles get the miner and computers get the monitor.
-- Every role also gets the updater (update.lua), which keeps the programs
-- current from then on.

local BASE_URL = "https://raw.githubusercontent.com/SoulofSorrow/cc-ender-miner/main/"

---@class InstallRole
---@field files table<string, string> Local file name -> path in the repository
---@field program string Program started by --startup

---@type table<string, InstallRole>
local ROLES = {
  miner = {
    files = { ["miner.lua"] = "src/miner.lua", ["update.lua"] = "src/update.lua" },
    program = "miner",
  },
  monitor = {
    files = { ["minermon.lua"] = "src/minermon.lua", ["update.lua"] = "src/update.lua" },
    program = "minermon",
  },
  follower = {
    files = {
      ["follower.lua"] = "src/follower.lua",
      ["miner.lua"] = "src/miner.lua",
      ["update.lua"] = "src/update.lua",
    },
    program = "follower",
  },
  station = {
    files = {
      ["station.lua"] = "src/station.lua",
      ["miner.lua"] = "src/miner.lua",
      ["update.lua"] = "src/update.lua",
    },
    program = "station",
  },
}

---@return string
local function baseUrl()
  local url = settings and settings.get("endermine.update_url") or nil
  if type(url) ~= "string" or url == "" then
    url = BASE_URL
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
  local response, err = http.get(url, nil, true)
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

---@param path string
---@param content string
---@return boolean ok
---@return string|nil err
local function writeFile(path, content)
  local handle, err = fs.open(path, "wb")
  if not handle then
    return false, tostring(err)
  end
  handle.write(content)
  handle.close()
  return true, nil
end

---@param argv string[]
---@return boolean success
local function main(argv)
  local roleName = nil
  local startup = false
  for _, arg in ipairs(argv) do
    if arg == "--startup" then
      startup = true
    elseif ROLES[arg] then
      roleName = arg
    else
      printError("Unknown argument: " .. arg)
      print("Usage: install [miner|monitor|follower|station] [--startup]")
      return false
    end
  end
  roleName = roleName or (turtle and "miner" or "monitor")
  local role = ROLES[roleName]

  -- Download and check everything first, then write: no half installs
  local contents = {}
  for name, path in pairs(role.files) do
    print("Downloading " .. name .. " ...")
    local body, err = download(baseUrl() .. path)
    if not body then
      printError("Download of " .. name .. " failed: " .. tostring(err))
      return false
    end
    -- Refuse obviously broken downloads (e.g. an HTML error page)
    local chunk, syntaxErr = load(body, "=" .. name, "t", {})
    if not chunk then
      printError(name .. " is not valid Lua: " .. tostring(syntaxErr))
      return false
    end
    contents[name] = body
  end
  for name, body in pairs(contents) do
    local ok, err = writeFile(name, body)
    if not ok then
      printError("Cannot write " .. name .. ": " .. tostring(err))
      return false
    end
  end
  print("Installed role '" .. roleName .. "', start it with '" .. role.program .. "'")

  if startup then
    if fs.exists("startup.lua") then
      printError("startup.lua exists already, not overwriting it")
    else
      local line = string.format('shell.run("%s")\n', role.program)
      local ok, err = writeFile("startup.lua", line)
      if ok then
        print("Created startup.lua")
      else
        printError("Cannot write startup.lua: " .. tostring(err))
      end
    end
  end
  return true
end

main({ ... })
