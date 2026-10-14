-- cc-ender-miner - installer
-- Copyright (C) 2026 Julian Schäfer
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Usage:  install [miner|monitor] [--startup]
-- Without a target, turtles get the miner and computers get the monitor.

local BASE_URL = "https://raw.githubusercontent.com/SoulofSorrow/cc-ender-miner/main/src/"

---@class InstallFile
---@field source string Path below src/ in the repository
---@field dest string Path on the computer

---@class InstallTarget
---@field program string Program name on the computer
---@field files InstallFile[]

---@type table<string, InstallTarget>
local TARGETS = {
  miner = {
    program = "miner",
    files = {
      { source = "miner.lua", dest = "miner.lua" },
      { source = "endermine/util.lua", dest = "endermine/util.lua" },
      { source = "endermine/config.lua", dest = "endermine/config.lua" },
      { source = "endermine/store.lua", dest = "endermine/store.lua" },
      { source = "endermine/geometry.lua", dest = "endermine/geometry.lua" },
      { source = "endermine/wizard.lua", dest = "endermine/wizard.lua" },
    },
  },
  monitor = {
    program = "minermon",
    files = { { source = "minermon.lua", dest = "minermon.lua" } },
  },
}

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
  local targetName = nil
  local startup = false
  for _, arg in ipairs(argv) do
    if arg == "--startup" then
      startup = true
    elseif TARGETS[arg] then
      targetName = arg
    else
      printError("Unknown argument: " .. arg)
      print("Usage: install [miner|monitor] [--startup]")
      return false
    end
  end
  targetName = targetName or (turtle and "miner" or "monitor")
  local target = TARGETS[targetName]

  -- Download and check every file first so a failure leaves the old install intact
  local downloaded = {}
  for _, file in ipairs(target.files) do
    print("Downloading " .. file.source .. " ...")
    local body, err = download(BASE_URL .. file.source)
    if not body then
      printError("Download failed: " .. tostring(err))
      return false
    end
    -- Refuse obviously broken downloads (e.g. an HTML error page)
    local chunk, syntaxErr = load(body, "=" .. file.dest, "t", {})
    if not chunk then
      printError(file.source .. " is not valid Lua: " .. tostring(syntaxErr))
      return false
    end
    downloaded[#downloaded + 1] = { dest = file.dest, body = body }
  end
  for _, file in ipairs(downloaded) do
    local dir = fs.getDir(file.dest)
    if dir ~= "" and not fs.exists(dir) then
      fs.makeDir(dir)
    end
    local ok, writeErr = writeFile(file.dest, file.body)
    if not ok then
      printError("Cannot write " .. file.dest .. ": " .. tostring(writeErr))
      return false
    end
  end
  print("Installed as '" .. target.program .. "'")

  if startup then
    if fs.exists("startup.lua") then
      printError("startup.lua exists already, not overwriting it")
    else
      local line = string.format('shell.run("%s")\n', target.program)
      local okStartup, startupErr = writeFile("startup.lua", line)
      if okStartup then
        print("Created startup.lua")
      else
        printError("Cannot write startup.lua: " .. tostring(startupErr))
      end
    end
  end
  return true
end

main({ ... })
