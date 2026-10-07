# GTNH OpenComputers BEC Line Control

Fail-closed automation for the GT New Horizons 2.9 Bose-Einstein
Condensate line.

The controller coordinates:

- a shared Containment Field behind a dynamically filtered Maxwell Gate;
- an AE2 blocking subnetwork containing exactly one cobblestone lock item;
- an Observation Array and one IO Node;
- ten filtered nanite storage cells selected by chest slot;
- a Transposer between the cell chest and two accelerated ME IO Ports;
- a Teleportation Node Controller Hatch configured to pause at nanite steps.

This project targets the OpenComputers integration at commit
`1e4559ff5f2443695cb28c7cdc9fba87219a862b`.

## Safety model

The IO Node remains paused while condensate routing or nanite cells change.
The lock is released only after the recipe completes, the active cell returns
home, and Maxwell Gate filters clear.

Any timeout, missing cell, transfer failure, unexpected machine state, or
failed postcondition leaves the IO Node paused and the lock present.

The script does not control Containment Field power. The field must remain
powered independently.

## Physical topology

```text
Cell chest (slots 1-10)
            |
        Transposer
       /          \
cell -> network   network -> cell
    ME IO Port    ME IO Port
        \          /
        nanite AE subnet
               |
      ME Storage Bus facing
      Nanite Containment Bus
      in Observation Array
```

The tested Transposer orientation is:

- east (`5`): cell chest;
- north (`2`): cell-to-network IO Port;
- south (`3`): network-to-cell IO Port.

Both IO Ports should contain acceleration cards.

Chest slots map directly to nanite tiers:

| Slot | Tier | Nanite |
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

Empty chest slots are allowed. A cycle fails closed only if its requested tier
is missing. Adding a tier later requires placing its filtered cell into the
already configured slot; no code patch is required.

## Nanite counts

GTNH 2.9 beta-3:

```lua
naniteCount = 2048
```

RC-1 and later:

```lua
naniteCount = 30720
```

The value is a minimum. Cells may contain more; loading succeeds when the IO
Node reports at least the configured count. Unloading always waits for exactly
zero.

## Other required connections

- Adapter touching the IO Node controller (`bec_io_node`).
- Adapter touching the Maxwell Gate controller (`bec_diode`).
- Adapter touching the Containment Field controller (`bec_storage`).
- Adapter touching an ME Interface on the lock/staging network.
- Redstone component with separate outputs for:
  - Teleportation Node Controller Hatch;
  - cobblestone lock removal.
- Transposer connected directly to the OC network.

Configure the Teleportation Node Controller Hatch to pause on nanite-step
transitions.

## Installation

```sh
wget -f https://raw.githubusercontent.com/vnesterovskyi/GTNH-OC-BEC-Line/main/becinstall.lua
becinstall
```

The installer updates program files and preserves an existing `config.lua`.

For a new installation:

```sh
cp config.example.lua config.lua
edit config.lua
becctl selftest
```

Component addresses may be full UUIDs, unique prefixes, or empty when exactly
one component of that type is visible.

## Configuration migration

The cell-carousel version removes these old settings:

```text
warehouseInterface
exportBus
importBus
bridgeTransposer
bridge
nanites
commissioning
```

Replace them with:

```lua
timing.naniteTransferTimeoutSeconds = 60
cycle.naniteCount = 2048 -- use 30720 on RC-1+

components.cellTransposer = {
  type = "transposer",
  address = "431b799e-00b2-4af7-9d00-0f19bc792e64",
}

cellCarousel = {
  chestSide = sides.east,
  loadPortSide = sides.north,
  unloadPortSide = sides.south,
  cellLabelContains = "Storage Cell",
  tierSlots = {
    [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5,
    [6] = 6, [7] = 7, [8] = 8, [9] = 9, [10] = 10,
  },
}
```

## Commissioning

```sh
becctl selftest
becctl cycle --simulate
becctl probe
becctl status
```

Manual cell checks:

```sh
becctl nanite load 1 2048
becctl nanite status
becctl nanite unload 1
```

Missing tiers appear as `empty` in `probe`; they do not prevent startup.

Run the first real BEC recipe interactively:

```sh
becctl cycle --step
```

After manual commissioning:

```sh
becctl cycle --automatic
```

The controller processes one locked batch and exits.

## Commands

```text
becctl probe
becctl status
becctl selftest
becctl lock status|acquire|release [--force]
becctl gate show|set <fluid...>|clear [--force]
becctl nanite status|load <tier> [minimum]|unload <tier>
becctl cycle --simulate|--step|--automatic
```

## Recovery

The journal records the active nanite tier. On restart, the controller pauses
the IO Node and uses that tier to return any cell left in either IO Port to its
fixed chest slot. Hardware state remains authoritative; an unknown active cell
is preserved rather than guessed.
