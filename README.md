# GTNH OpenComputers BEC Line Control

Fail-closed automation for the GT New Horizons 2.9 Bose-Einstein
Condensate line.

The controller coordinates:

- a shared Containment Field behind a dynamically filtered Maxwell Gate;
- an AE2 blocking subnetwork containing exactly one cobblestone lock item;
- an Observation Array and one IO Node;
- a nanite warehouse connected through programmable AE2 buses, a one-slot
  transfer buffer, and an OpenComputers Transposer;
- a Teleportation Node Controller Hatch configured to pause at nanite-step
  transitions.

This project targets the OpenComputers integration at commit
`1e4559ff5f2443695cb28c7cdc9fba87219a862b`.

## Safety model

The script asserts the IO pause signal before mutating routing or inventory.
It never releases the AE2 lock until the IO Node has completed, nanites have
returned to storage, and Maxwell Gate filters have cleared.

Any component error, timeout, unexpected machine state, ambiguous component
address, transfer shortfall, or failed postcondition enters a fail-closed
state:

- the pause signal remains asserted;
- the lock item remains present;
- active-recipe Gate filters are preserved;
- the failure is written to the journal and surfaced to the operator.

The script does not control Containment Field power. The field must remain
powered independently; power loss or disabling the field voids its contents.

## Physical topology

```text
Main AE2 network
  |
  +-- blocking interface --> BEC item subnetwork
                              +-- dedicated lock chest (one cobblestone)
                              +-- IO Node input/output

Nanite warehouse AE2
  +-- programmable export bus --+
  +-- programmable import bus --+--> one-slot buffer
                                      |
                                  Transposer
                                      |
                              nanite containment bus

Containment Field --> Maxwell Gate --> Observation Array --> IO Node

OC redstone output 1 --> Teleportation Node Controller Hatch
OC redstone output 2 --> lock-item importer/trash mechanism
```

The import and export buses must face the one-slot buffer. The Transposer
must see both the buffer and the nanite containment bus. During commissioning,
replace the nanite bus with an ordinary empty chest.

Configure the Teleportation Node Controller Hatch to pause on a step
transition. The configured redstone `pausedOutput` must arm/pause it, while
`runningOutput` must release it.

## Installation

After this repository is published, install or update from OpenOS with:

```sh
wget -f https://raw.githubusercontent.com/vnesterovskyi/GTNH-OC-BEC-Line/main/install.lua
install
```

The installer updates program files atomically and preserves an existing
`config.lua`.

For a manual installation, copy the repository tree, then:

```sh
cp config.example.lua config.lua
edit config.lua
becctl selftest
```

Add the repository directory to `PATH`, or run commands as
`./becctl.lua ...`.

## Configuration

Copy `config.example.lua` to `config.lua`.

Component addresses may be full UUIDs or unique prefixes. Empty addresses
are accepted only when exactly one component of that type is visible.
Ambiguous prefixes are rejected rather than selecting an arbitrary machine.

Configure:

- every component address;
- OC sides for both AE2 buses and the Transposer;
- separate redstone sides for IO pause and lock release;
- exact item identities for all ten nanite tiers;
- initial commissioning count (`1` or `64`);
- production nanite count (`30720`).

Run `becctl probe` to resolve components and print the full AE2 item details
found for each configured nanite. Replace label-only descriptors with exact
`name` and `damage` values before production.

## Staged commissioning

Do not start with a production BEC recipe.

### 1. Offline simulation

```sh
becctl selftest
becctl cycle --simulate
```

This validates normal cleanup and fail-closed behavior without loading
OpenComputers components.

### 2. Read-only component probe

```sh
becctl probe
becctl status
```

Both commands are read-only.

### 3. Cheap transfer bench

Point the configured bridge target at an empty ordinary chest. Stock the
configured test item (cobblestone by default) in the warehouse AE2 network.

```sh
becctl bench transfer 1
becctl bench transfer 64
```

Each run exports into the one-slot buffer, transfers to the target, verifies
the exact count, returns it through the import bus, and verifies both
inventories are empty.

### 4. Lock mechanism

Use a blocking AE2 pattern containing exactly one cobblestone. It must land
in a dedicated high-priority lock chest on the BEC subnetwork.

```sh
becctl lock acquire
becctl lock status
becctl lock release
```

Verify that a second craft cannot enter until release removes the lock.

### 5. Empty Gate test

With no active recipe and no valuable condensate exposed:

```sh
becctl gate set neutronium infinity
becctl gate show
becctl gate clear
```

Use registry fluid names, not display names.

### 6. Low-count nanite test

Replace the bench chest with the real nanite containment bus:

```sh
becctl nanite load 1 1
becctl nanite status
becctl nanite unload
```

Repeat with `64` only after the single-item test returns cleanly.

### 7. Manual BEC recipe

Use one parallel and the least expensive viable recipe:

```sh
becctl cycle --step
```

The controller asks before each mutation. Inspect the world after every
transition.

### 8. Automatic operation

After manual commissioning:

```sh
becctl cycle --automatic
```

The command processes one locked batch and exits. A service wrapper may call
it repeatedly after the single-cycle behavior is proven.

## Commands

```text
becctl probe
becctl status
becctl selftest
becctl bench transfer [count]
becctl lock status|acquire|release [--force]
becctl gate show|set <fluid...>|clear [--force]
becctl nanite status|load <tier> [count]|unload
becctl cycle --simulate|--step|--automatic
```

Manual Gate or lock mutation is rejected while the IO Node is active unless
`--force` is supplied. Force is deliberately inconvenient; it can destroy a
recipe.

## Recovery

On startup the cycle controller:

1. asserts the pause signal;
2. reads actual IO, lock, Gate, and nanite state;
3. rejects an active recipe without exactly one lock;
4. preserves routing for active work;
5. cleans stale routing and nanites only when the IO Node is idle and no lock
   exists.

The journal aids diagnosis but never overrides observed hardware state.
