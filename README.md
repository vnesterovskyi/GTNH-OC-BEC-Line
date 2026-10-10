# GTNH OpenComputers BEC Line Control

Fail-closed automation for the
[GT New Horizons Bose-Einstein Condensate line](https://wiki.gtnewhorizons.com/wiki/Bose-Einstein_Condensate_Line).

The controller coordinates:

- exact Maxwell Gate condensate routing;
- tiered nanite storage-cell loading and unloading;
- Teleportation Node Controller Hatch pause/resume transitions;
- one-to-four AE2 lock tokens per batch;
- crash recovery and safe cleanup;
- one-shot or continuous unattended operation.

This project targets the GTNH OpenComputers integration at commit
`1e4559ff5f2443695cb28c7cdc9fba87219a862b`.

## Scope and operating model

This controller starts after external automation has staged a BEC recipe and
placed at least one cobblestone token in the lock chest. It does not:

- construct or power the Containment Field;
- meter recipe ingredients or condensates;
- submit crafting jobs;
- keep the OpenComputers computer powered;
- automatically restart after a fault or computer reboot.

The script owns the Maxwell Gate filters, nanite-cell carousel, pause signal,
and lock release while it is running. Do not let another controller mutate
those devices concurrently.

## Safety guarantees

The design is fail-closed:

1. The Controller Hatch pause signal is asserted before routing or cell changes.
2. The Maxwell Gate exposes only the exact condensates required by the active
   recipe.
3. Idle state uses `water` as a registered non-condensate blocking filter.
4. The active nanite cell must return to its fixed chest slot before cleanup
   continues.
5. The water barrier must be restored before the lock is released.
6. Any timeout, invalid inventory, missing cell, transfer failure, unexpected
   IO state, or failed postcondition stops the daemon with the IO Node paused.

An empty Maxwell Gate filter exposes every condensate. Never use an empty
filter as the idle state.

The script does not control Containment Field power. Keep the field powered
independently whenever condensate is present.

## Prerequisites

### In-game infrastructure

- A functioning BEC line:
  - Entanglement Apparatus;
  - shared Containment Field;
  - Maxwell Gate;
  - Observation Array;
  - IO Node.
- A Teleportation Node Controller Hatch configured for nanite-step pausing.
- An OpenComputers computer with:
  - OpenOS;
  - enough component capacity for all connected devices;
  - an Internet Card for installation and updates;
  - persistent writable storage.
- Three physically isolated AE2 networks:
  - recipe ingredient network;
  - nanite network;
  - lock network.
- Two Transposers:
  - nanite-cell carousel Transposer;
  - lock-release Transposer.
- Two accelerated ME IO Ports for the nanite carousel.
- One chest for tiered nanite storage cells.
- One filtered lock chest and one Item Trash Can.
- One ME Storage Bus facing the Observation Array Nanite Containment Bus.
- OpenComputers Adapters or direct component connections for the BEC devices.
- A redstone component connected to the Controller Hatch.

### Version-specific nanite capacity

Use the correct minimum nanite count for the GTNH release:

| GTNH version | `cycle.naniteCount` |
|---|---:|
| 2.9 beta-3 | `2048` |
| RC-1 and later | `30720` |

The configured count is a minimum. A cell may contain more. Loading succeeds
when the IO Node reports at least the configured amount; unloading waits for
exactly zero.

## Complete physical layout

### BEC path

```text
Entanglement Apparatus
          |
Shared Containment Field
          |
     Maxwell Gate
          |
  Observation Array
          |
        IO Node
```

Connect OpenComputers Adapters to:

| Device | Component type |
|---|---|
| IO Node controller | `bec_io_node` |
| Maxwell Gate controller | `bec_diode` |
| Containment Field controller | `bec_storage` |

The adapters, both Transposers, and the redstone component must be on the same
OpenComputers component network.

### Nanite network

```text
                    +-----------------------+
                    | Cell chest, slots 1-10|
                    +-----------+-----------+
                                |
                           Transposer
                          /          \
                         /            \
             cell -> network       network -> cell
                 ME IO Port          ME IO Port
                         \            /
                          nanite AE subnet
                                |
                       ME Storage Bus facing
                    Nanite Containment Bus in
                       the Observation Array
```

The tested Transposer orientation is:

| Transposer side | Numeric side | Connected inventory |
|---|---:|---|
| East | `5` | Cell chest |
| North | `2` | Cell-to-network ME IO Port |
| South | `3` | Network-to-cell ME IO Port |

These directions are examples, not requirements. If the physical orientation
differs, update `cellCarousel` in `config.lua`.

Configure the IO Ports as follows:

1. **Cell-to-network port:** imports the inserted cell's contents into the
   nanite subnet.
2. **Network-to-cell port:** exports the nanite subnet back into the inserted
   cell.
3. Install acceleration cards in both ports.
4. Keep both ports empty before initial commissioning.

The nanite network must contain only nanite-related storage. Do not attach the
lock chest or recipe ingredient inventories. Empty storage cells can otherwise
absorb cobblestone or other items and return them to the subnet on a later
cycle.

### Nanite cell preparation

Use one partitioned storage cell for each installed nanite tier. Clean every
cell before commissioning; it must not contain cobblestone or unrelated items.

Chest slots map directly to tiers:

| Chest slot | Tier | Typical nanite |
|---:|---:|---|
| 1 | 1 | Carbon or Glowstone |
| 2 | 2 | Silver |
| 3 | 3 | Gold |
| 4 | 4 | Transcendent Metal |
| 5 | 5 | Six-Phased Copper |
| 6 | 6 | White Dwarf Matter |
| 7 | 7 | Black Dwarf Matter |
| 8 | 8 | Universium |
| 9 | 9 | Eternity |
| 10 | 10 | Magmatter |

Missing tiers are allowed. Leave their slots empty. The controller faults only
when an active recipe requests a missing tier.

### Lock network

```text
AE2 batch automation
         |
Filtered lock chest, slots 1-4
         |
   Lock Transposer
         |
   Item Trash Can
```

The tested orientation is:

| Transposer side | Connected inventory |
|---|---|
| North | Lock chest |
| South | Item Trash Can |

The lock network must be physically isolated from the nanite network. A shared
network allows empty nanite cells to absorb lock cobblestone.

External recipe automation must:

1. Deposit one to four cobblestone tokens in lock chest slots 1-4.
2. Stage the corresponding BEC recipe while the token keeps the next batch
   blocked.
3. Leave the token in place until the controller finishes.

At completion, the Lock Transposer captures and removes the current tokens.
The next batch may insert a new token immediately; the controller does not
require the chest to remain empty after release.

### Controller Hatch and redstone

Configure the Teleportation Node Controller Hatch to **Pause Next Step**.

Connect the configured redstone output side to that hatch:

- output `15`: paused/armed;
- output `0`: release the current boundary.

The controller lowers the signal, performs two synchronized IO-state
observations, then raises it again. This gives the server a complete tick to
observe the low signal without relying on wall-clock timing.

## OpenComputers installation

Run these commands from the directory where the controller should live,
normally `/home`:

```sh
cd /home
wget -f https://raw.githubusercontent.com/vnesterovskyi/GTNH-OC-BEC-Line/main/becinstall.lua
becinstall
```

The installer downloads:

```text
becctl.lua
config.example.lua
lib/cli.lua
lib/controller.lua
lib/hardware.lua
lib/journal.lua
lib/simulator.lua
lib/util.lua
```

On first installation it creates `config.lua`. On later runs it updates program
files but preserves the existing `config.lua`.

OpenOS caches loaded Lua modules. Reboot the computer after every update:

```sh
reboot
```

## Component discovery

List visible OpenComputers components:

```sh
components
```

Record the addresses for:

```text
bec_io_node
bec_diode
bec_storage
transposer          # cell carousel
transposer          # lock release
redstone
```

Addresses in `config.lua` may be:

- a full UUID;
- a unique UUID prefix;
- empty only when exactly one component of that type is visible.

Because this design uses two Transposers, configure a unique address or prefix
for each one. Leaving both Transposer addresses empty is ambiguous.

## Configuration

Edit the generated configuration:

```sh
edit /home/config.lua
```

Use this template and replace component addresses and sides for the actual
build:

```lua
local sides = require("sides")

return {
  timing = {
    stagingTimeoutSeconds = 120,
    naniteTransferTimeoutSeconds = 60,
    cycleTimeoutSeconds = 86400,
    completionStableChecks = 2,
  },

  cycle = {
    -- Use 2048 on beta-3 and 30720 on RC-1 or later.
    naniteCount = 2048,
    minParallel = 1,
    maxParallel = 1,
    speedDivisor = 1,
    journalPath = "/home/.bec-line.state",
  },

  components = {
    ioNode = {
      type = "bec_io_node",
      address = "IO-NODE-UUID-OR-UNIQUE-PREFIX",
    },
    gate = {
      type = "bec_diode",
      address = "MAXWELL-GATE-UUID-OR-UNIQUE-PREFIX",
    },
    storage = {
      type = "bec_storage",
      address = "CONTAINMENT-FIELD-UUID-OR-UNIQUE-PREFIX",
    },
    cellTransposer = {
      type = "transposer",
      address = "CELL-TRANSPOSER-UUID-OR-UNIQUE-PREFIX",
    },
    lockTransposer = {
      type = "transposer",
      address = "LOCK-TRANSPOSER-UUID-OR-UNIQUE-PREFIX",
    },
    redstone = {
      type = "redstone",
      address = "REDSTONE-UUID-OR-UNIQUE-PREFIX",
    },
  },

  ioControl = {
    side = sides.north,
    pausedOutput = 15,
    runningOutput = 0,
  },

  gateControl = {
    blockingFluid = "water",
  },

  lock = {
    item = {name = "minecraft:cobblestone", damage = 0},
    chestSide = sides.north,
    chestSlots = {1, 2, 3, 4},
    maxTokens = 4,
    trashSide = sides.south,
  },

  cellCarousel = {
    chestSide = sides.east,
    loadPortSide = sides.north,
    unloadPortSide = sides.south,
    cellLabelContains = "Storage Cell",
    tierSlots = {
      [1] = 1,
      [2] = 2,
      [3] = 3,
      [4] = 4,
      [5] = 5,
      [6] = 6,
      [7] = 7,
      [8] = 8,
      [9] = 9,
      [10] = 10,
    },
  },
}
```

### Configuration reference

| Setting | Meaning |
|---|---|
| `timing.stagingTimeoutSeconds` | Maximum game-time wait for a lock or staged paused recipe in one-shot mode. |
| `timing.naniteTransferTimeoutSeconds` | Maximum game-time wait for the IO Node's available nanite count to reach the expected value. |
| `timing.cycleTimeoutSeconds` | Maximum game-time duration of one active recipe. |
| `timing.completionStableChecks` | Consecutive synchronized `idle` observations required before cleanup. |
| `cycle.naniteCount` | Minimum nanites that must become available after loading a cell. |
| `cycle.minParallel` | IO Node minimum parallel setting. |
| `cycle.maxParallel` | IO Node maximum parallel setting. |
| `cycle.speedDivisor` | IO Node manual slowdown/speed divisor. |
| `cycle.journalPath` | Crash-recovery journal location. |
| `components.*.address` | Full address or unique prefix for each component. |
| `ioControl.side` | Redstone component side connected to the Controller Hatch. |
| `ioControl.pausedOutput` | Output used to pause/arm the hatch. |
| `ioControl.runningOutput` | Output used to release a boundary. |
| `gateControl.blockingFluid` | Registered non-condensate fluid used as the idle barrier. |
| `lock.chestSide` | Lock Transposer side facing the lock chest. |
| `lock.chestSlots` | Chest slots included in one batch lock. |
| `lock.maxTokens` | Maximum total token count accepted. |
| `lock.trashSide` | Lock Transposer side facing the Item Trash Can. |
| `cellCarousel.chestSide` | Cell Transposer side facing the cell chest. |
| `cellCarousel.loadPortSide` | Side facing the cell-to-network IO Port. |
| `cellCarousel.unloadPortSide` | Side facing the network-to-cell IO Port. |
| `cellCarousel.cellLabelContains` | Text used to identify storage-cell items. |
| `cellCarousel.tierSlots` | Nanite tier to fixed chest-slot mapping. |

Timeouts use `computer.uptime()`. OpenComputers advances that clock in server
ticks, so low TPS stretches real-world timeout duration rather than causing a
premature failure.

## Commissioning procedure

Do not skip directly to daemon mode. Complete each stage in order.

### 1. Establish a safe physical baseline

Before running commands:

1. Stop automatic recipe submission.
2. Ensure the IO Node is idle.
3. Keep the Containment Field powered.
4. Empty both nanite IO Ports.
5. Put each installed nanite cell in its mapped chest slot.
6. Confirm every cell is partitioned and free of unrelated items.
7. Empty the lock chest.
8. Confirm the lock chest is not connected to the nanite network.
9. Configure the Controller Hatch for **Pause Next Step**.
10. Confirm the Maxwell Gate can accept `water` as a filter.

### 2. Validate controller logic without hardware mutation

```sh
becctl cycle --simulate
```

Expected result:

- lifecycle reaches `[IDLE] cycle complete`;
- no stack trace or timeout is printed;
- no real component is modified.

Simulation validates the controller state machine and configuration shape. It
does not prove physical side mappings.

### 3. Resolve and inspect components

```sh
becctl probe
```

Verify:

- each logical component resolves to the intended address;
- `cellTransposer` and `lockTransposer` resolve to different devices;
- installed tier slots show `home`;
- intentionally absent tiers show `empty`;
- no storage cell appears in either IO Port.

Typical cell output:

```text
T1 slot 1: home
T2 slot 2: home
T3 slot 3: empty
...
```

Any ambiguity or missing required method must be fixed before continuing.

### 4. Establish the safe idle state

```sh
becctl gate clear
becctl gate show
becctl status
```

The safe idle status is:

```text
IO state: idle
Gate filters: water
Lock count: 0
Nanites available: 0
Provided tier: none
Loaded tier: none
Load IO Port: empty
Unload IO Port: empty
Pause asserted: true
```

Installed cells should show `home`; missing tiers should show `empty`.

If `Pause asserted` is false, correct `ioControl.side` or redstone wiring before
testing cells.

### 5. Verify the lock path

With the IO Node idle:

1. Place one cobblestone in lock chest slot 1.
2. Run:

   ```sh
   becctl lock status
   ```

3. Confirm `Lock count: 1`.
4. Run:

   ```sh
   becctl lock release
   ```

5. Confirm the cobblestone enters the Item Trash Can and the chest clears.
6. Repeat with tokens distributed across slots 1-4.

The Trash Can may report many empty slots through the Transposer API; that is
normal. The important check is that the exact captured token count moves.

### 6. Verify each installed nanite tier

Start with tier 1, using the configured minimum:

```sh
becctl nanite load 1 2048
```

Use `30720` instead of `2048` on RC-1 or later.

Verify:

- the tier-1 chest slot becomes empty;
- the cell is present in the load IO Port;
- `Nanites available` is at least the configured minimum;
- `Provided tier` reports T1;
- the pause signal remains asserted.

Return the cell:

```sh
becctl nanite unload 1
```

Verify:

- available nanites return to `0`;
- both IO Ports are empty;
- the cell returns to chest slot 1.

Repeat for every installed tier:

```sh
becctl nanite load <tier> [minimum]
becctl nanite unload <tier>
```

Never continue commissioning with a cell stranded in an IO Port.

### 7. Verify Maxwell Gate routing

Only while the IO Node is idle, temporarily program known condensate names:

```sh
becctl gate set entangled_infinity
becctl gate show
```

Confirm the Gate shows exactly that filter, then restore the idle barrier:

```sh
becctl gate clear
becctl gate show
```

The final filter must be `water`.

### 8. Run the first real recipe interactively

Prepare one small recipe batch and one lock token, then run:

```sh
becctl cycle --step
```

The controller prompts before every hardware mutation. At each prompt, inspect
the line:

- Gate filters match the required condensates.
- The expected nanite tier is active.
- The IO Node is paused during swaps.
- The previous cell returns home before the next one loads.
- The final cell returns home.
- The Gate returns to `water`.
- The lock token is discarded only after cleanup.

Answer `y` only after confirming the described action is safe.

### 9. Run one automatic batch

Stage another small batch:

```sh
becctl cycle --automatic
```

The command processes one batch and exits. A successful lifecycle ends with:

```text
[COMPLETED]
[CLEANING] returning nanites
[IDLE] cycle complete
```

Afterward, run:

```sh
becctl status
```

Confirm the complete safe-idle checklist from step 4.

### 10. Enable continuous operation

Only after step mode and one-shot automatic mode both succeed:

```sh
becctl cycle --daemon
```

Daemon mode:

- waits indefinitely for the next lock;
- waits indefinitely for the corresponding paused recipe after a lock arrives;
- processes batches sequentially;
- accepts one to four current-batch tokens;
- allows the next token to arrive immediately after release;
- restores cells home and the water barrier between batches;
- stops permanently on the first fault.

The process intentionally runs in the foreground. Keep the OpenComputers
computer and terminal session running. After a computer reboot, start the
daemon again manually.

Normal lifecycle:

```text
[DAEMON] online; faults stop the process
[DAEMON] waiting for batch #1
[WAITING_FOR_LOCK] ready for the next batch
[LOCKED] ... token(s) acquired
[STAGED] waiting for a paused recipe
[ROUTED] programming Maxwell Gate
[NANITE_READY] ...
[RUNNING]
...
[COMPLETED]
[CLEANING] returning nanites
[IDLE] cycle complete
[DAEMON] batch #1 complete; safe idle
[DAEMON] waiting for batch #2
```

## Post-enablement verification checklist

Observe several batches containing tier changes before leaving the line
unattended.

- [ ] No recipe starts before a lock exists.
- [ ] Only the required condensates appear in the Gate during a recipe.
- [ ] The idle Gate filter is always `water`.
- [ ] Exactly one nanite cell is away from home during a recipe.
- [ ] Both IO Ports are empty between batches.
- [ ] Available nanites return to zero between batches.
- [ ] Cobblestone never appears in a nanite cell or nanite subnet.
- [ ] Current lock tokens are removed at completion.
- [ ] An immediately arriving next-batch token remains available.
- [ ] The IO Node remains paused during every tier swap.
- [ ] The daemon stops instead of retrying after an injected or real fault.
- [ ] The Containment Field remains independently powered.

## Command reference

All commands accept an alternate configuration before the command:

```sh
becctl --config=/path/to/config.lua <command>
```

### Inspection

```sh
becctl probe
becctl status
```

### Lock control

```sh
becctl lock status
becctl lock acquire
becctl lock release
becctl lock release --force
```

`lock acquire` waits for at least one token. `lock release` refuses to mutate
while the IO Node is active unless `--force` is supplied.

### Maxwell Gate control

```sh
becctl gate show
becctl gate set <fluid> [fluid...]
becctl gate clear
```

`gate clear` means "restore the water barrier"; it does not leave the filter
empty. Gate mutation refuses to run while the IO Node is active unless
`--force` is supplied.

### Nanite carousel control

```sh
becctl nanite status
becctl nanite load <tier> [minimum]
becctl nanite unload <tier>
```

Manual nanite commands assert pause before moving cells.

### Cycle control

```sh
becctl cycle --simulate
becctl cycle --step
becctl cycle --automatic
becctl cycle --daemon
```

Exactly one cycle mode is required.

## Performance and low-TPS behavior

OpenComputers inventory callbacks are synchronized server operations. The
controller minimizes them by:

- reading a complete Transposer inventory with one `getAllStacks()` callback;
- caching only cell locations it has already verified;
- using a lightweight nanite availability check at recipe boundaries;
- caching verified parallel and speed settings across daemon batches;
- writing the recovery journal only at recovery-critical transitions;
- avoiding extra polling sleeps after synchronized observations.

Cell loading and unloading still validate inventory location, nanite count, and
the reported tier. Recovery never trusts an in-memory cache from a previous
computer process.

Timeouts use game-time ticks. Low TPS increases real-world duration but does
not shorten the number of server transitions allowed. Redstone release uses
synchronized state observations rather than a fixed real-time pulse.

## Recovery after a fault

The daemon never retries automatically. A fault should leave:

- pause asserted;
- the lock present;
- the current Gate filters unchanged or blocked;
- recovery data in `cycle.journalPath`.

Use this procedure:

1. Stop new recipe submission.
2. Keep the Containment Field powered.
3. Record the complete error message.
4. Run:

   ```sh
   becctl status
   ```

5. Inspect both IO Ports, the mapped cell chest slot, Gate filters, lock chest,
   and AE subnet contents.
6. Correct the physical or configuration problem.
7. If the active cell tier is known and the IO Node is not crafting, return it:

   ```sh
   becctl nanite unload <tier>
   ```

8. Restore the idle Gate barrier when safe:

   ```sh
   becctl gate clear
   ```

9. Release lock tokens only after confirming the recipe is finished and all
   cleanup is complete:

   ```sh
   becctl lock release
   ```

10. Confirm safe idle with `becctl status`.
11. Restart `becctl cycle --daemon`.

Do not delete the journal as a first response. It records the last known active
nanite tier and allows cycle startup to reconcile an interrupted operation.

If an active cell exists but its tier is unknown, the controller preserves it
instead of guessing a chest slot. Identify the cell manually, then use the
matching `nanite unload <tier>` command.

Use `--force` only after understanding why the normal idle-state guard refused
the operation.

## Troubleshooting

### Component address is ambiguous

Cause: more than one component of a configured type matches an empty or short
prefix.

Fix:

1. Run `components`.
2. Assign longer unique prefixes in `config.lua`.
3. Pay particular attention to the two Transposers.
4. Re-run `becctl probe`.

### Component does not expose a required method

Cause: the address points to the wrong component, the Adapter touches the wrong
block, or the mod version does not provide the expected integration.

Fix the physical connection or address. Do not bypass method validation.

### `becctl probe` shows a required tier as empty

Check:

- the cell is in the chest slot mapped to that tier;
- its item label contains `cellLabelContains`;
- the chest is on `cellCarousel.chestSide`;
- the cell is not stranded in either IO Port.

Missing tiers that no recipe uses are allowed.

### IO Node reports zero nanites after loading

Check:

- the load and unload IO Ports are not reversed;
- the cell-to-network port is configured in the correct direction;
- both IO Ports contain acceleration cards;
- the Storage Bus faces the Nanite Containment Bus;
- the nanite subnet is powered;
- the cell contains the expected nanites;
- `cycle.naniteCount` matches the GTNH version.

### Wrong provided tier

The cell in the mapped slot contains the wrong nanites or multiple nanite types
are visible. Stop automation, clean and repartition the cell, verify subnet
isolation, then repeat manual load/unload commissioning.

### Cobblestone accumulates in nanite cells

The lock chest or lock AE network is connected to the nanite subnet. Physically
separate the networks, clean every affected cell, and repeat nanite
commissioning.

### Storage cells appear in both IO Ports

This is an invalid carousel state. Stop automation and return each cell to the
correct mapped chest slot manually. Do not start the daemon until both ports
are empty.

### Gate appears open while idle

Run:

```sh
becctl gate clear
becctl gate show
```

The result must contain only `water`. Verify `gateControl.blockingFluid` and the
Maxwell Gate Adapter if it does not.

### Lock release moved the current token but another token remains

This may be normal immediate handoff from the next batch. The controller
removes only the token count captured for the completed batch and permits a new
token to arrive while release is in progress.

### Updated files do not change behavior

OpenOS has cached old modules. Reboot after running `becinstall`.

### Daemon stopped

This is intentional after any fault. Read the first error, correct its cause,
restore safe idle, and restart the daemon manually. Do not wrap it in an
unconditional retry loop.

### Lock exists but the IO Node remains idle

In daemon mode this is a safe waiting state. The controller keeps the lock,
pause signal, cells-home state, and Maxwell Gate water barrier unchanged until
the corresponding recipe reaches a paused boundary. Check the upstream AE
craft if the wait is unexpected. One-shot `--automatic` and `--step` modes
still use `timing.stagingTimeoutSeconds` and will fault if staging takes too
long.

### Log briefly shows `crafting` before `[ROUTED]`

This can be a normal handoff transition. Component calls are synchronized
across server ticks, so the IO Node may report `crafting` immediately before
the armed Controller Hatch reports its first paused boundary. The controller
keeps pause asserted, leaves the Gate blocked with `water`, keeps nanites home,
and waits for the paused state. If the boundary never appears, the staging
timeout stops the cycle fail-closed.

## Updating

From the installation directory:

```sh
wget -f https://raw.githubusercontent.com/vnesterovskyi/GTNH-OC-BEC-Line/main/becinstall.lua
becinstall
reboot
```

The installer preserves `config.lua`. Compare it with the new
`config.example.lua` after updates.

Obsolete timing fields from earlier versions are ignored and may be removed:

```text
timing.operationTimeoutSeconds
timing.pollSeconds
timing.completionStableSeconds
timing.resumePulseSeconds
cycle.betweenBatchesSeconds
```

Obsolete pre-carousel settings:

```text
warehouseInterface
exportBus
importBus
bridgeTransposer
bridge
nanites
commissioning
lockInterface
```

Replace obsolete settings with the current `components.lockTransposer`,
`components.cellTransposer`, `lock`, `cellCarousel`, `gateControl`, and
`timing.naniteTransferTimeoutSeconds` sections shown above.
