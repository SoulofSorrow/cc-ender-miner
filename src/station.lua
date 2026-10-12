-- cc-ender-miner - station: hands out ore jobs to a docked turtle
-- Copyright (C) 2026 Julian Schäfer
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Runs on the computer next to the disk drive of the dock. Jobs are created
-- on a touch monitor (or an advanced computer screen), queued, and written to
-- the floppy disk one at a time. The turtle ("miner dock") takes them,
-- mines its area and writes a report back. Areas are given out in a spiral
-- around the station, so no area is mined twice.
--
-- Needs miner.lua on this computer for the ore presets and the validation
-- ("install station" installs it).

local VERSION = "2.2.0"
local DB_FILE = "station.db"
local LIB_FILE = "miner.lua"
local DOCK_DIR = "endermine"
local POLL_SECONDS = 1
local DB_FORMAT = 1
local MIN_SIZE = 18
local MAX_SIZE = 90
local SIZE_STEP = 9
local MAX_BATCH = 9
local DEFAULT_OWN_Y = 16
local MIN_OWN_Y = -60
local MAX_OWN_Y = 319

-- Vanilla ores and the level preset (key in ORE_PRESETS) that suits them.
-- Ores of other mods are added as soon as the turtle reports them.
local VANILLA_ORES = {
  { key = "diamond", label = "Diamond", preset = "diamond" },
  { key = "redstone", label = "Redstone", preset = "diamond" },
  { key = "gold", label = "Gold", preset = "gold" },
  { key = "lapis", label = "Lapis", preset = "lapis" },
  { key = "iron", label = "Iron", preset = "iron" },
  { key = "copper", label = "Copper", preset = "copper" },
  { key = "coal", label = "Coal", preset = "coal" },
  { key = "emerald", label = "Emerald", preset = nil },
}

local FINISHED = { done = true, error = true, cancelled = true, rejected = true }

---@class StationJob
---@field id integer
---@field cell integer[] {i, j} area cell in the spiral around the dock
---@field levels integer[] Absolute Y levels
---@field ores string[]|nil Kinds of ore to mine (see oreKey in miner.lua), nil for every ore
---@field size integer Width and length of the area
---@field status string queued, sent, running, done, error, rejected or cancelled
---@field created number
---@field result table|nil Report of the turtle when the job ended

---@class StationDb
---@field format integer
---@field startY integer|nil Y of the docked turtle
---@field areaSize integer
---@field nextId integer
---@field jobs StationJob[]
---@field turtle table|nil Last report of the turtle
---@field knownOres table<string, boolean> Kinds of ore the turtle has found, besides the vanilla ones

---@return number
local function now()
  if os.epoch then
    return os.epoch("utc") / 1000
  end
  return os.clock()
end

---@param path string
---@param text string
---@return boolean ok
---@return string|nil err
local function writeAtomic(path, text)
  local handle, err = fs.open(path .. ".new", "w")
  if not handle then
    return false, tostring(err)
  end
  handle.write(text)
  handle.close()
  if fs.exists(path) then
    fs.delete(path)
  end
  fs.move(path .. ".new", path)
  return true, nil
end

---@param path string
---@return table|nil
local function readTable(path)
  for _, candidate in ipairs({ path, path .. ".new" }) do
    if fs.exists(candidate) then
      local handle = fs.open(candidate, "r")
      if handle then
        local data = textutils.unserialize(handle.readAll() or "")
        handle.close()
        if type(data) == "table" then
          return data
        end
      end
    end
  end
  return nil
end

--- Cells of the ring with distance r around the dock cell, in walking order.
---@param r integer
---@return integer[][]
local function ring(r)
  if r == 0 then
    return { { 0, 0 } }
  end
  local cells = {}
  for j = -r + 1, r do
    cells[#cells + 1] = { r, j }
  end
  for i = r - 1, -r, -1 do
    cells[#cells + 1] = { i, r }
  end
  for j = r - 1, -r, -1 do
    cells[#cells + 1] = { -r, j }
  end
  for i = -r + 1, r do
    cells[#cells + 1] = { i, -r }
  end
  return cells
end

---@param text any
---@param width integer
---@return string
local function truncate(text, width)
  text = tostring(text or "")
  if width <= 0 then
    return ""
  end
  if #text <= width then
    return text
  end
  return text:sub(1, math.max(0, width - 2)) .. ".."
end

---@param seconds number|nil
---@return string
local function fmtDuration(seconds)
  if type(seconds) ~= "number" or seconds < 0 then
    return "--"
  end
  seconds = math.floor(seconds)
  local h, m = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60)
  if h > 0 then
    return string.format("%dh %02dm", h, m)
  end
  return string.format("%dm %02ds", m, seconds % 60)
end

local STATUS_COLORS = {
  queued = colors.lightBlue,
  sent = colors.cyan,
  running = colors.yellow,
  done = colors.green,
  error = colors.red,
  rejected = colors.red,
  cancelled = colors.gray,
}

---@class StationOptions
---@field disk string Mount path of the floppy disk shared with the turtle
---@field lib table miner.lua loaded as a library
---@field dbPath string|nil
---@field now (fun(): number)|nil

---@param opts StationOptions
---@return table station
local function createStation(opts)
  local self = {}
  local lib = opts.lib
  local clock = opts.now or now
  local dbPath = opts.dbPath or DB_FILE
  local db = readTable(dbPath)
  if type(db) ~= "table" or db.format ~= DB_FORMAT then
    db = { format = DB_FORMAT, startY = nil, areaSize = 45, nextId = 1, jobs = {}, turtle = nil }
  end
  db.knownOres = type(db.knownOres) == "table" and db.knownOres or {}
  local vanillaKeys = {}
  for _, ore in ipairs(VANILLA_ORES) do
    vanillaKeys[ore.key] = true
  end

  -- Touch UI state
  local ui = {
    screen = "main",
    selected = {},
    size = db.areaSize,
    count = 1,
    ores = {},
    ownY = DEFAULT_OWN_Y,
    ownOn = false,
    orePage = 1,
    message = "",
    buttons = {},
  }

  local function save()
    local ok, err = pcall(writeAtomic, dbPath, textutils.serialize(db))
    if not ok then
      ui.message = "Cannot save " .. dbPath .. ": " .. tostring(err)
    end
  end

  ---@param name string
  ---@return string
  local function diskFile(name)
    return opts.disk .. "/" .. DOCK_DIR .. "/" .. name
  end

  ---@param i integer
  ---@param j integer
  ---@return StationJob|nil
  local function jobAt(i, j)
    for k = #db.jobs, 1, -1 do
      local job = db.jobs[k]
      if job.cell[1] == i and job.cell[2] == j and job.status ~= "cancelled" and job.status ~= "rejected" then
        return job
      end
    end
    return nil
  end

  --- Next free area cell, walking outwards in rings around the dock.
  ---@return integer[]
  local function nextCell()
    for r = 0, 1000 do
      for _, cell in ipairs(ring(r)) do
        if not jobAt(cell[1], cell[2]) then
          return cell
        end
      end
    end
    error("no free area left", 0)
  end

  ---@param id integer
  ---@return StationJob|nil
  local function findJob(id)
    for _, job in ipairs(db.jobs) do
      if job.id == id then
        return job
      end
    end
    return nil
  end

  --- Configuration the turtle receives for a job.
  ---@param job StationJob
  ---@return table
  function self.jobConfig(job)
    return {
      mode = "ores",
      startY = db.startY,
      oreLevels = job.levels,
      areaWidth = job.size,
      areaLength = job.size,
      areaOffsetX = job.cell[1] * job.size,
      areaOffsetZ = job.cell[2] * job.size,
      side = "right",
      returnHome = true,
      -- The station decides what is mined, a filter in miner.cfg does not apply
      oreGroups = job.ores or {},
      oreNames = {},
    }
  end

  --- Remember the kinds of ore in a report of the turtle.
  ---@param stats any
  ---@return boolean changed
  local function learnOres(stats)
    if type(stats) ~= "table" then
      return false
    end
    local names = {}
    if type(stats.seen) == "table" then
      for _, name in ipairs(stats.seen) do
        names[#names + 1] = name
      end
    end
    if type(stats.ores) == "table" then
      for _, ore in ipairs(stats.ores) do
        if type(ore) == "table" then
          names[#names + 1] = ore.name
        end
      end
    end
    local changed = false
    for _, name in ipairs(names) do
      if type(name) == "string" then
        local key = lib.oreKey(name)
        if not vanillaKeys[key] and not db.knownOres[key] then
          db.knownOres[key] = true
          changed = true
        end
      end
    end
    return changed
  end

  --- Ores to choose from: the vanilla ones, then the ones found in the world.
  ---@return table[] {key, label, preset}
  function self.oreChoices()
    local list = {}
    for _, ore in ipairs(VANILLA_ORES) do
      list[#list + 1] = ore
    end
    local found = {}
    for key in pairs(db.knownOres) do
      found[#found + 1] = key
    end
    table.sort(found)
    for _, key in ipairs(found) do
      local label = key:gsub("_", " "):gsub("^%l", string.upper)
      list[#list + 1] = { key = key, label = label, preset = nil }
    end
    return list
  end

  ---@param y integer
  function self.setStartY(y)
    db.startY = y
    save()
  end

  ---@return integer|nil
  function self.getStartY()
    return db.startY
  end

  --- Queue jobs for the next free areas.
  ---@param levels integer[]
  ---@param count integer
  ---@param size integer
  ---@param ores string[]|nil Kinds of ore, nil or empty for every ore
  ---@return boolean ok
  ---@return string|nil err
  function self.addJobs(levels, count, size, ores)
    if not db.startY then
      return false, "the Y of the dock is not set"
    end
    if #levels == 0 then
      return false, "choose at least one level"
    end
    local kinds = nil
    if type(ores) == "table" and #ores > 0 then
      kinds = {}
      for _, key in ipairs(ores) do
        kinds[#kinds + 1] = key
      end
      table.sort(kinds)
    end
    for _ = 1, count do
      local job = {
        id = db.nextId,
        cell = nextCell(),
        levels = levels,
        ores = kinds,
        size = size,
        status = "queued",
        created = clock(),
      }
      local cfg = lib.mergeConfig(lib.DEFAULT_CONFIG, self.jobConfig(job))
      local valid, errors = lib.validateConfig(cfg)
      if not valid then
        return false, table.concat(errors, "; ")
      end
      db.nextId = db.nextId + 1
      db.jobs[#db.jobs + 1] = job
    end
    db.areaSize = size
    save()
    return true, nil
  end

  --- Cancel the newest job the turtle has not taken yet.
  ---@return integer|nil id
  function self.cancelLast()
    for k = #db.jobs, 1, -1 do
      local job = db.jobs[k]
      if job.status == "queued" or job.status == "sent" then
        if job.status == "sent" then
          local onDisk = readTable(diskFile("job"))
          local ack = readTable(diskFile("ack"))
          if ack and ack.id == job.id then
            -- Taken in the meantime, too late to cancel
            job.status = "running"
            save()
            return nil
          end
          if onDisk and onDisk.id == job.id then
            fs.delete(diskFile("job"))
          end
        end
        job.status = "cancelled"
        save()
        return job.id
      end
    end
    return nil
  end

  --- Sync with the disk: acknowledgements, reports and the next job.
  function self.poll()
    local report = readTable(diskFile("report"))
    local ack = readTable(diskFile("ack"))
    local onDisk = readTable(diskFile("job"))
    local changed = false
    if type(report) == "table" then
      db.turtle = report
      if learnOres(report.stats) then
        changed = true
      end
      if type(report.result) == "table" and learnOres(report.result.stats) then
        changed = true
      end
    end
    if type(ack) == "table" and type(ack.id) == "number" then
      local job = findJob(ack.id)
      if job and job.status == "sent" then
        job.status = "running"
        job.started = ack.at
        changed = true
      end
    end
    if type(report) == "table" and report.state == "working" and type(report.jobId) == "number" then
      local job = findJob(report.jobId)
      if job and (job.status == "sent" or job.status == "queued") then
        job.status = "running"
        changed = true
      end
    end
    -- The outcome of the last job travels with every report of the turtle
    local result = type(report) == "table" and report.result or nil
    if type(result) == "table" and type(result.jobId) == "number" then
      local job = findJob(result.jobId)
      if job and not FINISHED[job.status] then
        local state = tostring(result.state)
        job.status = (state == "done" or state == "rejected") and state or "error"
        job.result = result
        changed = true
      end
    end
    -- Hand out the next job when the disk holds none or the last one was taken
    local free = onDisk == nil or (type(ack) == "table" and ack.id == onDisk.id)
    if free then
      for _, job in ipairs(db.jobs) do
        if job.status == "queued" then
          local dir = opts.disk .. "/" .. DOCK_DIR
          if not fs.exists(dir) then
            fs.makeDir(dir)
          end
          local ok = pcall(
            writeAtomic,
            diskFile("job"),
            textutils.serialize({ id = job.id, config = self.jobConfig(job), created = job.created })
          )
          if ok then
            job.status = "sent"
            changed = true
          else
            ui.message = "Cannot write to the floppy disk"
          end
          break
        end
      end
    end
    if changed then
      save()
    end
  end

  ---@return StationJob[]
  function self.getJobs()
    return db.jobs
  end

  -- Drawing -------------------------------------------------------------------

  ---@param target table
  ---@param x integer
  ---@param y integer
  ---@param w integer
  ---@param h integer
  ---@param bg integer
  local function fill(target, x, y, w, h, bg)
    if w <= 0 or h <= 0 then
      return
    end
    target.setBackgroundColor(bg)
    local line = string.rep(" ", w)
    for row = y, y + h - 1 do
      target.setCursorPos(x, row)
      target.write(line)
    end
  end

  ---@param target table
  ---@param x integer
  ---@param y integer
  ---@param text string
  ---@param fg integer
  ---@param bg integer
  local function text(target, x, y, str, fg, bg)
    target.setBackgroundColor(bg)
    target.setTextColor(fg)
    target.setCursorPos(x, y)
    target.write(str)
  end

  ---@param target table
  ---@param x integer
  ---@param y integer
  ---@param w integer
  ---@param label string
  ---@param color integer
  ---@param action function
  local function button(target, x, y, w, label, color, action)
    fill(target, x, y, w, 1, color)
    local str = truncate(label, w)
    text(target, x + math.floor((w - #str) / 2), y, str, colors.black, color)
    ui.buttons[#ui.buttons + 1] = { x1 = x, y1 = y, x2 = x + w - 1, y2 = y, action = action }
  end

  ---@param levels integer[]
  ---@return string
  local function levelText(levels)
    local parts = {}
    for _, y in ipairs(levels) do
      parts[#parts + 1] = tostring(y)
    end
    return "Y " .. table.concat(parts, ",")
  end

  ---@param target table
  ---@param x integer
  ---@param y integer
  ---@param w integer
  ---@param maxY integer
  ---@return integer nextY
  local function drawTurtle(target, x, y, w, maxY)
    local r = db.turtle
    text(target, x, y, truncate("TURTLE", w), colors.yellow, colors.black)
    y = y + 1
    if type(r) ~= "table" then
      text(target, x, y, truncate("No report yet - start 'miner dock'", w), colors.gray, colors.black)
      return y + 1
    end
    local age = clock() - (tonumber(r.at) or 0)
    local lines = {
      { tostring(r.state):upper() .. "  " .. tostring(r.message or ""), STATUS_COLORS[r.state] or colors.white },
      { "Job #" .. tostring(r.jobId or "-") .. "  fuel " .. tostring(r.fuel or "?"), colors.lightGray },
      { "Report " .. fmtDuration(age) .. " ago", colors.gray },
    }
    if r.version ~= nil and r.version ~= VERSION then
      -- An older miner ignores settings it does not know, e.g. the ore kinds
      table.insert(lines, 1, { "Turtle runs " .. tostring(r.version) .. ", run 'update'", colors.red })
    end
    if type(r.stats) == "table" then
      lines[#lines + 1] = {
        string.format("Last: %s blocks, %s", tostring(r.stats.mined or 0), fmtDuration(r.stats.uptime)),
        colors.lightGray,
      }
      if type(r.stats.ores) == "table" then
        for i, ore in ipairs(r.stats.ores) do
          if i > 3 then
            break
          end
          local name = tostring(ore.name):gsub("^[%w_%-%.]+:", ""):gsub("_ore$", ""):gsub("_", " ")
          lines[#lines + 1] = { string.format("  %-14s %d", name, tonumber(ore.count) or 0), colors.white }
        end
      end
    end
    for _, line in ipairs(lines) do
      if y > maxY then
        break
      end
      text(target, x, y, truncate(line[1], w), line[2], colors.black)
      y = y + 1
    end
    return y
  end

  ---@param target table
  ---@param x integer
  ---@param y integer
  ---@param w integer
  ---@param maxY integer
  ---@return integer nextY
  local function drawJobs(target, x, y, w, maxY)
    text(target, x, y, truncate("JOBS", w), colors.yellow, colors.black)
    y = y + 1
    local shown = 0
    for k = #db.jobs, 1, -1 do
      if y > maxY then
        break
      end
      local job = db.jobs[k]
      if job.status ~= "cancelled" or shown < 3 then
        local line = string.format(
          "#%-3d %-9s %s %s %dx%d @%d,%d",
          job.id,
          job.status,
          levelText(job.levels),
          job.ores and table.concat(job.ores, ",") or "all",
          job.size,
          job.size,
          job.cell[1],
          job.cell[2]
        )
        text(target, x, y, truncate(line, w), STATUS_COLORS[job.status] or colors.white, colors.black)
        y = y + 1
        shown = shown + 1
      end
    end
    if shown == 0 and y <= maxY then
      text(target, x, y, truncate("No jobs yet - tap NEW JOB", w), colors.gray, colors.black)
      y = y + 1
    end
    return y
  end

  ---@param target table
  ---@param x integer
  ---@param y integer
  ---@param w integer
  ---@param h integer
  local function drawMap(target, x, y, w, h)
    text(target, x, y, truncate("AREAS (D = station)", w), colors.yellow, colors.black)
    local cols = math.floor(w / 2)
    local rows = h - 2
    local radiusX = math.floor((cols - 1) / 2)
    local radiusZ = math.floor((rows - 1) / 2)
    -- Job z grows away from the station, so it is drawn upwards
    for dz = radiusZ, -radiusZ, -1 do
      local row = y + 1 + (radiusZ - dz)
      for dx = -radiusX, radiusX do
        local col = x + (dx + radiusX) * 2
        local job = jobAt(dx, dz)
        local color = job and (STATUS_COLORS[job.status] or colors.white) or colors.gray
        local mark = job and "##" or " ."
        if dx == 0 and dz == 0 and not job then
          mark = " D"
        elseif dx == 0 and dz == 0 then
          mark = "D#"
        end
        text(target, col, row, mark, color, colors.black)
      end
    end
    local legend = "green done  yellow running  blue queued"
    text(target, x, y + h - 1, truncate(legend, w), colors.lightGray, colors.black)
  end

  ---@param target table
  ---@param w integer
  ---@param h integer
  local function drawMain(target, w, h)
    local bottom = h - 2
    if w >= 60 then
      local leftW = math.floor(w / 2) - 1
      local nextY = drawTurtle(target, 2, 3, leftW, bottom)
      drawJobs(target, 2, nextY + 1, leftW, bottom)
      drawMap(target, leftW + 3, 3, w - leftW - 3, bottom - 2)
    else
      local nextY = drawTurtle(target, 2, 3, w - 2, bottom)
      local mapH = math.max(0, math.floor((bottom - nextY) / 2))
      local afterJobs = drawJobs(target, 2, nextY + 1, w - 2, bottom - mapH)
      if mapH >= 5 then
        drawMap(target, 2, afterJobs + 1, w - 2, mapH)
      end
    end
    local bw = math.floor((w - 4) / 3)
    button(target, 2, h, bw, "NEW JOB", colors.green, function()
      if not db.startY then
        ui.message = "Set the dock Y on the computer first"
        return
      end
      ui.screen = "new"
      ui.message = ""
    end)
    button(target, 3 + bw, h, bw, "CANCEL", colors.orange, function()
      local id = self.cancelLast()
      ui.message = id and ("Job #" .. id .. " cancelled") or "Nothing to cancel"
    end)
    button(target, 4 + 2 * bw, h, w - 4 - 2 * bw, "REFRESH", colors.lightBlue, function()
      self.poll()
    end)
  end

  ---@return integer[] levels Chosen levels, presets first
  local function chosenLevels()
    local levels = {}
    local seen = {}
    for i, preset in ipairs(lib.ORE_PRESETS) do
      if ui.selected[i] and not seen[preset.y] then
        levels[#levels + 1] = preset.y
        seen[preset.y] = true
      end
    end
    if ui.ownOn and not seen[ui.ownY] then
      levels[#levels + 1] = ui.ownY
    end
    return levels
  end

  ---@return string[] keys Chosen kinds of ore, empty for every ore
  local function chosenOres()
    local keys = {}
    for key in pairs(ui.ores) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
  end

  ---@param presetKey string|nil
  local function selectPreset(presetKey)
    for i, preset in ipairs(lib.ORE_PRESETS) do
      if preset.key == presetKey then
        ui.selected[i] = true
      end
    end
  end

  ---@param target table
  ---@param w integer
  ---@param h integer
  local function drawNew(target, w, h)
    text(target, 2, 3, truncate("NEW JOB - levels, size, ores", w - 2), colors.yellow, colors.black)
    local gap = h >= 30 and 2 or 1
    local y = 5
    local cols = w >= 40 and 2 or 1
    local bw = math.floor((w - 2 - (cols - 1)) / cols)
    for i, preset in ipairs(lib.ORE_PRESETS) do
      local col = (i - 1) % cols
      local row = math.floor((i - 1) / cols)
      local on = ui.selected[i] == true
      local label = string.format("%s Y%d", preset.label, preset.y)
      button(target, 2 + col * (bw + 1), y + row * gap, bw, label, on and colors.lime or colors.gray, function()
        ui.selected[i] = not ui.selected[i] or nil
      end)
    end
    y = y + math.ceil(#lib.ORE_PRESETS / cols) * gap + 1

    -- Own level, e.g. for ores of other mods
    text(target, 2, y, "Own Y", colors.lightGray, colors.black)
    button(target, 8, y, 3, "--", colors.lightGray, function()
      ui.ownY = math.max(MIN_OWN_Y, ui.ownY - 10)
    end)
    button(target, 12, y, 3, "-", colors.lightGray, function()
      ui.ownY = math.max(MIN_OWN_Y, ui.ownY - 1)
    end)
    text(target, 16, y, string.format("%4d", ui.ownY), colors.white, colors.black)
    button(target, 21, y, 3, "+", colors.lightGray, function()
      ui.ownY = math.min(MAX_OWN_Y, ui.ownY + 1)
    end)
    button(target, 25, y, 3, "++", colors.lightGray, function()
      ui.ownY = math.min(MAX_OWN_Y, ui.ownY + 10)
    end)
    button(target, 29, y, 5, ui.ownOn and "ON" or "OFF", ui.ownOn and colors.lime or colors.gray, function()
      ui.ownOn = not ui.ownOn
    end)
    y = y + gap + (gap == 1 and 1 or 0)

    text(target, 2, y, "Area size", colors.lightGray, colors.black)
    button(target, 14, y, 3, "-", colors.lightGray, function()
      ui.size = math.max(MIN_SIZE, ui.size - SIZE_STEP)
    end)
    text(target, 18, y, string.format("%3dx%-3d", ui.size, ui.size), colors.white, colors.black)
    button(target, 26, y, 3, "+", colors.lightGray, function()
      ui.size = math.min(MAX_SIZE, ui.size + SIZE_STEP)
    end)
    y = y + gap + (gap == 1 and 1 or 0)
    text(target, 2, y, "Areas", colors.lightGray, colors.black)
    button(target, 14, y, 3, "-", colors.lightGray, function()
      ui.count = math.max(1, ui.count - 1)
    end)
    text(target, 18, y, string.format("%3d", ui.count), colors.white, colors.black)
    button(target, 26, y, 3, "+", colors.lightGray, function()
      ui.count = math.min(MAX_BATCH, ui.count + 1)
    end)
    y = y + gap + (gap == 1 and 1 or 0)
    local ores = chosenOres()
    local oreLabel = "ORES: " .. (#ores > 0 and table.concat(ores, ", ") or "all")
    button(target, 2, y, w - 2, oreLabel, colors.lightBlue, function()
      ui.screen = "ores"
      ui.message = ""
    end)

    local half = math.floor((w - 3) / 2)
    button(target, 2, h, half, "CREATE", colors.green, function()
      local ok, err = self.addJobs(chosenLevels(), ui.count, ui.size, chosenOres())
      if ok then
        ui.message = string.format("%d job(s) queued", ui.count)
        ui.screen = "main"
        ui.selected = {}
        ui.ores = {}
        ui.ownOn = false
        ui.count = 1
        self.poll()
      else
        ui.message = tostring(err)
      end
    end)
    button(target, 3 + half, h, w - 3 - half, "BACK", colors.orange, function()
      ui.screen = "main"
      ui.message = ""
    end)
  end

  ---@param target table
  ---@param w integer
  ---@param h integer
  local function drawOres(target, w, h)
    text(target, 2, 3, truncate("ORES - none chosen = every ore", w - 2), colors.yellow, colors.black)
    local choices = self.oreChoices()
    local gap = h >= 30 and 2 or 1
    local cols = math.max(1, math.floor((w - 1) / 17))
    local bw = math.floor((w - 2 - (cols - 1)) / cols)
    local rows = math.max(1, math.floor((h - 3 - 5) / gap) + 1)
    local perPage = rows * cols
    local pages = math.max(1, math.ceil(#choices / perPage))
    ui.orePage = math.min(math.max(ui.orePage, 1), pages)
    local first = (ui.orePage - 1) * perPage + 1
    for i = first, math.min(#choices, first + perPage - 1) do
      local ore = choices[i]
      local index = i - first
      local col = index % cols
      local row = math.floor(index / cols)
      local on = ui.ores[ore.key] == true
      button(target, 2 + col * (bw + 1), 5 + row * gap, bw, ore.label, on and colors.lime or colors.gray, function()
        if ui.ores[ore.key] then
          ui.ores[ore.key] = nil
        else
          ui.ores[ore.key] = true
          -- Suggest the level where this ore is most common
          selectPreset(ore.preset)
        end
      end)
    end
    if #choices == #VANILLA_ORES and h - 2 > 5 + rows * gap then
      text(target, 2, h - 2, truncate("Ores of other mods appear after a job", w - 2), colors.gray, colors.black)
    end
    local bwBottom = math.floor((w - 5) / 4)
    button(target, 2, h, bwBottom, "ALL", colors.lightBlue, function()
      ui.ores = {}
    end)
    button(target, 3 + bwBottom, h, bwBottom, "<", colors.lightGray, function()
      ui.orePage = math.max(1, ui.orePage - 1)
    end)
    button(target, 4 + 2 * bwBottom, h, bwBottom, ui.orePage .. "/" .. pages .. " >", colors.lightGray, function()
      ui.orePage = math.min(pages, ui.orePage + 1)
    end)
    button(target, 5 + 3 * bwBottom, h, w - 4 - 3 * bwBottom, "DONE", colors.green, function()
      ui.screen = "new"
    end)
  end

  ---@param target table Monitor or terminal
  function self.render(target)
    local w, h = target.getSize()
    ui.buttons = {}
    fill(target, 1, 1, w, h, colors.black)
    fill(target, 1, 1, w, 1, colors.blue)
    text(target, 2, 1, truncate("ENDER STATION " .. VERSION, w - 2), colors.white, colors.blue)
    local queued = 0
    for _, job in ipairs(db.jobs) do
      if job.status == "queued" or job.status == "sent" then
        queued = queued + 1
      end
    end
    local right = string.format("%d waiting  Y %s", queued, tostring(db.startY or "?"))
    if #right + 22 <= w then
      text(target, w - #right, 1, right, colors.lightBlue, colors.blue)
    end
    if ui.screen == "new" then
      drawNew(target, w, h)
    elseif ui.screen == "ores" then
      drawOres(target, w, h)
    else
      drawMain(target, w, h)
    end
    if ui.message ~= "" then
      text(target, 2, h - 1, truncate(ui.message, w - 2), colors.orange, colors.black)
    end
  end

  ---@param x integer
  ---@param y integer
  ---@return boolean handled
  function self.handleTouch(x, y)
    for _, area in ipairs(ui.buttons) do
      if x >= area.x1 and x <= area.x2 and y >= area.y1 and y <= area.y2 then
        area.action()
        return true
      end
    end
    return false
  end

  ---@return string
  function self.getScreen()
    return ui.screen
  end

  return self
end

-- Program ---------------------------------------------------------------------

---@return table|nil lib
---@return string|nil err
local function loadLib()
  if not fs.exists(LIB_FILE) then
    return nil, LIB_FILE .. " is missing, install it with 'install station'"
  end
  local chunk, err = loadfile(LIB_FILE)
  if not chunk then
    return nil, "cannot load " .. LIB_FILE .. ": " .. tostring(err)
  end
  local ok, lib = pcall(chunk, "--lib")
  if not ok or type(lib) ~= "table" or type(lib.ORE_PRESETS) ~= "table" or type(lib.oreKey) ~= "function" then
    return nil, LIB_FILE .. " is too old for the station, update it"
  end
  return lib, nil
end

---@param argv string[]
---@return boolean restarted
local function runAutoUpdate(argv)
  if not shell or not fs.exists("update.lua") then
    return false
  end
  local chunk = loadfile("update.lua")
  if not chunk then
    return false
  end
  local ok, updater = pcall(chunk, "--lib")
  if not ok or type(updater) ~= "table" or type(updater.autoUpdate) ~= "function" then
    return false
  end
  return updater.autoUpdate({
    role = "station",
    current = VERSION,
    program = shell.getRunningProgram(),
    args = argv,
    shell = shell,
  })
end

---@param rawArgs string[]
local function main(rawArgs)
  local argv, noUpdate = {}, false
  for _, arg in ipairs(rawArgs) do
    if arg == "--no-update" then
      noUpdate = true
    else
      argv[#argv + 1] = arg
    end
  end
  if not noUpdate and runAutoUpdate(argv) then
    return
  end
  local lib, libErr = loadLib()
  if not lib then
    printError(libErr)
    return
  end
  local drive = peripheral.find("drive")
  if not drive or not drive.isDiskPresent() or not drive.getMountPath() then
    printError("Put a floppy disk into the disk drive between this computer and the turtle.")
    return
  end
  pcall(drive.setDiskLabel, "Ender Station")
  local station = createStation({ disk = drive.getMountPath(), lib = lib })

  term.clear()
  term.setCursorPos(1, 1)
  print("Ender Station " .. VERSION)
  if not station.getStartY() then
    while true do
      write("Y of the turtle at the dock (F3): ")
      local y = tonumber(read())
      if y and y == math.floor(y) and y >= -64 and y <= 320 then
        station.setStartY(y)
        break
      end
      printError("Enter a whole number between -64 and 320")
    end
  end

  local mon = peripheral.find("monitor")
  local monitorName = mon and peripheral.getName(mon) or nil
  if mon then
    pcall(mon.setTextScale, tonumber(argv[1]) or 0.5)
  end
  local target = mon or term.current()
  print(mon and ("Touch the monitor " .. monitorName .. " to create jobs.") or "Click the screen to create jobs.")
  print("Press Q to quit.")

  local function draw()
    local ok, err = pcall(station.render, target)
    if not ok then
      printError("Render error: " .. tostring(err))
    end
  end

  station.poll()
  draw()
  local timer = os.startTimer(POLL_SECONDS)
  while true do
    local ev = { os.pullEventRaw() }
    local name = ev[1]
    if name == "terminate" or (name == "key" and ev[2] == keys.q and mon) then
      break
    elseif name == "timer" and ev[2] == timer then
      local ok, err = pcall(station.poll)
      if not ok then
        printError("Disk error: " .. tostring(err))
      end
      draw()
      timer = os.startTimer(POLL_SECONDS)
    elseif name == "monitor_touch" and ev[2] == monitorName then
      if station.handleTouch(ev[3], ev[4]) then
        draw()
      end
    elseif name == "mouse_click" and not mon then
      if station.handleTouch(ev[3], ev[4]) then
        draw()
      end
    elseif name == "peripheral" or name == "peripheral_detach" then
      mon = peripheral.find("monitor")
      monitorName = mon and peripheral.getName(mon) or nil
      if mon then
        pcall(mon.setTextScale, tonumber(argv[1]) or 0.5)
      end
      target = mon or term.current()
      draw()
    end
  end
  if mon then
    mon.setBackgroundColor(colors.black)
    mon.clear()
  end
  print("Station stopped.")
end

local M = {
  VERSION = VERSION,
  ring = ring,
  createStation = createStation,
}

local args = { ... }
if args[1] == "--lib" then
  return M
end
main(args)
