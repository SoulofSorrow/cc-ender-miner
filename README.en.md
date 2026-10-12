# cc-ender-miner

[Deutsche Version](README.md)

Tunnel mining for [CC: Tweaked](https://tweaked.cc/) mining turtles with two
ender chests and a live dashboard on a monitor.

- **Ore mode (`miner`, mode `ores`)**: the turtle uses the **geo scanner**
  from Advanced Peripherals to find ores on several Y levels and mines only
  those. It never drives a way twice and keeps its own chunk loaded with the
  **chunky turtle** upgrade. See [Ore mode](#ore-mode-geo-scanner). Tuned for
  **FTB Evolution** (Minecraft 1.21.1).
- **Tunnel mode (`miner`, mode `tunnel`)** digs parallel tunnels of any size,
  places torches, drops cobblestone and similar junk, and sends everything
  else home through an ender chest.
- **Supply chest**: a second ender chest delivers torches (and optionally
  coal). The turtle restocks on its own.
- **Dashboard (`minermon`)** on a computer with an ender modem and a 4x4
  advanced monitor: progress, fuel, inventory, ores found, event log and touch
  buttons for pause, resume and return home. The computer is also the **hub**
  between the miner and the follower.
- **Follower (`follower`)**: optional second turtle with a chunk loader
  upgrade that follows the miner and keeps its chunk loaded. Off by default,
  the miner also works on its own.
- **Station (`station`, `miner dock`)**: a computer with a touch monitor
  hands out ore jobs to the docked turtle through a disk drive. The turtle
  unloads and refuels at the station and takes the next job. See
  [Station](#station-jobs-from-a-touch-monitor).
- **Auto update (`update`)**: all programs keep themselves up to date when
  they start.

Rewritten from scratch, inspired by the "Mining Turtle 3.5" script by PrinceTommen.

## Ore mode (geo scanner)

The turtle digs a shaft down to the first level and drives a grid of scan
points in a serpentine. At each point it briefly swaps its pickaxe for the geo
scanner, scans a sphere with radius 8 and then mines the ores of that section
on the shortest round trip. From the last point of a level it goes straight
down to the next level, which it drives in reverse. No way is driven twice.

**What you need (included in FTB Evolution):**

| Part | Where |
| --- | --- |
| Mining turtle (pickaxe) | pickaxe on the right side (configurable) |
| Chunky turtle upgrade (Advanced Peripherals, "chunk controller") | other side of the turtle, keeps the chunk loaded |
| Geo scanner (Advanced Peripherals) | slot 3, only equipped for scanning |
| 2 EnderStorage ender chests | slot 1 (supply: coal), slot 2 (resources) |
| Coal | slot 4 |

An ender modem is **not needed**. Without one there is just no live
dashboard; the turtle shows its state on its own screen.

**Start:**

1. Place the turtle at the start, facing the mining area. The area lies in
   front of it and extends to the chosen side.
2. Run `miner setup` and enter:
   - **Mode:** `ores`
   - **The turtle's Y:** read it from F3. This is the only coordinate it needs.
   - **Ores:** pick them from the list, e.g. `1,4` for diamond and iron.
   - **Area size, side and return home** at the end.
3. Press Enter. It scans twice first to work out its direction.

**Level presets** (ore distribution since Minecraft 1.18, still valid in 1.21):

| No. | Ore | Y |
| --- | --- | --- |
| 1 | Diamond + redstone | −57 |
| 2 | Gold | −16 |
| 3 | Lapis | 0 |
| 4 | Iron | 16 |
| 5 | Copper | 48 |
| 6 | Coal | 96 |

Each level covers a band 9 blocks high (Y −4 to +4). **All ores** in the band
are mined, including modded ores with the `c:ores` tag (Mekanism, Immersive
Engineering, ...). Use `oreGroups` to limit it to certain **kinds of ore**,
e.g. `{ "diamond", "osmium" }`. A kind covers every variant (stone,
deepslate, nether) from every mod. The setup wizard asks for it and the
station has a screen for it. `oreNames` filters by exact block ids instead.

**Restart safe:** position, level, scan point and the list of ores still to
mine are saved continuously. After a restart the turtle puts its pickaxe back
if it was scanning. An interrupted turn is resolved **without GPS**: it scans,
moves one block and compares the two scans.

**Simulation results** (45×45 area, 2 levels): all 918 ores in the area were
mined while digging only 5 % of the volume. Only 6 % of the moves went through
cells visited before.

**Please check on first use:** the simulation assumes that the geo scanner
returns relative coordinates and has a short cooldown between scans. That is
what the Advanced Peripherals source code says, but it has not been tested in
the real game yet. If the scanner returns something unexpected, the turtle
stops with a clear message instead of digging in the wrong place.

## Station (jobs from a touch monitor)

Instead of typing every job on the turtle, the turtle gets a fixed
**station**. You create ore jobs on a touch monitor, the turtle takes them one
after the other, mines its area, comes back, unloads, refuels and reports the
result.

### Layout

Seen from above (the turtle faces north, the mining direction):

```
            mining direction
                  ^
   [Monitor]
   [Computer][Drive][Turtle]
```

- **Turtle**: mining turtle with a pickaxe, the geo scanner in slot 3 and the
  ender chests in slots 1 and 2 as in the [ore mode](#ore-mode-geo-scanner).
- **Chest above the turtle**: output. After every job the turtle unloads
  slots 5-16 into it (hoppers or pipes can move it on).
- **Chest below the turtle**: fuel. The turtle refuels from it up to
  `dockFuel` (default 5000) and takes a stack along in slot 4.
- **Disk drive with a floppy disk** between the computer and the turtle (on
  one side of the turtle, not in front). Station and turtle exchange jobs and
  reports through the disk, no modem needed.
- **Computer** (advanced) with an **advanced monitor** (2x2 or larger, 3x3 or
  4x4 is nicer) on any side. Without a monitor you click on the screen of the
  advanced computer instead.
- The block in front of the turtle must be diggable, the shaft starts there.

### Installation and start

```sh
install station --startup     # on the computer (also gets miner.lua)
install miner                 # on the turtle
```

1. Start `station` and enter the Y of the turtle once (F3).
2. Run `miner dock` on the turtle. It creates `startup/endermine-dock.lua` and
   waits at the station again after every reboot. Press **Q** to leave the
   dock mode, which also removes the startup file.

### Using it

- **NEW JOB**: tap the levels (several at once, presets per ore), optionally
  an **own Y level** (`Own Y`, set with `--`/`-`/`+`/`++` and switch it
  `ON`, e.g. for modded ores), set the area size (18-90, step 9) and the
  number of areas (1-9), then **CREATE**.
- **ORES**: choose kinds of ore. Without a choice every ore is mined, with a
  choice only those kinds, in every variant. For vanilla ores the matching
  level is selected as well. **Modded ores** appear in the list as soon as
  the turtle has scanned them during a job (even if it did not mine them).
  Page through the list with `<` and `>`.
- **CANCEL** cancels the newest job the turtle has not taken yet.
- The main page shows the turtle (state, fuel, ores of the last job), the
  job list and a map of the areas.

Areas are given out **in a spiral around the station**: the first one in
front and to the right of the turtle, then ring by ring outwards. No area is
given out twice; the area of a cancelled job is used again.

### Restart safety

Everything is kept in files: the jobs in `station.db` on the computer, the
running job in `miner.state` on the turtle, and the last job the turtle took
in `dock.state`. After a chunk unload the turtle finishes the job it started,
reports the result and takes the next one. A job is never taken twice. The
result of the last job is part of every report, so the station does not miss
it even if it was not running at that moment.

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
install station               # station computer (also gets miner.lua)
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
| `mode` | `"tunnel"` | `"ores"` for the ore mode with the geo scanner |
| `startY` | – | Ore mode: Y of the start block (F3) |
| `oreLevels` | `{ -57, 16 }` | Ore mode: Y levels |
| `areaWidth` / `areaLength` | 45 / 45 | Ore mode: size of the area |
| `scanRadius` | 8 | Ore mode: scan radius (8 is free) |
| `oreNames` | `{}` | Ore mode: only these block ids, empty = every ore |
| `oreGroups` | `{}` | Ore mode: only these kinds of ore (`"diamond"`, `"osmium"`, ...), empty = every ore |
| `toolSide` | `"right"` | Ore mode: side of the pickaxe |
| `returnHome` | `true` | Ore mode: drive back to the start at the end |
| `areaOffsetX` / `areaOffsetZ` | 0 / 0 | Ore mode: offset of the area (set by the station) |
| `dockFuel` | 5000 | Dock mode: fuel level the turtle refuels to at the station |

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
make release    # push branch and tag v<VERSION>, create a GitHub release
                # (without a gh login the release page opens in the browser)
```

The tests simulate the world, turtle, ender chests and rednet
(`tests/mock_cc.lua`) and run without Minecraft. See
[CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

[GPL-3.0-or-later](LICENSE). The idea and the original digging pattern come
from "Mining Turtle 3.5" by PrinceTommen (made for CyanideEpic). This code is
an independent reimplementation.
