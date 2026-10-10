# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/SoulofSorrow/cc-ender-miner/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/SoulofSorrow/cc-ender-miner/releases/tag/v1.0.0
