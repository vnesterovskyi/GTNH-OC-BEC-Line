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

function Gate.new(proxy, config)
  return setmetatable({
    proxy = proxy,
    blockingFluid = config and config.blockingFluid or "water",
  }, Gate)
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
  self.proxy.setCondensateFilters({[1] = self.blockingFluid})
  local names = self:names()
  if #names ~= 1 or names[1] ~= self.blockingFluid then
    error("Maxwell Gate blocking filter did not apply")
  end
end

function Gate:isBlocked()
  local names = self:names()
  return #names == 1 and names[1] == self.blockingFluid
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

function Lock.new(transposer, config, environment)
  return setmetatable({
    transposer = transposer,
    config = config,
    environment = environment,
  }, Lock)
end

function Lock:contents()
  local total = 0
  local sources = {}
  for _, slot in ipairs(self.config.chestSlots) do
    local stack = self.transposer.getStackInSlot(self.config.chestSide, slot)
    if not util.isEmptyStack(stack) then
      if not util.itemMatches(stack, self.config.item) then
        error("Lock chest slot " .. slot
          .. " contains unexpected item " .. tostring(stack.label))
      end
      local count = stack.size or 0
      total = total + count
      sources[#sources + 1] = {slot = slot, count = count}
    end
  end
  if total > self.config.maxTokens then
    error("Lock chest contains " .. total .. " tokens; maximum is " .. self.config.maxTokens)
  end
  return total, sources
end

function Lock:count()
  return self:contents()
end

function Lock:assertValid()
  local count = self:count()
  return count >= 1
end

function Lock:waitForAcquire(timeoutSeconds)
  util.waitUntil(self.environment, function()
    local count = self:count()
    return count >= 1, "lock count is " .. count
  end, timeoutSeconds, "one or more lock items")
end

function Lock:release()
  local count, sources = self:contents()
  if count == 0 then
    return false
  end

  for _, source in ipairs(sources) do
    local moved, reason = self.transposer.transferItem(
      self.config.chestSide,
      self.config.trashSide,
      source.count,
      source.slot
    )
    if moved ~= source.count then
      error("Lock Transposer moved " .. tostring(moved)
        .. " of " .. source.count .. " tokens: " .. tostring(reason))
    end
  end

  util.waitUntil(self.environment, function()
    local count = self:count()
    return count == 0, "lock count is " .. count
  end, self.environment.operationTimeoutSeconds, "lock item removal")
  return true
end

local CellCarousel = {}
CellCarousel.__index = CellCarousel

function CellCarousel.new(transposer, ioNode, config, environment)
  return setmetatable({
    transposer = transposer,
    ioNode = ioNode,
    config = config,
    environment = environment,
  }, CellCarousel)
end

function CellCarousel:isStorageCell(stack)
  if util.isEmptyStack(stack) then
    return false
  end
  local label = stack.label or ""
  return label:find(self.config.cellLabelContains, 1, true) ~= nil
end

function CellCarousel:stack(side, slot)
  local stack = self.transposer.getStackInSlot(side, slot)
  if util.isEmptyStack(stack) then
    return nil
  end
  return stack
end

function CellCarousel:findCell(side)
  local size = self.transposer.getInventorySize(side)
  local foundSlot = nil
  local foundStack = nil

  for slot = 1, size do
    local stack = self:stack(side, slot)
    if stack ~= nil and self:isStorageCell(stack) then
      if foundSlot ~= nil then
        error("Multiple storage cells found on Transposer side " .. side)
      end
      foundSlot = slot
      foundStack = stack
    end
  end
  return foundSlot, foundStack
end

function CellCarousel:homeCell(tier)
  local slot = self.config.tierSlots[tier]
  if slot == nil then
    return nil, nil
  end
  local stack = self:stack(self.config.chestSide, slot)
  if stack ~= nil and not self:isStorageCell(stack) then
    error("Tier " .. tier .. " chest slot " .. slot .. " contains " .. tostring(stack.label))
  end
  return slot, stack
end

function CellCarousel:moveCell(fromSide, toSide, sourceSlot, sinkSlot)
  local moved, reason
  if sinkSlot ~= nil then
    moved, reason = self.transposer.transferItem(
      fromSide,
      toSide,
      1,
      sourceSlot,
      sinkSlot
    )
  else
    moved, reason = self.transposer.transferItem(
      fromSide,
      toSide,
      1,
      sourceSlot
    )
  end
  if moved ~= 1 then
    error("Storage cell transfer failed: " .. tostring(reason))
  end
end

function CellCarousel:waitForNanites(expected, allowOvershoot)
  util.waitUntil(self.environment, function()
    local actual = self.ioNode.getAvailableNanites()
    local ready = allowOvershoot and actual >= expected or actual == expected
    return ready, "IO Node reports " .. tostring(actual)
  end, self.environment.naniteTransferTimeoutSeconds,
    (allowOvershoot and "at least " or "") .. expected .. " available nanites")
end

function CellCarousel:hasActiveCell()
  local loadSlot = self:findCell(self.config.loadPortSide)
  local unloadSlot = self:findCell(self.config.unloadPortSide)
  return loadSlot ~= nil or unloadSlot ~= nil or self.ioNode.getAvailableNanites() > 0
end

function CellCarousel:load(tier, count)
  util.requirePositiveInteger(tier, "Nanite tier")
  util.requirePositiveInteger(count, "Nanite count")

  local loadSlot = self:findCell(self.config.loadPortSide)
  local unloadSlot = self:findCell(self.config.unloadPortSide)
  if loadSlot ~= nil or unloadSlot ~= nil or self.ioNode.getAvailableNanites() > 0 then
    error("Cannot load tier " .. tier .. ": a storage cell or nanites are already active")
  end

  local chestSlot, cell = self:homeCell(tier)
  if chestSlot == nil then
    error("No chest slot configured for nanite tier " .. tier)
  elseif cell == nil then
    error("Nanite tier " .. tier .. " cell slot " .. chestSlot .. " is empty")
  end

  self:moveCell(self.config.chestSide, self.config.loadPortSide, chestSlot)
  self:waitForNanites(count, true)

  if self:findCell(self.config.loadPortSide) == nil then
    error("Tier " .. tier .. " cell disappeared from the load IO Port")
  end
end

function CellCarousel:unload(tier)
  util.requirePositiveInteger(tier, "Nanite tier")
  local chestSlot, homeCell = self:homeCell(tier)
  if chestSlot == nil then
    error("No chest slot configured for nanite tier " .. tier)
  end

  local loadSlot = self:findCell(self.config.loadPortSide)
  local unloadSlot = self:findCell(self.config.unloadPortSide)
  if loadSlot ~= nil and unloadSlot ~= nil then
    error("Storage cells are present in both IO Ports")
  end

  if loadSlot ~= nil then
    if homeCell ~= nil then
      error("Tier " .. tier .. " home slot is occupied while its cell is active")
    end
    self:moveCell(
      self.config.loadPortSide,
      self.config.unloadPortSide,
      loadSlot
    )
  elseif unloadSlot == nil then
    if self.ioNode.getAvailableNanites() == 0 and homeCell ~= nil then
      return
    end
    error("Cannot locate the active tier " .. tier .. " storage cell")
  end

  self:waitForNanites(0, false)
  unloadSlot = self:findCell(self.config.unloadPortSide)
  if unloadSlot == nil then
    error("Tier " .. tier .. " cell disappeared from the unload IO Port")
  end
  if self:stack(self.config.chestSide, chestSlot) ~= nil then
    error("Tier " .. tier .. " home slot " .. chestSlot .. " is occupied")
  end

  self:moveCell(
    self.config.unloadPortSide,
    self.config.chestSide,
    unloadSlot,
    chestSlot
  )
  local _, returnedCell = self:homeCell(tier)
  if returnedCell == nil then
    error("Tier " .. tier .. " cell did not return to chest slot " .. chestSlot)
  end
end

function CellCarousel:status()
  local tiers = {}
  for tier = 1, 10 do
    local slot, cell = self:homeCell(tier)
    tiers[tier] = {
      slot = slot,
      state = cell and "home" or "empty",
      label = cell and cell.label or nil,
    }
  end
  local loadSlot, loadCell = self:findCell(self.config.loadPortSide)
  local unloadSlot, unloadCell = self:findCell(self.config.unloadPortSide)
  return {
    tiers = tiers,
    loadPort = loadCell and {slot = loadSlot, label = loadCell.label} or nil,
    unloadPort = unloadCell and {slot = unloadSlot, label = unloadCell.label} or nil,
    available = self.ioNode.getAvailableNanites(),
    providedTier = self.ioNode.getProvidedTier(),
    requiredTier = self.ioNode.getRequiredTier(),
  }
end

local Nanites = {}
Nanites.__index = Nanites

function Nanites.new(carousel, ioNode)
  return setmetatable({
    carousel = carousel,
    ioNode = ioNode,
    loadedTier = nil,
  }, Nanites)
end

function Nanites:setLoadedTier(tier)
  self.loadedTier = tier
end

function Nanites:hasActiveCell()
  return self.carousel:hasActiveCell()
end

function Nanites:load(tier, count, requireReportedTier)
  if self:hasActiveCell() then
    self:unload(self.loadedTier)
  end

  self.loadedTier = tier
  self.carousel:load(tier, count)

  local provided = self.ioNode.getProvidedTier()
  if requireReportedTier and (provided == nil or provided.tier ~= tier) then
    error("IO Node provided tier mismatch: " .. util.describe(provided))
  elseif provided ~= nil and provided.tier ~= tier then
    error("Loaded nanites resolve to unexpected tier: " .. util.describe(provided))
  end
end

function Nanites:unload(tier)
  if not self:hasActiveCell() then
    self.loadedTier = nil
    return
  end

  tier = tier or self.loadedTier
  local provided = self.ioNode.getProvidedTier()
  tier = tier or (provided and provided.tier or nil)
  if tier == nil then
    error("Active storage cell tier is unknown; preserve it and supply the tier manually")
  end

  self.carousel:unload(tier)
  self.loadedTier = nil
end

function Nanites:status()
  local status = self.carousel:status()
  status.loadedTier = self.loadedTier
  return status
end

local function buildEnvironment(config)
  local computer = require("computer")
  return {
    pollSeconds = config.timing.pollSeconds,
    operationTimeoutSeconds = config.timing.operationTimeoutSeconds,
    naniteTransferTimeoutSeconds = config.timing.naniteTransferTimeoutSeconds,
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
  local transposer = resolve("cellTransposer", {
    "getInventorySize", "getStackInSlot", "transferItem",
  })
  local lockTransposer = resolve("lockTransposer", {
    "getInventorySize", "getStackInSlot", "transferItem",
  })
  local redstone = resolve("redstone", {
    "getOutput", "setOutput",
  })

  local carousel = CellCarousel.new(
    transposer,
    ioNode,
    config.cellCarousel,
    environment
  )

  return {
    environment = environment,
    metadata = metadata,
    io = ioNode,
    gate = Gate.new(gateProxy, config.gateControl),
    storage = Storage.new(storageProxy),
    pause = PauseControl.new(redstone, config.ioControl, environment),
    lock = Lock.new(lockTransposer, config.lock, environment),
    carousel = carousel,
    nanites = Nanites.new(carousel, ioNode),
  }
end

function hardware.buildLock(config, includeIoNode)
  local component = require("component")
  local environment = buildEnvironment(config)
  local lockProxy, lockDescriptor = resolveComponent(
    component,
    "lockTransposer",
    config.components.lockTransposer,
    {"getInventorySize", "getStackInSlot", "transferItem"}
  )
  local result = {
    environment = environment,
    metadata = {lockDescriptor},
    lock = Lock.new(lockProxy, config.lock, environment),
  }

  if includeIoNode then
    local ioNode, ioDescriptor = resolveComponent(
      component,
      "ioNode",
      config.components.ioNode,
      {"getState"}
    )
    result.io = ioNode
    result.metadata[#result.metadata + 1] = ioDescriptor
  end
  return result
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
