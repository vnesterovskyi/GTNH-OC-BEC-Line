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
  local sourceCount = 128
  local buffer = nil
  local target = nil
  local importActive = false
  local lockCount = 1
  local redstoneOutputs = {}
  local gateFilters = {}

  local item = {
    name = "minecraft:cobblestone",
    damage = 0,
    label = "Cobblestone",
  }

  local function stack(size)
    return {
      name = item.name,
      damage = item.damage,
      label = item.label,
      size = size,
    }
  end

  local proxies = {}

  proxies.io = {
    getRequiredCondensate = function() return {neutronium = 144} end,
    getConsumedCondensate = function() return {} end,
    getProvidedTier = function() return nil end,
    getRequiredTier = function() return nil end,
    getAvailableNanites = function() return target and target.size or 0 end,
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

  proxies.warehouse = {
    getItemsInNetwork = function(filter)
      if sourceCount > 0 and (filter.name == nil or filter.name == item.name) then
        return {stack(sourceCount)}
      end
      return {}
    end,
  }

  proxies.export = {
    getExportConfiguration = function() return proxies.export.detail end,
    setExportConfiguration = function(_, _, detail)
      proxies.export.detail = detail
    end,
    exportIntoSlot = function()
      if proxies.export.detail == nil or buffer ~= nil or sourceCount == 0 then
        return false
      end
      local amount = math.min(64, sourceCount)
      sourceCount = sourceCount - amount
      buffer = stack(amount)
      return true
    end,
  }

  proxies.import = {
    getImportConfiguration = function() return proxies.import.detail end,
    setImportConfiguration = function(_, _, detail)
      proxies.import.detail = detail
      importActive = detail ~= nil
    end,
  }

  proxies.transposer = {
    getStackInSlot = function(side)
      if side == config.bridge.bufferSide then return buffer end
      if side == config.bridge.targetSide then return target end
      return nil
    end,
    transferItem = function(sourceSide, targetSide, count)
      if sourceSide == config.bridge.bufferSide and targetSide == config.bridge.targetSide then
        if buffer == nil then return 0 end
        local moved = math.min(count, buffer.size)
        buffer.size = buffer.size - moved
        target = target or stack(0)
        target.size = target.size + moved
        if buffer.size == 0 then buffer = nil end
        return moved
      elseif sourceSide == config.bridge.targetSide and targetSide == config.bridge.bufferSide then
        if target == nil or buffer ~= nil then return 0 end
        local moved = math.min(count, target.size)
        target.size = target.size - moved
        buffer = stack(moved)
        if target.size == 0 then target = nil end
        return moved
      end
      return 0
    end,
  }

  proxies.lock = {
    getItemsInNetwork = function()
      return lockCount == 1 and {stack(1)} or {}
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
    warehouse = "me_interface",
    export = "me_exportbus",
    import = "me_importbus",
    transposer = "transposer",
    lock = "me_interface",
    redstone = "redstone",
  }

  local fakeComponent = {}
  function fakeComponent.list(componentType)
    local addresses = {}
    for address, currentType in pairs(componentTypes) do
      if currentType == componentType then
        addresses[#addresses + 1] = address
      end
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
    if importActive and buffer ~= nil then
      sourceCount = sourceCount + buffer.size
      buffer = nil
    end
  end

  local testConfig = dofile("config.example.lua")
  testConfig.components.ioNode.address = "io"
  testConfig.components.gate.address = "gate"
  testConfig.components.storage.address = "storage"
  testConfig.components.warehouseInterface.address = "warehouse"
  testConfig.components.exportBus.address = "export"
  testConfig.components.importBus.address = "import"
  testConfig.components.bridgeTransposer.address = "transposer"
  testConfig.components.lockInterface.address = "lock"
  testConfig.components.redstone.address = "redstone"

  local hardware = require("lib.hardware").build(testConfig)
  hardware.pause:setPaused(true)
  assert(hardware.pause:isPaused(), "pause adapter did not assert output")

  hardware.gate:setExact({infinity = 1, neutronium = 1})
  assert(table.concat(hardware.gate:names(), ",") == "infinity,neutronium", "gate adapter mismatch")
  hardware.gate:clear()

  hardware.bridge:load(item, 65)
  assert(hardware.bridge:targetCount() == 65, "bridge forward transfer mismatch")
  assert(buffer == nil, "bridge left buffer contents after load")
  hardware.bridge:unload()
  assert(target == nil and buffer == nil, "bridge reverse transfer left contents")
  assert(sourceCount == 128, "bridge did not restore warehouse count")

  hardware.lock:release()
  assert(lockCount == 0, "lock adapter did not release token")

  package.loaded["component"] = oldComponent
  package.loaded["computer"] = oldComputer
  os.sleep = oldSleep
  print("ok hardware adapters")
end

runHardwareAdapterTest()
