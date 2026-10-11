# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.4.0] - 2026-10-11

### Added

- `miner`: setting `useFollower` (default off) and a question in the setup
  wizard. Without it the miner sends no "make way" requests and no extra
  chunk reports.
- `minermon`: pairs followers only with miners that want one, releases a
  follower whose miner runs without one, and shows a "Follower" row on the
  miner tab.
- `follower`: handles the release and waits instead of following.

### Changed

- The chunk loading follower is now explicitly optional and off by default.

## [1.3.0] - 2026-10-11

### Added

- `follower`: optional chunk loading follower turtle. It drives only through
  cells the miner has dug, waits on parking cells the miner never uses again,
  makes way when asked, prefers the miner's chunk with GPS and drives next to
  a silent miner to load its chunk again. It resumes after a reboot too.
- `minermon` is the hub between miner and follower: it pairs followers with
  miners, relays position and progress, forwards "make way" requests, shows a
  follower tab and warns about version differences.
- `update`: auto updater for all programs, driven by `manifest.json`. Files
  are checked for valid Lua and replaced together; a running job is only
  updated by a version that can read its saved state. Settings
  `endermine.auto_update` and `endermine.update_url`.
- `miner`: shared job geometry for the follower, reports chunk changes at once
  (with GPS) and asks for the follower to make way when a turtle blocks it.
- `install follower` installs the follower; every role also gets the updater.
- Co-simulation tests that run miner, follower and hub together.

## [1.2.0] - 2026-10-11

### Added

- `miner`: continues an interrupted job automatically after a chunk unload,
  logout or server restart. Position, facing and progress are journaled
  around every move and turn, and `startup/endermine.lua` resumes the job
  after a 5 second countdown that any key cancels.
- Moves interrupted by an unload are verified through the fuel level;
  interrupted turns (and moves with unlimited fuel) are recovered with GPS.
  Without GPS the turtle stops with the new state `lost` instead of digging
  in a wrong direction.
- An ender chest left in the world by an unload is picked up again.
- `miner` asks whether to resume when started by hand with an unfinished job.
- `minermon`: states `RESUMING` and `LOST`, restart counter and GPS status.
- Simulation tests that stop the turtle at hundreds of points and verify the
  finished job after the reboot.

### Changed

- Torches are placed while driving backwards, which saves two turns per torch.
- Job files are written atomically (write, then rename).

## [1.1.0] - 2026-10-10

### Added

- `minermon`: compact layout for small monitors such as 2x2. It shows only
  the essential values with short labels, so ores, events and buttons still fit.

### Fixed

- `minermon`: buttons fill the whole bottom row and stay visible on narrow
  monitors (short labels instead of hiding them).

## [1.0.0] - 2026-10-10

### Added

- `miner`: tunnel mining program for CC: Tweaked mining turtles, a complete
  rewrite inspired by the "Mining Turtle 3.5" script by PrinceTommen.
- Two EnderStorage ender chests: one supply chest for torches (and optional
  fuel), one resource chest that receives everything that is mined.
- Position tracking relative to the start block and a reliable way home,
  including detours around unbreakable blocks.
- Configurable number of parallel tunnels, width, height, length, spacing and
  side, saved in `miner.cfg` with an interactive setup wizard.
- Torches placed at a configurable interval on the tunnel floor.
- Junk filter (cobblestone, dirt, gravel, ...) and refuelling from mined coal.
- Telemetry over a wireless or ender modem (`endermine.v1` rednet protocol)
  with pause, resume, return home and refresh commands.
- `minermon`: dashboard for a computer with an ender modem and an advanced
  monitor (designed for 4x4), with tabs for several turtles, progress, fuel,
  inventory, ore statistics, event log and touch buttons.
- `install`: in-game installer for both programs, optionally with a
  `startup.lua`.
- Offline simulation tests, luacheck, StyLua, pre-commit hooks and a Makefile
  for building, testing and releasing.

[Unreleased]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/SoulofSorrow/cc-ender-miner/releases/tag/v1.0.0
