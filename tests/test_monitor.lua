-- Rendering and interaction tests for src/minermon.lua

local H = require("helpers")
local Mock = require("mock_cc")

local tests = {}

---@param name string
---@param fn function
local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

--- Produce a realistic status payload by running a short simulated job.
---@return table status
---@return table[] events
local function sampleTelemetry()
  local env, miner = H.setup({ mock = { modem = true, label = "Digger" }, config = { tunnels = 1, length = 10 } })
  miner.openTelemetry()
  H.check(miner.run(), "sample run failed")
  local events = {}
  for _, entry in ipairs(env.broadcasts) do
    if entry.msg.type == "event" then
      events[#events + 1] = entry.msg
    end
  end
  local status = env.lastBroadcast("status")
  status.state = "mining"
  return status, events
end

---@param w integer
---@param h integer
---@return table app
---@return table mon
---@return table clock
---@return table sent
local function newApp(w, h)
  local env = Mock.new()
  env.install()
  local M = H.loadProgram(H.SRC .. "/minermon.lua")
  local mon = Mock.newScreen(w, h)
  local clock = { t = 1000 }
  local sent = {}
  local app = M.createApp(mon, {
    now = function()
      return clock.t
    end,
    send = function(id, msg)
      sent[#sent + 1] = { id = id, msg = msg }
    end,
  })
  return app, mon, clock, sent
end

test("formatting helpers", function()
  Mock.new().install()
  local M = H.loadProgram(H.SRC .. "/minermon.lua")
  H.eq(M.fmtNumber(1234567), "1,234,567", "fmtNumber")
  H.eq(M.fmtNumber(12), "12", "fmtNumber small")
  H.eq(M.fmtDuration(nil), "--", "duration nil")
  H.eq(M.fmtDuration(45), "45s", "seconds")
  H.eq(M.fmtDuration(754), "12m 34s", "minutes")
  H.eq(M.fmtDuration(7322), "2h 02m", "hours")
  H.eq(M.prettyName("minecraft:deepslate_diamond_ore"), "Deepslate diamond", "prettyName")
  H.eq(M.truncate("abcdef", 4), "ab..", "truncate")
end)

test("waiting screen without turtles", function()
  local app, mon = newApp(79, 52)
  app.render()
  H.check(mon.find("Waiting for turtles"), "waiting text missing")
  H.check(mon.find("ENDER MINER CONTROL"), "header missing")
end)

test("renders at several monitor sizes", function()
  local status, events = sampleTelemetry()
  local sizes = { { 79, 52 }, { 39, 26 }, { 57, 38 }, { 29, 19 }, { 15, 10 }, { 164, 81 } }
  for _, size in ipairs(sizes) do
    local app, mon = newApp(size[1], size[2])
    for _, ev in ipairs(events) do
      app.handleMessage(7, ev)
    end
    H.check(app.handleMessage(7, status), "status not accepted")
    app.render()
    local label = size[1] .. "x" .. size[2]
    H.check(mon.find("MINING"), label .. ": state badge missing")
    if size[1] >= 29 then
      H.check(mon.find("PAUSE"), label .. ": buttons missing")
      H.check(mon.find("Progress"), label .. ": progress missing")
    end
    if size[1] >= 60 then
      H.check(mon.find("ORES FOUND"), label .. ": ores panel missing")
      H.check(mon.find("EVENTS"), label .. ": events panel missing")
      H.check(mon.find("Coal"), label .. ": coal row missing")
    end
  end
end)

test("2x2 monitor shows ores, events and usable buttons", function()
  local status, events = sampleTelemetry()
  -- 2x2 advanced monitor at text scale 0.5 and 1
  for _, size in ipairs({ { 36, 24 }, { 18, 12 } }) do
    local app, mon, _, sent = newApp(size[1], size[2])
    for _, ev in ipairs(events) do
      app.handleMessage(7, ev)
    end
    app.handleMessage(7, status)
    app.render()
    local label = size[1] .. "x" .. size[2]
    H.check(mon.find("MINING"), label .. ": state badge missing")
    H.check(mon.find("Fuel"), label .. ": fuel missing")
    if size[1] >= 36 then
      H.check(mon.find("ORES FOUND"), label .. ": ores missing")
      H.check(mon.find("EVENTS"), label .. ": events missing")
      H.check(mon.find("Torches"), label .. ": torches missing")
    end
    -- The bottom row holds the four buttons, the first one pauses
    H.check(app.handleTouch(2, size[2]), label .. ": pause button not touchable")
    H.eq(#sent, 1, label .. ": command count")
    H.eq(sent[1].msg.cmd, "pause", label .. ": command")
    H.check(app.handleTouch(size[1] - 1, size[2]), label .. ": refresh button not touchable")
    H.eq(sent[2].msg.cmd, "ping", label .. ": last button")
  end
end)

test("buttons send commands, home needs confirmation", function()
  local status = sampleTelemetry()
  local app, mon, clock, sent = newApp(79, 52)
  app.handleMessage(7, status)
  app.render()
  local x, y = mon.find("PAUSE")
  H.check(x, "pause button not drawn")
  H.check(app.handleTouch(x, y), "touch not handled")
  H.eq(#sent, 1, "pause sent")
  H.eq(sent[1].id, 7, "target id")
  H.eq(sent[1].msg.cmd, "pause", "command")
  H.eq(sent[1].msg.type, "command", "type")

  app.render()
  local hx, hy = mon.find("HOME")
  app.handleTouch(hx, hy)
  H.eq(#sent, 1, "home must not be sent on first touch")
  app.render()
  H.check(mon.find("CONFIRM?"), "confirmation not shown")
  app.handleTouch(hx, hy)
  H.eq(#sent, 2, "home sent after confirmation")
  H.eq(sent[2].msg.cmd, "home", "home command")

  app.render()
  app.handleTouch(hx, hy)
  clock.t = clock.t + 10
  app.render()
  app.handleTouch(hx, hy)
  H.eq(#sent, 2, "expired confirmation must not send")
end)

test("tabs switch between turtles", function()
  local status = sampleTelemetry()
  local app, mon, _, sent = newApp(79, 52)
  local second = {}
  for k, v in pairs(status) do
    second[k] = v
  end
  second.label = "Bravo"
  second.state = "paused"
  app.handleMessage(7, status)
  app.handleMessage(9, second)
  app.render()
  H.check(mon.find("PAUSED") == nil, "first turtle should be selected")
  local x, y = mon.find("Bravo")
  H.check(x, "tab missing")
  app.handleTouch(x, y)
  app.render()
  H.check(mon.find("PAUSED"), "second turtle not shown")
  local px, py = mon.find("RESUME")
  app.handleTouch(px, py)
  H.eq(sent[#sent].id, 9, "command goes to the selected turtle")
end)

test("stale turtles are shown as offline", function()
  local status = sampleTelemetry()
  local app, mon, clock = newApp(79, 52)
  app.handleMessage(7, status)
  clock.t = clock.t + 60
  app.render()
  H.check(mon.find("NO SIGNAL"), "offline badge missing")
end)

test("malformed messages do not crash", function()
  local app, mon = newApp(39, 26)
  H.eq(app.handleMessage(5, "text"), false, "string message")
  H.eq(app.handleMessage("x", { type = "status" }), false, "bad sender")
  H.eq(app.handleMessage(5, { type = "unknown" }), false, "unknown type")
  H.check(
    app.handleMessage(5, {
      type = "status",
      state = { "nested" },
      progress = "bad",
      pos = 7,
      ores = { 1, { name = 3, count = "x" } },
      fuel = "lots",
      inventory = { used = "?" },
      eta = 0 / 0,
      job = { side = {} },
    }),
    "status with garbage should still be accepted"
  )
  app.handleMessage(5, { type = "event", text = { "table" }, level = 4 })
  app.render()
  H.check(mon.find("ENDER MINER CONTROL"), "render failed")
end)

test("several miners and followers are paired one to one", function()
  local app, _, _, sent = newApp(79, 52)
  local job = { tunnels = 1, width = 3, height = 3, length = 10, spacing = 1, side = "right", torchInterval = 8 }
  local function minerStatus(id)
    return {
      type = "status",
      role = "miner",
      id = id,
      state = "mining",
      pos = { x = 0, y = 1, z = 3, f = 0 },
      progress = { done = 3, total = 30, tunnel = 1, tunnels = 1, index = 0, phase = "tunnel" },
      job = job,
      followerWanted = true,
    }
  end
  app.handleMessage(11, minerStatus(11))
  app.handleMessage(12, minerStatus(12))
  app.handleMessage(21, { type = "status", role = "follower", id = 21, state = "waiting" })
  app.handleMessage(22, { type = "status", role = "follower", id = 22, state = "waiting" })
  local assigned = {}
  for _, entry in ipairs(sent) do
    if entry.msg.type == "assign" then
      assigned[entry.id] = entry.msg.miner
    end
  end
  H.eq(assigned[21], 11, "first follower gets the first miner")
  -- The follower confirms the pairing in its next status
  app.handleMessage(21, { type = "status", role = "follower", id = 21, state = "following", follow = 11 })
  app.handleMessage(22, { type = "status", role = "follower", id = 22, state = "waiting" })
  local second = nil
  for _, entry in ipairs(sent) do
    if entry.msg.type == "assign" and entry.id == 22 then
      second = entry.msg.miner
    end
  end
  H.eq(second, 12, "second follower gets the other miner")
  app.handleMessage(22, { type = "status", role = "follower", id = 22, state = "following", follow = 12 })
  local before = #sent
  app.handleMessage(12, minerStatus(12))
  local relayed = {}
  for i = before + 1, #sent do
    relayed[#relayed + 1] = sent[i]
  end
  H.eq(#relayed, 1, "a miner status goes to its own follower only")
  H.eq(relayed[1].id, 22, "relay target")
  H.eq(relayed[1].msg.type, "follow", "relay type")
  H.eq(relayed[1].msg.job.width, 3, "job relayed")
  app.handleMessage(11, { type = "blocked", id = 11, pos = { x = 0, y = 1, z = 3, f = 0 }, dir = "fwd" })
  local last = sent[#sent]
  H.eq(last.id, 21, "make_way goes to the follower of the blocked miner")
  H.eq(last.msg.type, "make_way", "make_way type")
  app.render()
end)

test("follower tab renders and old versions are flagged", function()
  local app, mon = newApp(79, 52)
  app.handleMessage(21, {
    type = "status",
    role = "follower",
    id = 21,
    label = "Loader",
    state = "following",
    message = "Parked 3 blocks from the miner",
    follow = 11,
    distance = 3,
    chunkLoader = "active",
    fuel = 900,
    pos = { x = 1, y = 2, z = 9 },
    version = "0.9.0",
  })
  app.render()
  H.check(mon.find("FOLLOWING"), "state badge")
  H.check(mon.find("Chunk loader"), "chunk loader row")
  H.check(mon.find("#11"), "paired miner")
  H.check(not mon.find("ORES FOUND"), "no ore panel for followers")
  H.check(mon.find("Runs v0.9.0"), "version warning")
end)

test("followers are released when the miner runs without one", function()
  local app, mon, _, sent = newApp(79, 52)
  local status = {
    type = "status",
    role = "miner",
    id = 11,
    state = "mining",
    pos = { x = 0, y = 1, z = 3, f = 0 },
    progress = { done = 3, total = 30, tunnel = 1, tunnels = 1, index = 0, phase = "tunnel" },
    job = { tunnels = 1, width = 3, height = 3, length = 10, spacing = 1, side = "right", torchInterval = 8 },
    followerWanted = false,
  }
  app.handleMessage(11, status)
  app.handleMessage(21, { type = "status", role = "follower", id = 21, state = "waiting" })
  for _, entry in ipairs(sent) do
    H.check(entry.msg.type ~= "assign", "no assignment to a miner without follower")
  end
  -- A follower that still follows this miner (e.g. configured by id) is released
  app.handleMessage(21, { type = "status", role = "follower", id = 21, state = "following", follow = 11 })
  app.handleMessage(11, status)
  H.eq(sent[#sent].msg.type, "release", "release message")
  H.eq(sent[#sent].id, 21, "release target")
  app.selected = 11
  app.render()
  local x, y = mon.find("Follower")
  H.check(x and mon.rows[y]:find("off", 1, true), "miner tab shows the follower as off")
end)

return tests
