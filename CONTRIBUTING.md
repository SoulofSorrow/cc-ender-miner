# Contributing

Thanks for helping to improve cc-ender-miner!

## Requirements

- Lua 5.1 or 5.2 for the offline tests (`lua`)
- [luacheck](https://github.com/lunarmodules/luacheck)
- [StyLua](https://github.com/JohnnyMorganz/StyLua)
- [pre-commit](https://pre-commit.com/) (recommended)
- [GitHub CLI](https://cli.github.com/) for releases

## Workflow

1. Fork the repository and create a branch: `git checkout -b feature/my-change`
2. Install the hooks once: `pre-commit install`
3. Make your change and run `make check` (lint, format check, tests)
4. Add an entry to the `[Unreleased]` section of `CHANGELOG.md`
5. Open a pull request with a short description of the change

## Code style

- Code, comments and commit messages are written in English.
- Format with `make format`; the line length is 120 characters.
- Annotate functions with [LuaLS](https://luals.github.io/) type comments
  (`---@param`, `---@return`, `---@class`).
- Handle failures explicitly: turtle actions return `false, reason` and must
  never be ignored silently.
- No emojis in code, logs or on the turtle and monitor screens.
- `miner` is split into `src/miner.lua` and the modules in `src/endermine/`;
  `src/install.lua` downloads all of them. A new module must be added to the
  file list in `src/install.lua`.
  `minermon.lua` stays a single file.

## Tests

`tests/mock_cc.lua` simulates a voxel world, a turtle, EnderStorage chests,
rednet and `parallel`. New behaviour needs a test in `tests/test_miner.lua`
or `tests/test_monitor.lua`. Run a single test with
`lua tests/run.lua "part of the test name"`.

## Protocol changes

The rednet protocol name contains a version (`endermine.v1`). Changes that
break older monitors or turtles must bump it in both programs.

## Releases

Maintainers bump `VERSION` in `src/miner.lua` and `src/minermon.lua`, move the
changelog entries into a new version section, commit, and run `make release`.
