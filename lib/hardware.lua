local util = require("lib.util")

local hardware = {}

local function assertMethod(componentApi, address, method)
  local methods = componentApi.methods(address)
  if methods == nil or methods[method] == nil then
    error("Component " .. address .. " does not expose required method " .. method)
  end
end

local function resolveComponent(componentApi, name, spec, requiredMethods)
  if type(spec) ~= "table" or type(spec.type) ~= "string" then
    error("Missing component configuration for " .. name)
  end

  local prefix = spec.address or ""
  local matches = {}
  for address, componentType in componentApi.list(spec.type) do
    if componentType == spec.type and address:sub(1, #prefix) == prefix then
      matches[#matches + 1] = address
    end
  end

  if #matches == 0 then
    error("No " .. spec.type .. " component matches " .. name .. " address prefix '" .. prefix .. "'")
  elseif #matches > 1 then
    error("Address prefix for " .. name .. " is ambiguous: " .. table.concat(matches, ", "))
  end

  local address = matches[1]
  for _, method in ipairs(requiredMethods) do
    assertMethod(componentApi, address, method)
  end

  return componentApi.proxy(address), {
    name = name,
    type = spec.type,
    address = address,
    methods = requiredMethods,
  }
end

local PauseControl = {}
PauseControl.__index = PauseControl

function PauseControl.new(proxy, config, environment)
  return setmetatable({
    proxy = proxy,
    config = config,
    environment = environment,
  }, PauseControl)
end

function PauseControl:setPaused(paused)
  local expected = paused and self.config.pausedOutput or self.config.runningOutput
  self.proxy.setOutput(self.config.side, expected)
  local actual = self.proxy.getOutput(self.config.side)
  if actual ~= expected then
    error("Pause redstone output did not reach " .. tostring(expected) .. "; actual " .. tostring(actual))
  end
end

function PauseControl:isPaused()
  return self.proxy.getOutput(self.config.side) == self.config.pausedOutput
end

function PauseControl:resumePulse()
  self:setPaused(false)
  self.environment.sleep(self.environment.resumePulseSeconds)
  self:setPaused(true)
end

local Gate = {}
Gate.__index = Gate

function Gate.new(proxy)
  return setmetatable({proxy = proxy}, Gate)
end

function Gate:filterCount()
  return self.proxy.getCondensateFilterCount()
end

function Gate:get()
  local values = self.proxy.getCondensateFilters() or {}
  local result = {}
  for slot = 1, self:filterCount() do
    if values[slot] ~= nil then
      result[slot] = values[slot]
    end
  end
  return result
end

function Gate:names()
  local result = {}
  for _, name in pairs(self:get()) do
    result[#result + 1] = name
  end
  table.sort(result)
  return result
end

local function condensateNames(required)
  local names = {}
  for name, amount in pairs(required or {}) do
    local normalizedName = name
    local normalizedAmount = amount
    if type(name) == "number" then
      normalizedName = amount
      normalizedAmount = 1
    end
    if normalizedAmount ~= nil and normalizedAmount ~= false and normalizedAmount ~= 0 then
      names[#names + 1] = normalizedName
    end
  end
  table.sort(names)
  return names
end

function Gate:setExact(required)
  local names = condensateNames(required)
  local count = self:filterCount()
  if #names > count then
    error("Recipe requires " .. #names .. " condensates but Maxwell Gate has " .. count .. " slots")
  end

  local filters = {}
  for slot, name in ipairs(names) do
    filters[slot] = name
  end
  self.proxy.setCondensateFilters(filters)

  local actual = self:names()
  if #actual ~= #names then
    error("Maxwell Gate filter count mismatch; expected " .. #names .. ", got " .. #actual)
  end
  for index, name in ipairs(names) do
    if actual[index] ~= name then
      error("Maxwell Gate filter mismatch; expected " .. util.join(names) .. ", got " .. util.join(actual))
    end
  end
end

function Gate:clear()
  self.proxy.setCondensateFilters({})
  if #self:names() ~= 0 then
    error("Maxwell Gate filters did not clear")
  end
end

local Storage = {}
Storage.__index = Storage

function Storage.new(proxy)
  return setmetatable({proxy = proxy}, Storage)
end

function Storage:status()
  local stored = self.proxy.getStoredCondensate() or {}
  local total = 0
  for _, amount in pairs(stored) do
    total = total + amount
  end
  return {
    fieldStrength = self.proxy.getFieldStrength(),
    stored = stored,
    total = total,
  }
end

local Lock = {}
Lock.__index = Lock

function Lock.new(interfaceProxy, redstoneProxy, config, environment)
  return setmetatable({
    interface = interfaceProxy,
    redstone = redstoneProxy,
    config = config,
    environment = environment,
  }, Lock)
end

function Lock:count()
  local stacks = self.interface.getItemsInNetwork(self.config.item) or {}
  local total = 0
  for _, stack in pairs(stacks) do
    if util.itemMatches(stack, self.config.item) then
      total = total + (stack.size or 0)
    end
  end
  return total
end

function Lock:assertValid()
  local count = self:count()
  if count > 1 then
    error("BEC subnetwork contains " .. count .. " lock items; expected exactly one")
  end
  return count == 1
end

function Lock:waitForAcquire(timeoutSeconds)
  util.waitUntil(self.environment, function()
    local count = self:count()
    if count > 1 then
      error("BEC subnetwork contains " .. count .. " lock items; expected exactly one")
    end
    return count == 1, "lock count is " .. count
  end, timeoutSeconds, "one lock item")
end

function Lock:release()
  if self:count() ~= 1 then
    error("Cannot release lock: expected exactly one lock item")
  end

  self.redstone.setOutput(self.config.releaseSide, self.config.releaseActiveOutput)
  self.environment.sleep(self.config.releasePulseSeconds)
  self.redstone.setOutput(self.config.releaseSide, self.config.releaseIdleOutput)
  local actual = self.redstone.getOutput(self.config.releaseSide)
  if actual ~= self.config.releaseIdleOutput then
    error("Lock release redstone output did not return idle; actual " .. tostring(actual))
  end

  util.waitUntil(self.environment, function()
    local count = self:count()
    return count == 0, "lock count is " .. count
  end, self.environment.operationTimeoutSeconds, "lock item removal")
end

local ItemBridge = {}
ItemBridge.__index = ItemBridge

function ItemBridge.new(warehouse, exportBus, importBus, transposer, config, environment)
  return setmetatable({
    warehouse = warehouse,
    exportBus = exportBus,
    importBus = importBus,
    transposer = transposer,
    config = config,
    environment = environment,
  }, ItemBridge)
end

function ItemBridge:bufferStack()
  local stack = self.transposer.getStackInSlot(self.config.bufferSide, self.config.bufferSlot)
  if util.isEmptyStack(stack) then
    return nil
  end
  return stack
end

function ItemBridge:targetStack()
  local stack = self.transposer.getStackInSlot(self.config.targetSide, self.config.targetSlot)
  if util.isEmptyStack(stack) then
    return nil
  end
  return stack
end

function ItemBridge:targetCount()
  local stack = self:targetStack()
  return stack and (stack.size or 0) or 0
end

function ItemBridge:clearExport()
  self.exportBus.setExportConfiguration(
    self.config.exportPartSide,
    self.config.exportFilterSlot
  )
  local configured = self.exportBus.getExportConfiguration(
    self.config.exportPartSide,
    self.config.exportFilterSlot
  )
  if not util.isEmptyStack(configured) then
    error("ME export bus filter did not clear: " .. util.describe(configured))
  end
end

function ItemBridge:clearImport()
  self.importBus.setImportConfiguration(
    self.config.importPartSide,
    self.config.importFilterSlot
  )
  local configured = self.importBus.getImportConfiguration(
    self.config.importPartSide,
    self.config.importFilterSlot
  )
  if not util.isEmptyStack(configured) then
    error("ME import bus filter did not clear: " .. util.describe(configured))
  end
end

function ItemBridge:setExport(detail)
  self.exportBus.setExportConfiguration(
    self.config.exportPartSide,
    self.config.exportFilterSlot,
    detail
  )
  local configured = self.exportBus.getExportConfiguration(
    self.config.exportPartSide,
    self.config.exportFilterSlot
  )
  if configured == nil or not util.itemMatches(configured, detail) then
    error("ME export bus filter verification failed: " .. util.describe(configured))
  end
end

function ItemBridge:setImport(detail)
  self.importBus.setImportConfiguration(
    self.config.importPartSide,
    self.config.importFilterSlot,
    detail
  )
  local configured = self.importBus.getImportConfiguration(
    self.config.importPartSide,
    self.config.importFilterSlot
  )
  if configured == nil or not util.itemMatches(configured, detail) then
    error("ME import bus filter verification failed: " .. util.describe(configured))
  end
end

function ItemBridge:warehouseStack(filter)
  local stacks = self.warehouse.getItemsInNetwork(filter) or {}
  local matches = {}
  for _, stack in pairs(stacks) do
    if util.itemMatches(stack, filter) then
      matches[#matches + 1] = stack
    end
  end

  if #matches == 0 then
    return nil
  elseif #matches > 1 then
    error("Warehouse filter is ambiguous: " .. util.describe(filter))
  end
  return matches[1]
end

function ItemBridge:waitForBufferEmpty()
  util.waitUntil(self.environment, function()
    local stack = self:bufferStack()
    return stack == nil, stack and util.describe(stack) or nil
  end, self.environment.operationTimeoutSeconds, "transfer buffer to empty")
end

function ItemBridge:drainBuffer()
  local stack = self:bufferStack()
  if stack == nil then
    return
  end

  self:clearExport()
  self:setImport(util.itemIdentity(stack))
  self:waitForBufferEmpty()
  self:clearImport()
end

function ItemBridge:load(filter, count)
  util.requirePositiveInteger(count, "Transfer count")
  self:clearExport()
  self:clearImport()
  self:drainBuffer()

  local existing = self:targetStack()
  if existing ~= nil then
    error("Bridge target is not empty: " .. util.describe(existing))
  end

  local source = self:warehouseStack(filter)
  if source == nil then
    error("Warehouse does not contain " .. util.describe(filter))
  elseif (source.size or 0) < count then
    error("Warehouse has " .. tostring(source.size or 0) .. " items; " .. count .. " required")
  end

  local identity = util.itemIdentity(source)
  self:setExport(identity)

  while self:targetCount() < count do
    self.exportBus.exportIntoSlot(
      self.config.exportPartSide,
      self.config.bufferSlot
    )

    local buffer = util.waitUntil(self.environment, function()
      local stack = self:bufferStack()
      if stack ~= nil then
        return true, stack
      end
      return false, "buffer is empty"
    end, self.environment.operationTimeoutSeconds, "warehouse export")

    if not util.itemMatches(buffer, identity) then
      error("Unexpected item entered transfer buffer: " .. util.describe(buffer))
    end

    local remaining = count - self:targetCount()
    local moved = self.transposer.transferItem(
      self.config.bufferSide,
      self.config.targetSide,
      math.min(remaining, buffer.size or remaining),
      self.config.bufferSlot,
      self.config.targetSlot
    )
    if moved == nil or moved <= 0 then
      error("Transposer failed to move item into bridge target")
    end
  end

  self:clearExport()
  self:drainBuffer()
  self:clearImport()

  local target = self:targetStack()
  if target == nil or not util.itemMatches(target, identity) or (target.size or 0) ~= count then
    error("Bridge target verification failed: " .. util.describe(target))
  end
  return target
end

function ItemBridge:unload()
  self:clearExport()
  self:clearImport()
  self:drainBuffer()

  while self:targetStack() ~= nil do
    local target = self:targetStack()
    self:setImport(util.itemIdentity(target))

    local moved = self.transposer.transferItem(
      self.config.targetSide,
      self.config.bufferSide,
      target.size,
      self.config.targetSlot,
      self.config.bufferSlot
    )
    if moved == nil or moved <= 0 then
      error("Transposer failed to remove item from bridge target")
    end
    self:waitForBufferEmpty()
  end

  self:clearImport()
  if self:targetStack() ~= nil or self:bufferStack() ~= nil then
    error("Bridge did not unload completely")
  end
end

local Nanites = {}
Nanites.__index = Nanites

function Nanites.new(bridge, ioNode, tiers)
  return setmetatable({
    bridge = bridge,
    ioNode = ioNode,
    tiers = tiers,
  }, Nanites)
end

function Nanites:load(tier, count, requireReportedTier)
  local descriptor = self.tiers[tier]
  if descriptor == nil then
    error("No item descriptor configured for nanite tier " .. tostring(tier))
  end

  self.bridge:unload()
  self.bridge:load(descriptor, count)

  local reportedCount = self.ioNode.getAvailableNanites()
  if reportedCount ~= nil and reportedCount > 0 and reportedCount ~= count then
    error("IO Node reports " .. reportedCount .. " nanites; expected " .. count)
  end

  local provided = self.ioNode.getProvidedTier()
  if requireReportedTier and (provided == nil or provided.tier ~= tier) then
    error("IO Node provided tier mismatch: " .. util.describe(provided))
  elseif provided ~= nil and provided.tier ~= tier then
    error("Loaded nanites resolve to unexpected tier: " .. util.describe(provided))
  end
end

function Nanites:unload()
  self.bridge:unload()
  local reportedCount = self.ioNode.getAvailableNanites()
  if reportedCount ~= nil and reportedCount > 0 then
    error("IO Node still reports " .. reportedCount .. " nanites after unload")
  end
end

function Nanites:status()
  return {
    target = self.bridge:targetStack(),
    buffer = self.bridge:bufferStack(),
    available = self.ioNode.getAvailableNanites(),
    providedTier = self.ioNode.getProvidedTier(),
    requiredTier = self.ioNode.getRequiredTier(),
  }
end

local function buildEnvironment(config)
  local computer = require("computer")
  return {
    pollSeconds = config.timing.pollSeconds,
    operationTimeoutSeconds = config.timing.operationTimeoutSeconds,
    resumePulseSeconds = config.timing.resumePulseSeconds,
    now = computer.uptime,
    sleep = os.sleep,
  }
end

function hardware.build(config)
  local component = require("component")
  local environment = buildEnvironment(config)
  local metadata = {}

  local function resolve(name, methods)
    local proxy, descriptor = resolveComponent(component, name, config.components[name], methods)
    metadata[#metadata + 1] = descriptor
    return proxy
  end

  local ioNode = resolve("ioNode", {
    "getRequiredCondensate", "getConsumedCondensate", "getProvidedTier",
    "getRequiredTier", "getAvailableNanites", "getRecipeSteps", "getState",
    "getMinParallel", "getMaxParallel", "getManualSlowdown",
    "setMinParallel", "setMaxParallel", "setSpeedDivisor",
  })
  local gateProxy = resolve("gate", {
    "getCondensateFilterCount", "getCondensateFilters", "setCondensateFilters",
  })
  local storageProxy = resolve("storage", {
    "getFieldStrength", "setFieldStrength", "getStoredCondensate",
  })
  local warehouse = resolve("warehouseInterface", {
    "getItemsInNetwork",
  })
  local exportBus = resolve("exportBus", {
    "getExportConfiguration", "setExportConfiguration", "exportIntoSlot",
  })
  local importBus = resolve("importBus", {
    "getImportConfiguration", "setImportConfiguration",
  })
  local transposer = resolve("bridgeTransposer", {
    "getStackInSlot", "transferItem",
  })
  local lockInterface = resolve("lockInterface", {
    "getItemsInNetwork",
  })
  local redstone = resolve("redstone", {
    "getOutput", "setOutput",
  })

  if config.ioControl.side == config.lock.releaseSide then
    error("Pause and lock-release redstone outputs must use different sides")
  end

  local bridge = ItemBridge.new(
    warehouse,
    exportBus,
    importBus,
    transposer,
    config.bridge,
    environment
  )

  return {
    environment = environment,
    metadata = metadata,
    io = ioNode,
    gate = Gate.new(gateProxy),
    storage = Storage.new(storageProxy),
    pause = PauseControl.new(redstone, config.ioControl, environment),
    lock = Lock.new(lockInterface, redstone, config.lock, environment),
    bridge = bridge,
    nanites = Nanites.new(bridge, ioNode, config.nanites),
  }
end

function hardware.discover(config)
  local component = require("component")
  local discovered = {}
  local seenTypes = {}

  for _, spec in pairs(config.components or {}) do
    if type(spec) == "table" and type(spec.type) == "string" and not seenTypes[spec.type] then
      seenTypes[spec.type] = true
      for address, componentType in component.list(spec.type) do
        discovered[#discovered + 1] = {
          type = componentType,
          address = address,
        }
      end
    end
  end

  table.sort(discovered, function(left, right)
    if left.type == right.type then
      return left.address < right.address
    end
    return left.type < right.type
  end)
  return discovered
end

return hardware
