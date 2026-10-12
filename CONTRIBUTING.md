# Contributing

Thanks for helping to improve cc-ender-miner!

## Requirements

- Lua 5.1 or 5.2 for the offline tests (`lua`)
- [luacheck](https://github.com/lunarmodules/luacheck)
- [StyLua](https://github.com/JohnnyMorganz/StyLua)
- [pre-commit](https://pre-commit.com/) (recommended)
- [GitHub CLI](https://cli.github.com/) for releases (optional, without it the
  release page opens in the browser)

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
- Keep the programs single files so they can be installed with `wget`. The
  follower is the one exception: it loads the shared job geometry from
  `miner.lua`, so geometry changes must keep both in sync.
- Bump `VERSION` in every program and in `manifest.json` together; a change
  to the saved job format must also bump `stateFormat` (miner `STATE_FORMAT`),
  otherwise the auto updater would install a version that cannot resume a
  running job.

## Tests

`tests/mock_cc.lua` simulates a voxel world with one or more turtles,
EnderStorage chests, rednet, http, GPS and `parallel`. `tests/test_follower.lua`
runs miner, follower and hub together with game time (0.4 s per action), and
`tests/test_resume.lua` stops the turtle at hundreds of points to test the
resume. New behaviour needs a test in `tests/test_miner.lua`
or `tests/test_monitor.lua`. Run a single test with
`lua tests/run.lua "part of the test name"`.

## Protocol changes

The rednet protocol name contains a version (`endermine.v1`). Changes that
break older monitors or turtles must bump it in both programs.

## Releases

Maintainers bump `VERSION` in `src/miner.lua` and `src/minermon.lua`, move the
changelog entries into a new version section, commit, and run `make release`.

`make release` pushes the branch and the tag `v<VERSION>`. If the GitHub CLI
is logged in or `GH_TOKEN` is set, it creates the release with the files from
`dist/`. Otherwise it opens the release page in the browser with tag, title
and notes filled in, and the files from `dist/` have to be dropped in by hand.
`make release-check` shows which way will be used, `RELEASE_MODE=gh` or
`RELEASE_MODE=browser` forces one.
