package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["sides"] = function()
  return {
    bottom = 0,
    top = 1,
    back = 2,
    front = 3,
    right = 4,
    left = 5,
    down = 0,
    up = 1,
    north = 2,
    south = 3,
    west = 4,
    east = 5,
  }
end

local controller = require("lib.controller")
local simulator = require("lib.simulator")
local config = dofile("config.example.lua")

simulator.runSelfTests(controller, config)

local function runHardwareAdapterTest()
  local time = 0
  local availableNanites = 0
  local providedTier = nil
  local lockCount = 1
  local redstoneOutputs = {}
  local gateFilters = {}
  local inventories = {
    [config.cellCarousel.chestSide] = {
      size = 10,
      slots = {
        [1] = {name = "appliedenergistics2:item.ItemBasicStorageCell.4k", label = "4k ME Storage Cell", size = 1, tier = 1, amount = 4096},
        [2] = {name = "appliedenergistics2:item.ItemBasicStorageCell.4k", label = "4k ME Storage Cell", size = 1, tier = 2, amount = 2048},
      },
    },
    [config.cellCarousel.loadPortSide] = {size = 6, slots = {}},
    [config.cellCarousel.unloadPortSide] = {size = 6, slots = {}},
  }

  local function firstCell(side)
    local inventory = inventories[side]
    for slot = 1, inventory.size do
      local stack = inventory.slots[slot]
      if stack ~= nil then
        return slot, stack
      end
    end
  end

  local proxies = {}
  proxies.io = {
    getRequiredCondensate = function() return {neutronium = 144} end,
    getConsumedCondensate = function() return {} end,
    getProvidedTier = function()
      return providedTier and {name = "T" .. providedTier, tier = providedTier} or nil
    end,
    getRequiredTier = function() return {name = "T1", tier = 1} end,
    getAvailableNanites = function() return availableNanites end,
    getRecipeSteps = function() return {} end,
    getState = function() return "idle" end,
    getMinParallel = function() return 1 end,
    getMaxParallel = function() return 1 end,
    getManualSlowdown = function() return 1 end,
    setMinParallel = function() end,
    setMaxParallel = function() end,
    setSpeedDivisor = function() end,
  }

  proxies.gate = {
    getCondensateFilterCount = function() return 4 end,
    getCondensateFilters = function() return gateFilters end,
    setCondensateFilters = function(filters)
      gateFilters = {}
      for slot, fluid in pairs(filters) do gateFilters[slot] = fluid end
    end,
  }

  proxies.storage = {
    getFieldStrength = function() return 1000 end,
    setFieldStrength = function() end,
    getStoredCondensate = function() return {neutronium = 144} end,
  }

  proxies.transposer = {
    getInventorySize = function(side)
      return inventories[side] and inventories[side].size or 0
    end,
    getStackInSlot = function(side, slot)
      return inventories[side] and inventories[side].slots[slot] or nil
    end,
    transferItem = function(sourceSide, targetSide, count, sourceSlot, sinkSlot)
      local source = inventories[sourceSide]
      local target = inventories[targetSide]
      if source == nil or target == nil or count ~= 1 then return 0 end
      local stack = source.slots[sourceSlot]
      if stack == nil then return 0 end

      if sinkSlot == nil then
        for slot = 1, target.size do
          if target.slots[slot] == nil then
            sinkSlot = slot
            break
          end
        end
      end
      if sinkSlot == nil or target.slots[sinkSlot] ~= nil then return 0 end

      source.slots[sourceSlot] = nil
      target.slots[sinkSlot] = stack
      return 1
    end,
  }

  proxies.lock = {
    getItemsInNetwork = function()
      return lockCount == 1 and {{name = "minecraft:cobblestone", damage = 0, size = 1}} or {}
    end,
  }

  proxies.redstone = {
    getOutput = function(side) return redstoneOutputs[side] or 0 end,
    setOutput = function(side, value)
      redstoneOutputs[side] = value
      if side == config.lock.releaseSide and value == config.lock.releaseActiveOutput then
        lockCount = 0
      end
    end,
  }

  local componentTypes = {
    io = "bec_io_node",
    gate = "bec_diode",
    storage = "bec_storage",
    transposer = "transposer",
    lock = "me_interface",
    redstone = "redstone",
  }

  local fakeComponent = {}
  function fakeComponent.list(componentType)
    local addresses = {}
    for address, currentType in pairs(componentTypes) do
      if currentType == componentType then addresses[#addresses + 1] = address end
    end
    table.sort(addresses)
    local index = 0
    return function()
      index = index + 1
      local address = addresses[index]
      if address then return address, componentTypes[address] end
    end
  end
  function fakeComponent.proxy(address) return proxies[address] end
  function fakeComponent.methods(address)
    local result = {}
    for name, value in pairs(proxies[address]) do
      if type(value) == "function" then result[name] = true end
    end
    return result
  end

  local oldComponent = package.loaded["component"]
  local oldComputer = package.loaded["computer"]
  local oldSleep = os.sleep
  package.loaded["component"] = fakeComponent
  package.loaded["computer"] = {uptime = function() return time end}
  os.sleep = function(seconds)
    time = time + seconds
    local _, loadCell = firstCell(config.cellCarousel.loadPortSide)
    local _, unloadCell = firstCell(config.cellCarousel.unloadPortSide)
    if loadCell ~= nil and availableNanites == 0 then
      availableNanites = loadCell.amount
      providedTier = loadCell.tier
    elseif unloadCell ~= nil and availableNanites > 0 then
      availableNanites = 0
      providedTier = nil
    end
  end

  local testConfig = dofile("config.example.lua")
  testConfig.components.ioNode.address = "io"
  testConfig.components.gate.address = "gate"
  testConfig.components.storage.address = "storage"
  testConfig.components.cellTransposer.address = "transposer"
  testConfig.components.lockInterface.address = "lock"
  testConfig.components.redstone.address = "redstone"

  local hardware = require("lib.hardware").build(testConfig)
  hardware.pause:setPaused(true)
  assert(hardware.pause:isPaused(), "pause adapter did not assert output")

  hardware.gate:setExact({infinity = 1, neutronium = 1})
  assert(table.concat(hardware.gate:names(), ",") == "infinity,neutronium", "gate adapter mismatch")
  hardware.gate:clear()

  local initial = hardware.nanites:status()
  assert(initial.tiers[1].state == "home", "tier-1 cell not detected")
  assert(initial.tiers[3].state == "empty", "empty tier slot was not tolerated")

  hardware.nanites:load(1, 2048, true)
  assert(availableNanites == 4096, "oversized cell was not accepted")
  assert(hardware.nanites:status().tiers[1].state == "empty", "tier-1 cell did not leave home")

  hardware.nanites:load(2, 2048, true)
  assert(inventories[config.cellCarousel.chestSide].slots[1] ~= nil, "tier-1 cell did not return home")
  assert(availableNanites == 2048 and providedTier == 2, "tier-2 cell did not load")

  hardware.nanites:unload(2)
  assert(availableNanites == 0, "nanites remained after unload")
  assert(inventories[config.cellCarousel.chestSide].slots[2] ~= nil, "tier-2 cell did not return home")

  local missingTierLoaded = pcall(function()
    hardware.nanites:load(3, 2048, true)
  end)
  assert(not missingTierLoaded, "empty tier slot unexpectedly loaded")
  assert(availableNanites == 0, "missing tier test changed nanite inventory")

  hardware.lock:release()
  assert(lockCount == 0, "lock adapter did not release token")

  package.loaded["component"] = oldComponent
  package.loaded["computer"] = oldComputer
  os.sleep = oldSleep
  print("ok hardware adapters")
end

runHardwareAdapterTest()
