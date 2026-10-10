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

return tests
