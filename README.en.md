# cc-ender-miner

[Deutsche Version](README.md)

Tunnel mining for [CC: Tweaked](https://tweaked.cc/) mining turtles with two
ender chests and a live dashboard on a monitor.

- **Turtle (`miner`)** digs parallel tunnels of any size, places torches,
  drops cobblestone and similar junk, and sends everything else home through
  an ender chest.
- **Supply chest**: a second ender chest delivers torches (and optionally
  coal). The turtle restocks on its own.
- **Dashboard (`minermon`)** on a computer with an ender modem and a 4x4
  advanced monitor: progress, fuel, inventory, ores found, event log and touch
  buttons for pause, resume and return home. The computer is also the **hub**
  between the miner and the follower.
- **Follower (`follower`)**: optional second turtle with a chunk loader
  upgrade that follows the miner and keeps its chunk loaded. Off by default,
  the miner also works on its own.
- **Auto update (`update`)**: all programs keep themselves up to date when
  they start.

Rewritten from scratch, inspired by the "Mining Turtle 3.5" script by PrinceTommen.

## Requirements

| What | Why |
| --- | --- |
| CC: Tweaked | Turtle and computer |
| [EnderStorage](https://www.curseforge.com/minecraft/mc-mods/ender-storage-1-8) | Ender chests that turtles can access (vanilla ender chests do **not** work) |
| Mining turtle with ender modem | Pickaxe on one side, ender modem on the other |
| Computer with ender modem | Receives the telemetry |
| Advanced monitor, 4x4 recommended (2x2 works too) | Colour and touch for the dashboard |
| Optional: second turtle with a chunk loader upgrade and an ender modem | Follower that keeps the miner's chunk loaded |

A wireless modem also works but has a limited range. The ender modem works
at any distance and across dimensions.

## Setting up the ender chests

EnderStorage chests are linked by their three colour codes. You need two
pairs with **different** colours:

| Chest at the turtle | Counterpart at your base | Contents |
| --- | --- | --- |
| Slot 1: supply | e.g. white-white-yellow | Fill with torches, optionally coal |
| Slot 2: resources | e.g. white-white-blue | Everything mined ends up here. Ideally empty it with hoppers or a sorting system |

When the resource chest is full, the turtle waits and the dashboard shows
**CHEST FULL**.

## Turtle slot layout

| Slot | Contents |
| --- | --- |
| 1 | **Supply** ender chest (torches) |
| 2 | **Resource** ender chest |
| 3 | Torches (refilled automatically) |
| 4 | Fuel (coal, charcoal, coal block, ...) |
| 5-16 | Keep empty, mined items go here |

## Installation

The HTTP API must be enabled in the CC: Tweaked config (default).

```sh
wget run https://raw.githubusercontent.com/SoulofSorrow/cc-ender-miner/main/src/install.lua
```

A turtle gets `miner`, a computer gets `minermon`. For the follower, name the
role. Add `--startup` to also create a `startup.lua`:

```sh
wget https://raw.githubusercontent.com/SoulofSorrow/cc-ender-miner/main/src/install.lua install
install monitor --startup     # hub computer
install miner                 # mining turtle
install follower              # follower turtle (also gets miner.lua for the geometry)
```

Every role also gets `update.lua`, the auto updater. You can also copy the
files from `src/` by hand.

## Usage

### Start the dashboard

Build a computer with an ender modem and a 4x4 monitor, then run:

```sh
minermon        # text scale 0.5 (default, ideal for 4x4)
minermon 1      # larger text
```

On smaller monitors (e.g. 2x2) the dashboard switches to a compact layout
automatically: only the essential values, ores, events and short buttons.
Keep the default text scale 0.5 there, `minermon 1` gets very cramped.

`Q` quits. `id` shows the computer id. Enter it on the turtle as "Monitor PC
id" so the turtle only accepts commands from that computer.

### Start the turtle

Place the turtle at the start point, facing the direction of the first tunnel.
Fill the slots as shown above, then run:

```sh
miner           # shows the saved configuration, Enter starts
miner setup     # run the wizard again
miner resume    # continue an interrupted job (the startup file does this automatically)
```

On the first start a wizard asks for all values and saves them to `miner.cfg`.

### Digging pattern

```
 Top view (side = right, 3 tunnels, width 3, spacing 3)

   z ^   ###...###...###
     |   ###...###...###
     |   ###...###...###
     |   ###...###...###
   1 |   ###############   <- connecting corridor at floor level
   0 |   T
     +------------------> x
```

- The first tunnel starts directly in front of the turtle, further tunnels are
  dug to the right or left (`side`).
- Each pass clears three rows (top, middle, bottom). Taller tunnels are dug in
  several layers.
- Torches stand on the floor along the first column of every tunnel, every
  `torchInterval` blocks.
- At the end the turtle returns to its start block and faces forward again.

### Dashboard buttons

| Button | Effect |
| --- | --- |
| PAUSE | The turtle stops at its next step |
| RESUME | Continue |
| HOME | Abort and return to the start (tap twice to confirm) |
| REFRESH | Request an immediate status update |

With several turtles, tabs appear at the top. Turtles that have not reported
for 15 seconds are shown as **NO SIGNAL**.

## Configuration (`miner.cfg`)

| Key | Default | Meaning |
| --- | --- | --- |
| `tunnels` | 3 | Number of parallel tunnels |
| `width` / `height` / `length` | 3 / 3 / 48 | Tunnel size in blocks |
| `spacing` | 3 | Solid blocks between two tunnels |
| `side` | `"right"` | Side for additional columns and tunnels |
| `useTorches` / `torchInterval` | `true` / 8 | Place torches and their distance |
| `dropJunk` / `junkItems` | `true` / list | Drop junk instead of storing it |
| `refuelFromLoot` / `fuelItems` | `true` / coal | Burn mined coal when fuel runs low |
| `torchItems` | `minecraft:torch` | Items accepted as torches |
| `fuelReserve` / `fuelBuffer` | 100 / 1000 | Reserve on top of the way home, amount taken when refuelling |
| `minFreeSlots` | 2 | Unload when this few slots are free |
| `reportInterval` | 2 | Seconds between status updates |
| `controllerId` | `nil` | Id of the dashboard computer. `nil` broadcasts and accepts commands from anyone |
| `returnOnError` | `true` | Return to the start after an error |
| `useFollower` | `false` | Work together with a follower turtle (chunk loader) |

## Failure handling

| Situation | Reaction |
| --- | --- |
| Out of fuel | Takes coal from the supply chest, otherwise shows **NO FUEL** and waits |
| Out of torches | Restocks; if the chest is empty it keeps digging without torches (warning) |
| Resource chest full | Waits, shows **CHEST FULL** |
| Unbreakable block (bedrock) | Aborts and returns home, using detours if needed |
| Gravel/sand | Dug until nothing falls anymore |
| Another turtle in the way | Never mined, the turtle waits |
| Foreign items in the supply chest | Sent to the resource chest |
| Vanilla ender chest | Rejected before the start |
| Chunk unloaded / logged out | Continues automatically after the reload (see below) |
| Restart in the middle of a turn without GPS | Shows **LOST**, the turtle stays where it is |

## Logging out, chunk unloads and server restarts

Minecraft stops a turtle as soon as its chunk unloads: you log out, move too
far away, or the server restarts. No script can prevent that. `miner` makes
sure the job **continues on its own exactly where it stopped**:

- Position, facing and progress are saved continuously (`miner.state`,
  `miner.pos`).
- When a job starts, `miner` creates `startup/endermine.lua`. When the chunk
  loads again, CC: Tweaked boots the turtle and the job continues after
  5 seconds. Pressing a key at that moment cancels it.
- These files are removed when the job ends.
- When you start `miner` by hand and an interrupted job exists, it asks
  whether to resume it.
- An ender chest that was standing outside is picked up again after the
  restart.
- The dashboard shows **RESUMING** and counts the restarts.

**Important – set up GPS:** a move that happened exactly when the chunk
unloaded is detected through the fuel level. A **turn** uses no fuel, though.
If the turtle is stopped during a turn (rare, but it happens), it cannot be
sure where it is facing. Without GPS it then stops with **LOST** instead of
digging in the wrong direction. With GPS it measures its facing again and
continues. The same applies to servers with unlimited fuel.

GPS tower with ender modems (works in the whole dimension, one tower is
enough):

1. Place four computers with one ender modem each, not all on one level,
   e.g. the corners of a cube a few blocks apart.
2. On each computer read the exact position **of the modem** with F3 and put
   `gps host <x> <y> <z>` into its `startup.lua`.
3. Test on the turtle: `gps locate` must print a position.

The turtle detects GPS by itself when a job starts and reports
"GPS available".

**Keep mining while you are away:** the chunk has to stay loaded: with the
[follower turtle](#follower-turtle-chunk-loader), with `/forceload` or with a
server chunk claim (FTB Chunks or similar) over the mining area. With a
pickaxe and an ender modem the miner has no free upgrade slot left. The hub
computer and the ender chests at your base must be loaded too for the
display, the relay and the chests to work.

## Follower turtle (chunk loader)

**Optional.** A second turtle with a **chunk loader upgrade** and an **ender
modem** (no pickaxe needed) follows the miner and keeps its chunk loaded.
Without a follower the miner works the same; it is only stopped by a chunk
unload and continues afterwards. The hub
computer connects the two: it relays the miner's position and progress to the
follower.

**Setup**

1. Switch the follower on in the miner: run `miner setup` and answer `y` to
   "Chunk loader follower" (or set `useFollower = true` in `miner.cfg`). When
   it is off, the hub assigns no follower to the miner and releases one that
   is already paired.
2. Install the follower with `install follower` and put some coal into its
   inventory.
3. Place it **directly behind** the miner's start block, facing the same
   direction.
4. Start `follower`. On the first start it asks for the hub computer's id and
   optionally the miner's id. `-1` means the hub assigns the next free miner.
5. Start the miner. The follower appears as its own tab on the dashboard with
   its distance to the miner and the state of its chunk loader.

**How it stays out of the way**

- It only drives through blocks the miner has provably dug already. It never
  digs itself.
- It only waits on **parking cells**: the top row of a 3 block high band in
  the current tunnel, which the miner never drives through, or anywhere in
  finished tunnels. With tunnels lower than 3 it parks in finished tunnels
  only.
- If it ever is in the way, the miner reports it and the hub asks the
  follower to make way.
- In simulations with various tunnel shapes the follower never got in the
  miner's way.

**Chunks and GPS:** with GPS the follower knows the chunk borders. It then
prefers parking cells in the miner's chunk, and the miner reports every chunk
change at once. In the simulations it stayed in the same or a directly
adjacent chunk more than 95 % of the time. If the miner goes silent (its chunk
was unloaded after all), the follower drives up to 2 blocks from its last
known position. The chunk loads again and the miner continues with the
automatic resume.

**Please check:** which chunks your chunk loader upgrade loads (only its own
or the neighbours too) and whether it has to be switched on with `setActive`
depends on the mod. The follower switches upgrades on with `setActive`
automatically and shows "active", "passive" or "none". Without a chunk loader
it still follows but keeps nothing loaded. In single player no chunk loader
helps, because the whole world stops when you log out.

When the job is done, the follower drives **directly in front of the miner**
(block 0/0/1) and stops there.

## Auto update

Miner, follower and hub check for a new version on every start
(`manifest.json` on the `main` branch of the repository). If there is one,
they download only their own files, check each file for valid Lua, replace
them all together and restart.

- **Running jobs:** an interrupted job is only updated when the new version
  can read its saved state. Otherwise the update waits until the job is done.
- **Version check:** the hub shows every device's version and warns when it
  differs from its own.
- **By hand:**

  ```sh
  update            # detects the role
  update follower   # name the role
  update --force    # reinstall even if the version is the same
  ```

- **Switch off or use your own source:**

  ```sh
  set endermine.auto_update false
  set endermine.update_url https://raw.githubusercontent.com/<user>/<repo>/<branch>/
  ```

Without the HTTP API or without network the program simply keeps running the
installed version.

## Development

```sh
make check      # luacheck, StyLua check, offline tests
make format     # format the code
make build      # copy the programs into dist/
make release    # create tag v<VERSION>, push it and create a GitHub release
```

The tests simulate the world, turtle, ender chests and rednet
(`tests/mock_cc.lua`) and run without Minecraft. See
[CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

[GPL-3.0-or-later](LICENSE). The idea and the original digging pattern come
from "Mining Turtle 3.5" by PrinceTommen (made for CyanideEpic). This code is
an independent reimplementation.
