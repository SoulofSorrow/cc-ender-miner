# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [2.2.0] - 2026-10-12

### Added

- `station`: choose kinds of ore per job on an ORES screen. Without a choice
  every ore is mined as before. Ores of other mods are added to the list as
  soon as the turtle has scanned them, choosing a vanilla ore selects its
  level as well.
- `station`: own Y level per job (`Own Y`), e.g. for modded ores.
- `station`: warns when the turtle runs a different version.
- `miner`: setting `oreGroups` mines only certain kinds of ore. A kind covers
  every variant of an ore (stone, deepslate, nether, any mod), e.g.
  `diamond` or `osmium`. The setup wizard asks for it.
- `miner`: reports every kind of ore the geo scanner saw, also the ones it
  did not mine.

### Changed

- Station jobs decide alone what is mined; `oreNames` from `miner.cfg` no
  longer applies to them.
- Level buttons of the station use shorter labels so they fit on small
  screens.
- `make release` works without a GitHub CLI login: it pushes the branch and
  the tag, then opens the release page in the browser with tag, title and
  notes filled in. With `gh` logged in or `GH_TOKEN` set it creates the
  release as before. `RELEASE_MODE=gh|browser` forces one way.

## [2.1.0] - 2026-10-12

### Added

- `station`: job station for a computer with a touch monitor (or the screen
  of an advanced computer). Ore jobs are created by tapping the ores, the
  area size and the number of areas, queued in `station.db` and handed to
  the docked turtle one at a time through a floppy disk. Areas are given out
  in a spiral around the station, so no area is mined twice. Shows the state
  of the turtle, the job list and a map of the areas.
- `miner dock`: dock mode. The turtle waits at the station, takes the next
  job, mines it in ore mode, unloads into the chest above, refuels from the
  chest below (`dockFuel`) and reports the result. It resumes a job after a
  reboot and never takes a job twice.
- Ore mode settings `areaOffsetX` and `areaOffsetZ` move the area away from
  the start block.
- `install station` and the role `station` for the updater.
- Tests for the station screens, the job protocol and the dock mode,
  including unloads in the middle of a queue.

## [2.0.0] - 2026-10-11

### Added

- Ore mode (`mode = "ores"`): the miner uses the Advanced Peripherals geo
  scanner to find ores on several Y levels and mines only those. Scan points
  are spaced so the scan spheres cover each level band completely, levels are
  driven as alternating serpentines connected by vertical shafts, and the ores
  of each cell are visited on a nearest-neighbour tour improved with 2-opt.
- Level presets for the vanilla ores of Minecraft 1.18+ (diamond/redstone,
  gold, lapis, iron, copper, coal); every ore with the `c:ores` tag is mined,
  so modded ores are included. `oreNames` limits it to certain blocks.
- The pickaxe and the geo scanner share one upgrade slot and are swapped for
  each scan, so the other slot can hold the chunky turtle upgrade.
- Restart safety without GPS: the direction is calibrated with two scans at
  the start, and an interrupted turn is resolved by scanning, moving one
  block and comparing the scans. A reboot while scanning puts the pickaxe
  back.
- The setup wizard asks for the mode, the start Y and the ores.
- Tests for the ore mode with a simulated geo scanner, including an unload at
  hundreds of points of a job.

### Changed

- The ender modem is optional; without it the turtle only shows its state on
  its own screen.

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

[Unreleased]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v2.2.0...HEAD
[2.2.0]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v2.1.0...v2.2.0
[2.1.0]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v1.4.0...v2.0.0
[1.4.0]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/SoulofSorrow/cc-ender-miner/releases/tag/v1.0.0
