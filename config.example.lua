local sides = require("sides")

return {
  timing = {
    pollSeconds = 0.25,
    operationTimeoutSeconds = 30,
    stagingTimeoutSeconds = 120,
    cycleTimeoutSeconds = 86400,
    completionStableSeconds = 2,
    resumePulseSeconds = 0.15,
  },

  cycle = {
    naniteCount = 30720,
    minParallel = 1,
    maxParallel = 1,
    speedDivisor = 1,
    journalPath = "/home/.bec-line.state",
  },

  components = {
    ioNode = {type = "bec_io_node", address = ""},
    gate = {type = "bec_diode", address = ""},
    storage = {type = "bec_storage", address = ""},
    warehouseInterface = {type = "me_interface", address = ""},
    exportBus = {type = "me_exportbus", address = ""},
    importBus = {type = "me_importbus", address = ""},
    bridgeTransposer = {type = "transposer", address = ""},
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

  bridge = {
    exportPartSide = sides.east,
    exportFilterSlot = 1,
    importPartSide = sides.west,
    importFilterSlot = 1,
    bufferSide = sides.north,
    bufferSlot = 1,
    targetSide = sides.south,
    targetSlot = 1,
  },

  -- Fill these from `becctl probe`. Exact item name/damage descriptors are
  -- preferred. Labels are useful for discovery but should not be the only
  -- production identity.
  nanites = {
    [1] = {label = "Carbon Nanites"},
    [2] = {label = "Silver Nanites"},
    [3] = {label = "Gold Nanites"},
    [4] = {label = "Transcendent Metal Nanites"},
    [5] = {label = "Six-Phased Copper Nanites"},
    [6] = {label = "White Dwarf Matter Nanites"},
    [7] = {label = "Black Dwarf Matter Nanites"},
    [8] = {label = "Universium Nanites"},
    [9] = {label = "Eternity Nanites"},
    [10] = {label = "Magmatter Nanites"},
  },

  commissioning = {
    testItem = {name = "minecraft:cobblestone", damage = 0},
    testCount = 1,
  },
}

