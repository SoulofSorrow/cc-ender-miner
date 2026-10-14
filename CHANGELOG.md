# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [3.0.0] - 2026-10-14

### Added

- `miner`: never steps into lava (`avoidLava`, on by default). The way counts
  as blocked, so the turtle returns home and reports `lava ahead`.
- `miner`: optional shared `secret`; `minermon` reads it from
  `minermon.secret` and sends it with every command.
- `miner`: unknown keys in `miner.cfg` are reported instead of silently
  dropped.

### Fixed

- A `home` command now interrupts the wait for fuel.
- Atomic file writes are read back before the old file is replaced, so a full
  disk cannot destroy the last good job file.

### Changed

- Progress is saved every 8 cells instead of every cell; the current cell
  count is kept in the position journal, so no work is repeated after a
  reboot.
- `miner` is split into `src/miner.lua` and the modules in `src/endermine/`.
  `install` downloads all files.
- Renamed the README files: `README.md` is English, `README.de.md` is German.

### Removed

- `station`, `follower` and the updater (`update`, `manifest.json`), together
  with ore mode and dock mode of the miner.

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

[Unreleased]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v2.2.0...v3.0.0
[1.2.0]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/SoulofSorrow/cc-ender-miner/releases/tag/v1.0.0
