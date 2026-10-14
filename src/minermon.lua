-- cc-ender-miner - monitor dashboard for ender miner turtles
-- Copyright (C) 2026 Julian Schäfer
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Runs on a computer with a wireless or ender modem and an (advanced)
-- monitor, e.g. 4x4 blocks. Shows the telemetry of every turtle running
-- miner.lua and sends pause/resume/home commands on touch.

local VERSION = "3.0.0"
local PROTOCOL = "endermine.v1"
local SECRET_FILE = "minermon.secret"
local DEFAULT_SCALE = 0.5
local STALE_AFTER = 15
local MAX_EVENTS = 40
local CONFIRM_SECONDS = 5

local FACING = { [0] = "forward", [1] = "right", [2] = "back", [3] = "left" }

---@class StateStyle
---@field label string
---@field color integer

---@type table<string, StateStyle>
local STATE_STYLES = {
  starting = { label = "STARTING", color = colors.lightGray },
  resuming = { label = "RESUMING", color = colors.lightBlue },
  lost = { label = "LOST", color = colors.red },
  mining = { label = "MINING", color = colors.green },
  dumping = { label = "UNLOADING", color = colors.purple },
  resupply = { label = "RESUPPLY", color = colors.purple },
  returning = { label = "RETURNING", color = colors.cyan },
  paused = { label = "PAUSED", color = colors.yellow },
  no_fuel = { label = "NO FUEL", color = colors.orange },
  chest_full = { label = "CHEST FULL", color = colors.orange },
  done = { label = "DONE", color = colors.lightBlue },
  aborted = { label = "ABORTED", color = colors.orange },
  stopped = { label = "STOPPED", color = colors.red },
  error = { label = "ERROR", color = colors.red },
  offline = { label = "NO SIGNAL", color = colors.gray },
}

local ORE_COLORS = {
  { "diamond", colors.lightBlue },
  { "emerald", colors.lime },
  { "gold", colors.yellow },
  { "iron", colors.lightGray },
  { "copper", colors.orange },
  { "redstone", colors.red },
  { "lapis", colors.blue },
  { "coal", colors.gray },
  { "quartz", colors.white },
  { "debris", colors.brown },
}

local BUTTONS = {
  { label = "PAUSE", short = "PAU", cmd = "pause", color = colors.yellow },
  { label = "RESUME", short = "GO", cmd = "resume", color = colors.green },
  { label = "HOME", short = "HOM", cmd = "home", color = colors.orange, confirm = true },
  { label = "REFRESH", short = "UPD", cmd = "ping", color = colors.lightBlue },
}

---@param value any
---@param default number|nil
---@return number
local function num(value, default)
  if type(value) == "number" and value == value then
    return value
  end
  return default or 0
end

---@param value number
---@param low number
---@param high number
---@return number
local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
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
  if width <= 2 then
    return text:sub(1, width)
  end
  return text:sub(1, width - 2) .. ".."
end

---@param value number
---@return string
local function fmtNumber(value)
  local text = tostring(math.floor(value))
  local formatted, count = text, 1
  while count > 0 do
    formatted, count = formatted:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
  end
  return formatted
end

---@param seconds number|nil
---@return string
local function fmtDuration(seconds)
  if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 or seconds == math.huge then
    return "--"
  end
  seconds = math.floor(seconds)
  local h = math.floor(seconds / 3600)
  local m = math.floor(seconds % 3600 / 60)
  local s = seconds % 60
  if h > 0 then
    return string.format("%dh %02dm", h, m)
  elseif m > 0 then
    return string.format("%dm %02ds", m, s)
  end
  return string.format("%ds", s)
end

---@param id string
---@return string
local function prettyName(id)
  local name = tostring(id or "?"):gsub("^[%w_%-%.]+:", "")
  name = name:gsub("_ore$", ""):gsub("_", " ")
  return (name:gsub("^%l", string.upper))
end

---@param id string
---@return integer
local function oreColor(id)
  local text = tostring(id or "")
  for _, entry in ipairs(ORE_COLORS) do
    if text:find(entry[1], 1, true) then
      return entry[2]
    end
  end
  return colors.magenta
end

---@return string
local function clockText()
  if os.date then
    local ok, text = pcall(os.date, "%H:%M:%S")
    if ok and type(text) == "string" then
      return text
    end
  end
  return ""
end

---@class Canvas
---@field fill fun(x: integer, y: integer, w: integer, h: integer, bg: integer)
---@field text fun(x: integer, y: integer, s: string, fg: integer, bg: integer)
---@field bar fun(x: integer, y: integer, w: integer, ratio: number, fg: integer, bg: integer)

---@param target table Monitor, window or terminal object
---@return Canvas
local function newCanvas(target)
  local cv = {}
  function cv.fill(x, y, w, h, bg)
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
  function cv.text(x, y, s, fg, bg)
    target.setBackgroundColor(bg)
    target.setTextColor(fg)
    target.setCursorPos(x, y)
    target.write(s)
  end
  function cv.bar(x, y, w, ratio, fg, bg)
    local filled = math.floor(w * clamp(num(ratio), 0, 1) + 0.5)
    cv.fill(x, y, filled, 1, fg)
    cv.fill(x + filled, y, w - filled, 1, bg)
  end
  return cv
end

---@param cv Canvas
---@param x integer
---@param y integer
---@param w integer
---@param maxY integer
---@param rows table[]
---@return integer nextY
local function drawRows(cv, x, y, w, maxY, rows)
  for _, row in ipairs(rows) do
    if y > maxY then
      break
    end
    if row.kind == "gap" then
      y = y + 1
    elseif row.kind == "title" then
      cv.text(x, y, truncate(row.text, w), row.color or colors.white, colors.black)
      y = y + 1
    elseif row.kind == "badge" then
      local badge = " " .. row.label .. " "
      cv.text(x, y, badge, colors.black, row.color)
      local rest = w - #badge - 1
      if rest > 0 then
        cv.text(x + #badge + 1, y, truncate(row.text, rest), colors.lightGray, colors.black)
      end
      y = y + 1
    elseif row.kind == "kv" then
      local key = truncate(row.key, w)
      cv.text(x, y, key, colors.lightGray, colors.black)
      local value = truncate(row.value, w - #key - 1)
      if #value > 0 then
        cv.text(x + w - #value, y, value, row.color or colors.white, colors.black)
      end
      y = y + 1
    elseif row.kind == "bar" then
      cv.bar(x, y, w, row.ratio, row.color, colors.gray)
      y = y + 1
    end
  end
  return y
end

---@param cv Canvas
---@param x integer
---@param y integer
---@param w integer
---@param maxY integer
---@param ores any
---@return integer nextY
local function drawOres(cv, x, y, w, maxY, ores)
  if y > maxY then
    return y
  end
  cv.text(x, y, truncate("ORES FOUND", w), colors.yellow, colors.black)
  y = y + 1
  if type(ores) ~= "table" or #ores == 0 then
    if y <= maxY then
      cv.text(x, y, truncate("none yet", w), colors.gray, colors.black)
      y = y + 1
    end
    return y
  end
  local maxCount = 1
  for _, ore in ipairs(ores) do
    maxCount = math.max(maxCount, num(type(ore) == "table" and ore.count or 0))
  end
  local nameWidth = math.min(18, math.floor(w * 0.45))
  for _, ore in ipairs(ores) do
    if y > maxY then
      break
    end
    if type(ore) == "table" then
      local count = num(ore.count)
      local color = oreColor(ore.name)
      local countText = fmtNumber(count)
      cv.text(x, y, truncate(prettyName(ore.name), nameWidth), color, colors.black)
      local barWidth = w - nameWidth - #countText - 2
      if barWidth > 0 then
        cv.bar(x + nameWidth + 1, y, barWidth, count / maxCount, color, colors.black)
      end
      cv.text(x + w - #countText, y, countText, colors.white, colors.black)
      y = y + 1
    end
  end
  return y
end

local LEVEL_COLORS = { warn = colors.orange, error = colors.red, cmd = colors.lightBlue }

---@param cv Canvas
---@param x integer
---@param y integer
---@param w integer
---@param maxY integer
---@param events table[]
---@return integer nextY
local function drawEvents(cv, x, y, w, maxY, events)
  if y > maxY then
    return y
  end
  cv.text(x, y, truncate("EVENTS", w), colors.yellow, colors.black)
  y = y + 1
  for _, entry in ipairs(events) do
    if y > maxY then
      break
    end
    local stamp = entry.time ~= "" and (entry.time .. " ") or ""
    cv.text(x, y, truncate(stamp, w), colors.gray, colors.black)
    cv.text(x + #stamp, y, truncate(entry.text, w - #stamp), LEVEL_COLORS[entry.level] or colors.white, colors.black)
    y = y + 1
  end
  return y
end

---@class AppOptions
---@field send fun(id: integer, msg: table)|nil
---@field now (fun(): number)|nil
---@field useWindow boolean|nil

---@param mon table Monitor peripheral
---@param opts AppOptions|nil
---@return table app
local function createApp(mon, opts)
  opts = opts or {}
  local app = { turtles = {}, order = {}, selected = nil, buttons = {}, confirm = nil }
  local clock = opts.now
    or function()
      if os.epoch then
        return os.epoch("utc") / 1000
      end
      return os.clock()
    end
  local buffer = nil

  ---@return table target
  ---@return integer w
  ---@return integer h
  local function surface()
    local w, h = mon.getSize()
    if opts.useWindow and window then
      if not buffer or buffer.w ~= w or buffer.h ~= h then
        buffer = { win = window.create(mon, 1, 1, w, h, false), w = w, h = h }
      end
      return buffer.win, w, h
    end
    return mon, w, h
  end

  --- Swap the monitor, e.g. after it was rebuilt or reattached.
  ---@param newMon table
  function app.setMonitor(newMon)
    mon = newMon
    buffer = nil
  end

  ---@param id integer
  ---@return table entry
  local function ensure(id)
    local entry = app.turtles[id]
    if not entry then
      entry = { id = id, label = "Turtle #" .. tostring(id), events = {}, lastSeen = clock(), status = nil }
      app.turtles[id] = entry
      app.order[#app.order + 1] = id
      table.sort(app.order)
      if app.selected == nil then
        app.selected = id
      end
    end
    return entry
  end

  ---@param entry table
  ---@param text any
  ---@param level string|nil
  local function addEvent(entry, text, level)
    table.insert(entry.events, 1, { time = clockText(), text = tostring(text), level = level or "info" })
    while #entry.events > MAX_EVENTS do
      table.remove(entry.events)
    end
  end

  ---@param sender integer
  ---@param msg any
  ---@return boolean handled
  function app.handleMessage(sender, msg)
    if type(sender) ~= "number" or type(msg) ~= "table" then
      return false
    end
    if msg.type == "status" then
      local entry = ensure(sender)
      entry.status = msg
      entry.lastSeen = clock()
      if type(msg.label) == "string" and msg.label ~= "" then
        entry.label = msg.label
      end
      return true
    elseif msg.type == "event" then
      local entry = ensure(sender)
      entry.lastSeen = clock()
      addEvent(entry, msg.text, type(msg.level) == "string" and msg.level or "info")
      return true
    end
    return false
  end

  ---@param cmd string
  ---@return boolean sent
  function app.sendCommand(cmd)
    local id = app.selected
    if id == nil or not opts.send then
      return false
    end
    local ok, err = pcall(opts.send, id, { type = "command", cmd = cmd, target = id, secret = opts.secret })
    local entry = ensure(id)
    if ok then
      addEvent(entry, "Sent '" .. cmd .. "'", "cmd")
    else
      addEvent(entry, "Sending '" .. cmd .. "' failed: " .. tostring(err), "error")
    end
    return ok
  end

  ---@param button table
  local function pressButton(button)
    if button.confirm then
      local pending = app.confirm
      if not pending or pending.cmd ~= button.cmd or clock() > pending.expires then
        app.confirm = { cmd = button.cmd, expires = clock() + CONFIRM_SECONDS }
        return
      end
    end
    app.confirm = nil
    app.sendCommand(button.cmd)
  end

  ---@param x integer
  ---@param y integer
  ---@return boolean handled
  function app.handleTouch(x, y)
    for _, area in ipairs(app.buttons) do
      if x >= area.x1 and x <= area.x2 and y >= area.y1 and y <= area.y2 then
        area.action()
        return true
      end
    end
    return false
  end

  ---@param entry table
  ---@param offline boolean
  ---@param roomy boolean Add spacer rows between the groups
  ---@param compact boolean Small monitor: short values, only the essential rows
  ---@return table[]
  local function buildRows(entry, offline, roomy, compact)
    local s = type(entry.status) == "table" and entry.status or {}
    local rows = {}
    local function add(row)
      rows[#rows + 1] = row
    end
    local function gap()
      if roomy then
        add({ kind = "gap" })
      end
    end

    local style = STATE_STYLES[offline and "offline" or tostring(s.state)]
      or { label = string.upper(tostring(s.state or "UNKNOWN")), color = colors.lightGray }
    if not compact then
      -- On small monitors the tab row already shows the turtle name
      local version = type(s.version) == "string" and ("  v" .. s.version) or ""
      add({ kind = "title", text = entry.label .. "  #" .. tostring(entry.id) .. version })
    end
    local info = tostring(s.message or "")
    if offline then
      info = "last update " .. fmtDuration(clock() - entry.lastSeen) .. " ago"
    end
    add({ kind = "badge", label = style.label, color = style.color, text = info })
    gap()

    local progress = type(s.progress) == "table" and s.progress or {}
    local total = num(progress.total)
    local done = num(progress.done)
    local ratio = total > 0 and done / total or 0
    add({ kind = "kv", key = "Progress", value = string.format("%.1f%%", ratio * 100), color = colors.lime })
    add({ kind = "bar", ratio = ratio, color = colors.lime })
    add({
      kind = "kv",
      key = "Tunnel",
      value = string.format("%d / %d", num(progress.tunnel), num(progress.tunnels)),
    })
    add({ kind = "kv", key = "ETA", value = fmtDuration(s.eta) })
    gap()

    local fuel = num(s.fuel)
    local limit = num(s.fuelLimit)
    if fuel < 0 then
      add({ kind = "kv", key = "Fuel", value = "unlimited", color = colors.green })
    else
      local fuelRatio = limit > 0 and fuel / limit or 0
      local fuelColor = colors.green
      if fuel < 500 then
        fuelColor = colors.red
      elseif fuelRatio < 0.2 then
        fuelColor = colors.orange
      end
      add({
        kind = "kv",
        key = "Fuel",
        value = compact and fmtNumber(fuel) or (fmtNumber(fuel) .. " / " .. fmtNumber(limit)),
        color = fuelColor,
      })
      add({ kind = "bar", ratio = fuelRatio, color = fuelColor })
    end
    gap()

    local inventory = type(s.inventory) == "table" and s.inventory or {}
    local used = num(inventory.used)
    local slots = num(inventory.total, 12)
    local invRatio = slots > 0 and used / slots or 0
    local invColor = invRatio >= 0.8 and colors.orange or colors.cyan
    local slotFormat = compact and "%d/%d" or "%d / %d slots"
    add({ kind = "kv", key = "Inventory", value = string.format(slotFormat, used, slots), color = invColor })
    add({ kind = "bar", ratio = invRatio, color = invColor })
    gap()

    local torches = num(s.torches)
    add({
      kind = "kv",
      key = "Torches",
      value = compact and tostring(torches) or string.format("%d (placed %d)", torches, num(s.torchesPlaced)),
      color = torches == 0 and colors.red or colors.white,
    })
    local p = type(s.pos) == "table" and s.pos or {}
    local position = string.format("X%d Y%d Z%d %s", num(p.x), num(p.y), num(p.z), FACING[num(p.f)] or "?")
    if compact then
      position = string.format("%d/%d/%d", num(p.x), num(p.y), num(p.z))
    end
    add({ kind = "kv", key = "Position", value = position })
    add({ kind = "kv", key = "Mined", value = fmtNumber(num(s.mined)) .. (compact and "" or " blocks") })
    if compact then
      return rows
    end
    add({
      kind = "kv",
      key = "Unloads",
      value = string.format("%d (%s items)", num(s.dumps), fmtNumber(num(s.itemsDumped))),
    })
    add({ kind = "kv", key = "Junk dropped", value = fmtNumber(num(s.junkDropped)) })
    add({ kind = "kv", key = "Moved", value = fmtNumber(num(s.moved)) .. " blocks" })
    add({ kind = "kv", key = "Resupplies", value = fmtNumber(num(s.resupplies)) })
    add({
      kind = "kv",
      key = "Restarts",
      value = string.format("%d  (GPS %s)", num(s.restarts), s.gps and "on" or "off"),
      color = num(s.restarts) > 0 and colors.yellow or colors.white,
    })
    add({ kind = "kv", key = "Uptime", value = fmtDuration(s.uptime) })
    local job = type(s.job) == "table" and s.job or nil
    if job then
      add({
        kind = "kv",
        key = "Job",
        value = string.format(
          "%dx %dx%dx%d gap %d %s",
          num(job.tunnels),
          num(job.width),
          num(job.height),
          num(job.length),
          num(job.spacing),
          tostring(job.side or "")
        ),
      })
    end
    return rows
  end

  ---@param cv Canvas
  ---@param w integer
  local function drawHeader(cv, w)
    cv.fill(1, 1, w, 1, colors.blue)
    cv.text(2, 1, truncate("ENDER MINER CONTROL", w - 2), colors.white, colors.blue)
    local right = string.format("%d turtle(s)  %s", #app.order, clockText())
    if #right + 23 <= w then
      cv.text(w - #right, 1, right, colors.lightBlue, colors.blue)
    end
  end

  ---@param cv Canvas
  ---@param w integer
  local function drawTabs(cv, w)
    cv.fill(1, 2, w, 1, colors.black)
    local x = 1
    for _, id in ipairs(app.order) do
      local entry = app.turtles[id]
      local offline = clock() - entry.lastSeen > STALE_AFTER
      local s = type(entry.status) == "table" and entry.status or {}
      local style = STATE_STYLES[offline and "offline" or tostring(s.state)] or STATE_STYLES.starting
      local label = " " .. truncate(entry.label, 14) .. " "
      local width = #label + 1
      if x + width - 1 > w then
        break
      end
      local selected = id == app.selected
      cv.text(x, 2, " ", colors.black, style.color)
      cv.text(x + 1, 2, label, selected and colors.black or colors.white, selected and colors.lightBlue or colors.gray)
      app.buttons[#app.buttons + 1] = {
        x1 = x,
        y1 = 2,
        x2 = x + width - 1,
        y2 = 2,
        action = function()
          app.selected = id
          app.confirm = nil
        end,
      }
      x = x + width + 1
    end
  end

  ---@param cv Canvas
  ---@param top integer
  ---@param height integer
  ---@param w integer
  local function drawButtons(cv, top, height, w)
    local count = #BUTTONS
    local gapWidth = 1
    local width = math.floor((w - gapWidth * (count + 1)) / count)
    if width < 4 then
      -- Narrow monitor: drop the gaps, the button colours separate them
      gapWidth = 0
      width = math.floor(w / count)
    end
    if width < 2 then
      return
    end
    -- Spread the remaining columns over the buttons so the row is filled
    local usable = w - gapWidth * (count + 1)
    for index, button in ipairs(BUTTONS) do
      local x = 1 + gapWidth * index + math.floor((index - 1) * usable / count)
      width = math.floor(index * usable / count) - math.floor((index - 1) * usable / count)
      local label = button.label
      local color = button.color
      local confirming = app.confirm and app.confirm.cmd == button.cmd and clock() <= app.confirm.expires
      if confirming then
        label = "CONFIRM?"
        color = colors.red
      end
      if #label > width then
        label = confirming and "OK?" or button.short
      end
      cv.fill(x, top, width, height, color)
      local text = truncate(label, width)
      local tx = x + math.floor((width - #text) / 2)
      cv.text(tx, top + math.floor((height - 1) / 2), text, colors.black, color)
      local captured = button
      app.buttons[#app.buttons + 1] = {
        x1 = x,
        y1 = top,
        x2 = x + width - 1,
        y2 = top + height - 1,
        action = function()
          pressButton(captured)
        end,
      }
    end
  end

  function app.render()
    local target, w, h = surface()
    local cv = newCanvas(target)
    app.buttons = {}
    cv.fill(1, 1, w, h, colors.black)
    drawHeader(cv, w)

    if #app.order == 0 then
      local lines = {
        "Waiting for turtles ...",
        "Protocol: " .. PROTOCOL,
        "Start 'miner' on a turtle with an ender modem.",
      }
      local y = math.max(3, math.floor(h / 2) - 1)
      for i, line in ipairs(lines) do
        local text = truncate(line, w - 2)
        cv.text(math.max(1, math.floor((w - #text) / 2) + 1), y + i - 1, text, colors.lightGray, colors.black)
      end
    else
      if app.selected == nil or app.turtles[app.selected] == nil then
        app.selected = app.order[1]
      end
      drawTabs(cv, w)
      local entry = app.turtles[app.selected]
      local offline = clock() - entry.lastSeen > STALE_AFTER
      local buttonHeight = h >= 30 and 3 or 1
      local top = 4
      local bottom = h - buttonHeight - 1
      local roomy = h >= 40
      -- Below 30 rows (e.g. a 2x2 monitor) only the essential rows fit
      -- together with the ores and the event log
      local compact = h < 30
      local rows = buildRows(entry, offline, roomy, compact)
      local status = type(entry.status) == "table" and entry.status or {}

      if w >= 60 then
        local leftWidth = math.floor((w - 5) / 2)
        local rightX = leftWidth + 5
        local rightWidth = w - rightX
        drawRows(cv, 2, top, leftWidth, bottom, rows)
        for y = top, bottom do
          cv.text(leftWidth + 3, y, "|", colors.gray, colors.black)
        end
        local oreRows = math.max(3, math.floor((bottom - top) / 2))
        local nextY = drawOres(cv, rightX, top, rightWidth, top + oreRows - 1, status.ores)
        drawEvents(cv, rightX, nextY + 1, rightWidth, bottom, entry.events)
      else
        local nextY = drawRows(cv, 2, top, w - 2, bottom, rows)
        local remaining = bottom - nextY
        if remaining >= 4 then
          local oreBottom = nextY + math.floor(remaining / 2)
          local afterOres = drawOres(cv, 2, nextY + 1, w - 2, oreBottom, status.ores)
          drawEvents(cv, 2, afterOres + 1, w - 2, bottom, entry.events)
        end
      end
      drawButtons(cv, h - buttonHeight + 1, buttonHeight, w)
    end

    if buffer and target == buffer.win then
      target.setVisible(true)
      target.setVisible(false)
    end
  end

  return app
end

---@return table|nil modem
local function findWirelessModem()
  return peripheral.find("modem", function(_, wrapped)
    return wrapped.isWireless ~= nil and wrapped.isWireless()
  end)
end

--- Shared command secret from the optional file "minermon.secret".
---@return string|nil
local function readSecret()
  if not fs.exists(SECRET_FILE) then
    return nil
  end
  local handle = fs.open(SECRET_FILE, "r")
  if not handle then
    return nil
  end
  local text = handle.readAll() or ""
  handle.close()
  text = text:gsub("%s+$", ""):gsub("^%s+", "")
  if text == "" then
    return nil
  end
  return text
end

---@param argv string[]
local function main(argv)
  local scale = tonumber(argv[1]) or DEFAULT_SCALE
  local mon = peripheral.find("monitor")
  if not mon then
    printError("No monitor attached.")
    return
  end
  local modem = findWirelessModem()
  if not modem then
    printError("No wireless or ender modem attached.")
    return
  end
  local modemName = peripheral.getName(modem)
  local monitorName = peripheral.getName(mon)
  local okOpen, openErr = pcall(rednet.open, modemName)
  if not okOpen then
    printError("Cannot open modem: " .. tostring(openErr))
    return
  end
  local okScale = pcall(mon.setTextScale, scale)
  if not okScale then
    printError("Invalid text scale " .. tostring(scale) .. ", using " .. DEFAULT_SCALE)
    mon.setTextScale(DEFAULT_SCALE)
  end

  local app = createApp(mon, {
    useWindow = true,
    secret = readSecret(),
    send = function(id, msg)
      rednet.send(id, msg, PROTOCOL)
    end,
  })

  term.clear()
  term.setCursorPos(1, 1)
  print("Ender Miner Monitor " .. VERSION)
  print("Monitor: " .. monitorName .. "  Modem: " .. modemName)
  print("Protocol: " .. PROTOCOL)
  print("Press Q to quit.")

  local monitorOk = true

  local function safeRender()
    if not monitorOk then
      return
    end
    local ok, err = pcall(app.render)
    if not ok then
      printError("Render error: " .. tostring(err))
    end
  end

  --- Re-attach monitor and modem after they were removed or rebuilt.
  local function reattach()
    local newMon = peripheral.find("monitor")
    if newMon then
      mon = newMon
      monitorName = peripheral.getName(newMon)
      pcall(newMon.setTextScale, okScale and scale or DEFAULT_SCALE)
      app.setMonitor(newMon)
      if not monitorOk then
        print("Monitor attached: " .. monitorName)
      end
      monitorOk = true
    end
    local newModem = findWirelessModem()
    if newModem then
      local name = peripheral.getName(newModem)
      if not rednet.isOpen(name) then
        local ok, err = pcall(rednet.open, name)
        if ok then
          print("Modem attached: " .. name)
        else
          printError("Cannot open modem: " .. tostring(err))
        end
      end
      modemName = name
    end
  end

  safeRender()
  local timer = os.startTimer(1)
  while true do
    local ev = { os.pullEventRaw() }
    local name = ev[1]
    if name == "terminate" or (name == "key" and ev[2] == keys.q) then
      break
    elseif name == "rednet_message" then
      if ev[4] == PROTOCOL and app.handleMessage(ev[2], ev[3]) then
        safeRender()
      end
    elseif name == "monitor_touch" then
      if ev[2] == monitorName and app.handleTouch(ev[3], ev[4]) then
        safeRender()
      end
    elseif name == "monitor_resize" then
      safeRender()
    elseif name == "peripheral_detach" then
      if ev[2] == monitorName then
        monitorOk = false
        printError("Monitor detached - waiting for a monitor")
      elseif ev[2] == modemName then
        printError("Modem detached - waiting for an ender modem")
      end
    elseif name == "peripheral" then
      reattach()
      safeRender()
    elseif name == "timer" and ev[2] == timer then
      timer = os.startTimer(1)
      safeRender()
    end
  end

  if monitorOk then
    pcall(function()
      mon.setBackgroundColor(colors.black)
      mon.clear()
    end)
  end
  print("Monitor stopped.")
end

local M = {
  VERSION = VERSION,
  PROTOCOL = PROTOCOL,
  createApp = createApp,
  fmtDuration = fmtDuration,
  fmtNumber = fmtNumber,
  prettyName = prettyName,
  truncate = truncate,
}

local args = { ... }
if args[1] == "--lib" then
  return M
end
main(args)
