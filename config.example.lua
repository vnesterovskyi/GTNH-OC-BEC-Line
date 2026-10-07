local sides = require("sides")

return {
  timing = {
    pollSeconds = 0.25,
    operationTimeoutSeconds = 30,
    stagingTimeoutSeconds = 120,
    naniteTransferTimeoutSeconds = 60,
    cycleTimeoutSeconds = 86400,
    completionStableSeconds = 2,
    resumePulseSeconds = 0.15,
  },

  cycle = {
    -- beta-3 regular bus capacity. Change to 30720 on RC-1+.
    naniteCount = 2048,
    minParallel = 1,
    maxParallel = 1,
    speedDivisor = 1,
    journalPath = "/home/.bec-line.state",
  },

  components = {
    ioNode = {type = "bec_io_node", address = ""},
    gate = {type = "bec_diode", address = ""},
    storage = {type = "bec_storage", address = ""},
    cellTransposer = {type = "transposer", address = ""},
    lockInterface = {type = "me_interface", address = ""},
    redstone = {type = "redstone", address = ""},
  },

  ioControl = {
    side = sides.north,
    pausedOutput = 15,
    runningOutput = 0,
  },

  lock = {
    item = {name = "minecraft:cobblestone", damage = 0},
    releaseSide = sides.south,
    releaseActiveOutput = 15,
    releaseIdleOutput = 0,
    releasePulseSeconds = 0.5,
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
