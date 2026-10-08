local util = require("lib.util")

local controller = {}
controller.__index = controller

local fatalStates = {
  ["unpowered"] = true,
  ["assembler-offline"] = true,
  ["internal-error"] = true,
}

local pausedStates = {
  ["paused-step"] = true,
  ["paused-immediate"] = true,
}

local activeStates = {
  ["crafting"] = true,
  ["paused-step"] = true,
  ["paused-immediate"] = true,
  ["nanite-tier-too-low"] = true,
}

function controller.new(hardware, config, options)
  options = options or {}
  return setmetatable({
    hardware = hardware,
    config = config,
    environment = hardware.environment,
    journal = options.journal,
    stepMode = options.stepMode == true,
    lockTimeoutSeconds = options.lockTimeoutSeconds
      or config.timing.stagingTimeoutSeconds,
    confirm = options.confirm or function() return true end,
    log = options.log or print,
    state = "NEW",
    observedActive = false,
    currentNaniteTier = nil,
  }, controller)
end

function controller:setState(state, detail, persist)
  self.state = state
  self.log("[" .. state .. "]" .. (detail and (" " .. detail) or ""))
  if persist and self.journal then
    self.journal:save({
      state = state,
      detail = detail,
      observedActive = self.observedActive,
      currentNaniteTier = self.currentNaniteTier,
      timestamp = self.environment.now(),
    })
  end
end

function controller:mutation(description, action)
  if self.stepMode and not self.confirm(description) then
    error("Operator declined: " .. description)
  end
  return action()
end

function controller:assertStateUsable(state)
  if fatalStates[state] then
    error("IO Node entered fail-closed state: " .. state)
  end
end

function controller:pause()
  self.hardware.pause:setPaused(true)
end

function controller:failClosed(reason)
  local pauseOk, pauseError = pcall(function()
    self.hardware.pause:setPaused(true)
  end)
  local statusOk, naniteStatus = pcall(function()
    return self.hardware.nanites:status()
  end)
  if statusOk and naniteStatus.loadedTier ~= nil then
    self.currentNaniteTier = naniteStatus.loadedTier
  end

  local detail = tostring(reason)
  if not pauseOk then
    detail = detail .. "; additionally failed to assert pause: " .. tostring(pauseError)
  end

  self.state = "FAULT"
  if self.journal then
    local journalOk, journalError = pcall(function()
      self.journal:save({
        state = "FAULT",
        detail = detail,
        observedActive = self.observedActive,
        currentNaniteTier = self.currentNaniteTier,
        timestamp = self.environment.now(),
      })
    end)
    if not journalOk then
      detail = detail .. "; additionally failed to write journal: " .. tostring(journalError)
    end
  end
  error(detail, 0)
end

function controller:reconcile()
  local previousJournal = self.journal and self.journal:load() or nil
  self.currentNaniteTier = previousJournal and previousJournal.currentNaniteTier or nil
  self.hardware.nanites:setLoadedTier(self.currentNaniteTier)
  self:setState("RECONCILING")
  self:pause()

  local state = self.hardware.io.getState()
  self:assertStateUsable(state)
  local lockCount = self.hardware.lock:count()

  if activeStates[state] and lockCount == 0 then
    error("Active recipe has no lock item; preserving machine in paused state")
  end

  if lockCount >= 1
      and state == "idle"
      and self.hardware.io.getRequiredCondensate() == nil
      and previousJournal ~= nil
      and previousJournal.observedActive == true then
    self.observedActive = true
    self:setState("RECOVERED_COMPLETION", "finishing cleanup after interrupted cycle")
    self:cleanup()
    self.recoveredComplete = true
    return 0
  end

  if lockCount == 0 and state == "idle" then
    if self.hardware.nanites:hasActiveCell() then
      self:mutation("return the residual nanite cell to its chest slot", function()
        self.hardware.nanites:unload(self.currentNaniteTier)
        self.currentNaniteTier = nil
      end)
    end
    if not self.hardware.gate:isBlocked() then
      self:mutation("restore the Maxwell Gate water barrier", function()
        self.hardware.gate:clear()
      end)
    end
  end
  return lockCount
end

function controller:waitForLock()
  self:setState("WAITING_FOR_LOCK", "ready for the next batch")
  local lockCount = self.hardware.lock:waitForAcquire(self.lockTimeoutSeconds)
  self:setState("LOCKED",
    tostring(lockCount) .. " token(s) acquired", true)
end

function controller:waitForStagedRecipe()
  self:setState("STAGED", "waiting for a paused recipe")

  local recipe = util.waitUntil(self.environment, function()
    local state = self.hardware.io.getState()
    self:assertStateUsable(state)

    local requiredCondensate = self.hardware.io.getRequiredCondensate()
    local requiredTier = self.hardware.io.getRequiredTier()
    local safePause = pausedStates[state] or state == "nanite-tier-too-low"

    if state == "crafting" and not safePause then
      error("Recipe began crafting before routing and nanites were prepared")
    end

    if requiredCondensate ~= nil and requiredTier ~= nil and safePause then
      return true, {
        condensate = requiredCondensate,
        tier = requiredTier,
      }
    end

    return false, "state=" .. tostring(state)
      .. ", condensate=" .. util.describe(requiredCondensate)
      .. ", tier=" .. util.describe(requiredTier)
  end, self.config.timing.stagingTimeoutSeconds, "a paused staged recipe")
  local condensates = util.sortedKeys(recipe.condensate)
  self.log("[RECIPE] first nanite tier T" .. recipe.tier.tier
    .. "; condensates: " .. util.join(condensates))
  return recipe
end

function controller:configureRecipe(recipe)
  self:setState("ROUTED", "programming Maxwell Gate")
  self:mutation("program exact condensate filters", function()
    self.hardware.gate:setExact(recipe.condensate)
  end)

  local desired = {
    minParallel = self.config.cycle.minParallel,
    maxParallel = self.config.cycle.maxParallel,
    speedDivisor = self.config.cycle.speedDivisor,
  }
  local applied = self.hardware.ioSettings
  if applied == nil
      or applied.minParallel ~= desired.minParallel
      or applied.maxParallel ~= desired.maxParallel
      or applied.speedDivisor ~= desired.speedDivisor then
    local actualMin = self.hardware.io.getMinParallel()
    if actualMin ~= desired.minParallel then
      self.hardware.io.setMinParallel(desired.minParallel)
      actualMin = self.hardware.io.getMinParallel()
    end
    local actualMax = self.hardware.io.getMaxParallel()
    if actualMax ~= desired.maxParallel then
      self.hardware.io.setMaxParallel(desired.maxParallel)
      actualMax = self.hardware.io.getMaxParallel()
    end
    local actualSpeed = self.hardware.io.getManualSlowdown()
    if actualSpeed ~= desired.speedDivisor then
      self.hardware.io.setSpeedDivisor(desired.speedDivisor)
      actualSpeed = self.hardware.io.getManualSlowdown()
    end

    if actualMin ~= desired.minParallel then
      error("IO Node minimum parallel setting did not apply")
    elseif actualMax ~= desired.maxParallel then
      error("IO Node maximum parallel setting did not apply")
    elseif actualSpeed ~= desired.speedDivisor then
      error("IO Node speed divisor setting did not apply")
    end
    self.hardware.ioSettings = desired
  end

  self:setState("NANITE_READY", "loading tier " .. tostring(recipe.tier.tier))
  self:mutation(
    "load " .. self.config.cycle.naniteCount .. " tier-" .. recipe.tier.tier .. " nanites",
    function()
      self.hardware.nanites:load(
        recipe.tier.tier,
        self.config.cycle.naniteCount,
        true
      )
      self.currentNaniteTier = recipe.tier.tier
      self:setState("NANITE_READY", "tier " .. recipe.tier.tier .. " loaded", true)
    end
  )
end

function controller:swapNanites(requiredTier)
  self:setState("SWAPPING", "tier " .. tostring(requiredTier.tier))
  self:pause()
  self:mutation(
    "replace nanites with tier " .. requiredTier.tier,
    function()
      self.hardware.nanites:load(
        requiredTier.tier,
        self.config.cycle.naniteCount,
        true
      )
      self.currentNaniteTier = requiredTier.tier
      self:setState("SWAPPING", "tier " .. requiredTier.tier .. " loaded", true)
    end
  )
end

function controller:resumeAtBoundary()
  self:mutation("resume IO Node and re-arm step-transition pause", function()
    self.hardware.pause:resumePulse()
  end)
end

function controller:runRecipe(initialTier)
  self.observedActive = true
  self:setState("RUNNING", nil, true)

  local recipeSteps = self.hardware.io.getRecipeSteps() or {}
  local maximumBoundaries = math.max(#recipeSteps + 2, 4)
  local boundaryCount = 0
  local currentTier = initialTier.tier
  local deadline = self.environment.now() + self.config.timing.cycleTimeoutSeconds

  self:resumeAtBoundary()

  while self.environment.now() <= deadline do
    local state = self.hardware.io.getState()
    self:assertStateUsable(state)

    if state == "idle" then
      local stableChecks = self.config.timing.completionStableChecks or 2
      util.requirePositiveInteger(stableChecks, "Completion stable checks")
      for _ = 2, stableChecks do
        local current = self.hardware.io.getState()
        self:assertStateUsable(current)
        if current ~= "idle" then
          error("IO Node left idle during completion confirmation: " .. tostring(current))
        end
      end
      return
    end

    if state == "crafting" then
      self.observedActive = true
      if self.environment.afterObservation then
        self.environment.afterObservation()
      end
    elseif pausedStates[state] or state == "nanite-tier-too-low" then
      self.observedActive = true
      boundaryCount = boundaryCount + 1
      if boundaryCount > maximumBoundaries then
        error("Observed more pause boundaries than recipe steps; check Controller Hatch mode")
      end

      local requiredTier = self.hardware.io.getRequiredTier()
      if requiredTier == nil then
        error("Paused recipe does not report a required nanite tier")
      end

      local ready = requiredTier.tier == currentTier
      if ready then
        ready = self.hardware.nanites:isReady(
          requiredTier.tier,
          self.config.cycle.naniteCount
        )
      end
      if not ready then
        self:swapNanites(requiredTier)
        currentTier = requiredTier.tier
      end

      self:setState("RUNNING")
      self:resumeAtBoundary()
    else
      error("Unexpected IO Node state while running: " .. tostring(state))
    end
  end

  error("Cycle exceeded timeout of " .. self.config.timing.cycleTimeoutSeconds .. " seconds")
end

function controller:cleanup()
  self:setState("COMPLETED", nil, true)
  self:pause()

  self:setState("CLEANING", "returning nanites", true)
  self:mutation("return the active nanite cell to its chest slot", function()
    self.hardware.nanites:unload(self.currentNaniteTier)
    self.currentNaniteTier = nil
  end)

  self:mutation("restore the Maxwell Gate water barrier", function()
    self.hardware.gate:clear()
  end)

  self:mutation("release the AE2 lock item", function()
    self.hardware.lock:release()
  end)

  self.state = "IDLE"
  self.log("[IDLE] cycle complete")
  if self.journal then
    self.journal:clear()
  end
end

function controller:runInternal()
  local lockCount = self:reconcile()
  if self.recoveredComplete then
    return
  end

  if lockCount == 0 then
    self:waitForLock()
  else
    self:setState("LOCKED",
      tostring(lockCount) .. " existing token(s) recovered", true)
  end

  local recipe = self:waitForStagedRecipe()
  self:configureRecipe(recipe)
  self:runRecipe(recipe.tier)
  self:cleanup()
end

function controller:run()
  local success, failure = xpcall(function()
    self:runInternal()
  end, debug.traceback)

  if not success then
    self:failClosed(failure)
  end
end

return controller
