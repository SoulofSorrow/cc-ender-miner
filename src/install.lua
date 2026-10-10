-- cc-ender-miner - installer
-- Copyright (C) 2026 Julian Schäfer
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Usage:  install [miner|monitor] [--startup]
-- Without a target, turtles get the miner and computers get the monitor.

local BASE_URL = "https://raw.githubusercontent.com/SoulofSorrow/cc-ender-miner/main/src/"

---@class InstallTarget
---@field source string File name in the repository
---@field program string Program name on the computer

---@type table<string, InstallTarget>
local TARGETS = {
  miner = { source = "miner.lua", program = "miner" },
  monitor = { source = "minermon.lua", program = "minermon" },
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

  print("Downloading " .. target.source .. " ...")
  local body, err = download(BASE_URL .. target.source)
  if not body then
    printError("Download failed: " .. tostring(err))
    return false
  end
  -- Refuse obviously broken downloads (e.g. an HTML error page)
  local chunk, syntaxErr = load(body, "=" .. target.program, "t", {})
  if not chunk then
    printError("Downloaded file is not valid Lua: " .. tostring(syntaxErr))
    return false
  end
  local ok, writeErr = writeFile(target.program .. ".lua", body)
  if not ok then
    printError("Cannot write " .. target.program .. ".lua: " .. tostring(writeErr))
    return false
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
