-- luacheck configuration for CC: Tweaked programs
std = "lua51"
max_line_length = 120
read_globals = {
  "turtle", "rednet", "peripheral", "term", "colors", "colours", "fs", "textutils",
  "parallel", "sleep", "read", "write", "printError", "keys", "window", "http", "shell",
  os = { fields = { "getComputerID", "getComputerLabel", "epoch", "pullEvent", "pullEventRaw", "startTimer", "cancelTimer", "clock", "time", "date" } },
}
files["tests/"] = {
  std = "lua51+lua52",
  globals = { "turtle", "rednet", "peripheral", "term", "colors", "colours", "fs", "textutils",
    "parallel", "sleep", "read", "write", "print", "printError", "keys", "window", "os" },
}
