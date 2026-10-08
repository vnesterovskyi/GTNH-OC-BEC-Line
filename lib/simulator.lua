local util = require("lib.util")

local simulator = {}

local function newJournal()
  return {
    data = nil,
    save = function(self, data)
      self.data = util.copy(data)
    end,
    load = function(self)
      return util.copy(self.data)
    end,
    clear = function(self)
      self.data = nil
    end,
  }
end

function simulator.build(options)
  options = options or {}
  local clock = 0
  local lockCount = options.lockCount or 1
  local paused = true
  local filters = {"water"}
  local naniteStack = nil
  local providedTier = nil
  local loadedTier = nil
  local stepIndex = 1
  local steps = options.steps or {1, 2, 1}
  local state = options.state or "paused-step"
  local requiredCondensate = options.requiredCondensate or {
    neutronium = 144,
    infinity = 144,
  }

  local environment = {
    pollSeconds = 0.01,
    operationTimeoutSeconds = 1,
    resumePulseSeconds = 0.01,
    now = function() return clock end,
    sleep = function(seconds) clock = clock + seconds end,
  }

  local ioNode = {}
  function ioNode.getRequiredCondensate()
    if state == "idle" then
      return nil
    end
    return util.copy(requiredCondensate)
  end
  function ioNode.getConsumedCondensate()
    return {}
  end
  function ioNode.getProvidedTier()
    return providedTier and {name = "T" .. providedTier, tier = providedTier} or nil
  end
  function ioNode.getRequiredTier()
    if state == "idle" then
      return nil
    end
    local tier = steps[stepIndex]
    return tier and {name = "T" .. tier, tier = tier} or nil
  end
  function ioNode.getAvailableNanites()
    return naniteStack and naniteStack.size or 0
  end
  function ioNode.getRecipeSteps()
    local result = {}
    for index, tier in ipairs(steps) do
      result[index] = {
        nanite = {name = "T" .. tier, tier = tier},
        start = index - 1,
        ["end"] = index,
        index = index,
      }
    end
    return result
  end
  function ioNode.getState()
    return state
  end
  function ioNode.getMinParallel() return 1 end
  function ioNode.getMaxParallel() return 1 end
  function ioNode.getManualSlowdown() return 1 end
  function ioNode.setMinParallel() end
  function ioNode.setMaxParallel() end
  function ioNode.setSpeedDivisor() end

  local gate = {}
  function gate:names()
    local result = {}
    for _, name in ipairs(filters) do result[#result + 1] = name end
    return result
  end
  function gate:setExact(required)
    if options.failGate then
      error("simulated gate failure")
    end
    filters = util.sortedKeys(required)
  end
  function gate:clear()
    filters = {"water"}
  end
  function gate:isBlocked()
    return #filters == 1 and filters[1] == "water"
  end

  local nanites = {}
  function nanites:setLoadedTier(tier)
    loadedTier = tier
  end
  function nanites:hasActiveCell()
    return naniteStack ~= nil
  end
  function nanites:load(tier, count)
    if naniteStack ~= nil then
      self:unload(loadedTier)
    end
    naniteStack = {name = "sim:nanite", damage = tier, label = "Tier " .. tier .. " Nanites", size = count}
    providedTier = tier
    loadedTier = tier
  end
  function nanites:unload()
    naniteStack = nil
    providedTier = nil
    loadedTier = nil
  end
  function nanites:status()
    local tiers = {}
    for tier = 1, 10 do
      tiers[tier] = {
        slot = tier,
        state = loadedTier == tier and "empty" or "home",
      }
    end
    return {
      tiers = tiers,
      available = ioNode.getAvailableNanites(),
      providedTier = ioNode.getProvidedTier(),
      requiredTier = ioNode.getRequiredTier(),
      loadedTier = loadedTier,
    }
  end

  local pause = {}
  function pause:setPaused(value)
    paused = value
  end
  function pause:isPaused() return paused end
  function pause:resumePulse()
    paused = false
    environment.sleep(environment.resumePulseSeconds)
    stepIndex = stepIndex + 1
    if stepIndex > #steps then
      state = "idle"
    else
      state = "paused-step"
    end
    paused = true
  end

  local lock = {}
  function lock:count() return lockCount end
  function lock:assertValid()
    if lockCount > 1 then error("invalid simulated lock count") end
    return lockCount == 1
  end
  function lock:waitForAcquire()
    if lockCount ~= 1 then error("simulated lock is absent") end
  end
  function lock:release()
    if lockCount ~= 1 then error("simulated lock release failed") end
    lockCount = 0
  end

  local storage = {}
  function storage:status()
    return {fieldStrength = 1000000, stored = util.copy(requiredCondensate), total = 288}
  end

  local result = {
    environment = environment,
    io = ioNode,
    gate = gate,
    nanites = nanites,
    pause = pause,
    lock = lock,
    storage = storage,
    metadata = {},
    journal = newJournal(),
  }

  function result.snapshot()
    return {
      state = state,
      lockCount = lockCount,
      paused = paused,
      filters = util.copy(filters),
      naniteStack = util.copy(naniteStack),
      providedTier = providedTier,
      loadedTier = loadedTier,
      stepIndex = stepIndex,
    }
  end

  return result
end

return simulator
