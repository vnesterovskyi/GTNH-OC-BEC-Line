local util = require("lib.util")
local hardwareFactory = require("lib.hardware")
local controllerClass = require("lib.controller")
local computer = require("computer")

local cli = {}

local function usage()
  print([[
Usage:
  becctl [--config=path] probe
  becctl [--config=path] status
  becctl [--config=path] lock status|acquire|release [--force]
  becctl [--config=path] gate show|set <fluid...>|clear [--force]
  becctl [--config=path] nanite status|load <tier> [minimum]|unload <tier>
  becctl [--config=path] cycle --simulate|--step|--automatic|--daemon
]])
end

local function contains(args, expected)
  for _, value in ipairs(args) do
    if value == expected then
      return true
    end
  end
  return false
end

local function confirm(description)
  io.write(description .. " [y/N]: ")
  local answer = io.read()
  return answer ~= nil and answer:lower() == "y"
end

local function printMap(name, value)
  print(name .. ": " .. util.describe(value))
end

local function timestamp()
  local seconds = math.floor(computer.uptime())
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  return string.format("%02d:%02d:%02d", hours, minutes, seconds % 60)
end

local function log(message)
  print("[" .. timestamp() .. "] " .. message)
end

local function tierText(tier)
  if tier == nil then return "none" end
  return "T" .. tostring(tier.tier) .. " " .. tostring(tier.name)
end

local function printCarousel(status)
  local cells = {}
  for tier = 1, 10 do
    local cell = status.tiers[tier]
    cells[#cells + 1] = "T" .. tier .. "=" .. cell.state
  end
  print("Nanite cells: " .. table.concat(cells, "  "))
  print("Nanites available: " .. tostring(status.available))
  print("Provided tier: " .. tierText(status.providedTier))
  print("Required tier: " .. tierText(status.requiredTier))
  print("Loaded tier: " .. (status.loadedTier and ("T" .. status.loadedTier) or "none"))
  print("Load IO Port: " .. (status.loadPort and status.loadPort.label or "empty"))
  print("Unload IO Port: " .. (status.unloadPort and status.unloadPort.label or "empty"))
end

local function safeToMutateIdle(ioNode, force)
  local state = ioNode.getState()
  if state ~= "idle" and not force then
    error("IO Node is " .. tostring(state) .. "; use --force only after understanding the active recipe")
  end
end

local function probe(config)
  print("Visible candidate components:")
  for _, descriptor in ipairs(hardwareFactory.discover(config)) do
    print("  " .. descriptor.type .. "@" .. descriptor.address)
  end
  print("")

  local hardware = hardwareFactory.build(config)
  print("Resolved components:")
  for _, descriptor in ipairs(hardware.metadata) do
    print("  " .. descriptor.name .. " = " .. descriptor.type .. "@" .. descriptor.address)
  end

  print("\nNanite cell chest:")
  local status = hardware.nanites:status()
  for tier = 1, 10 do
    local cell = status.tiers[tier]
    print("  T" .. tier .. " slot " .. tostring(cell.slot) .. ": " .. cell.state)
  end
end

local function status(config)
  local hardware = hardwareFactory.build(config)
  local storage = hardware.storage:status()
  print("IO state: " .. tostring(hardware.io.getState()))
  printMap("Required condensate", hardware.io.getRequiredCondensate())
  printMap("Consumed condensate", hardware.io.getConsumedCondensate())
  print("Required tier: " .. tierText(hardware.io.getRequiredTier()))
  print("Provided tier: " .. tierText(hardware.io.getProvidedTier()))
  print("Gate filters: " .. util.join(hardware.gate:names()))
  print("Storage: " .. storage.total .. " / " .. storage.fieldStrength .. " L")
  for _, fluid in ipairs(util.sortedKeys(storage.stored)) do
    print("  " .. fluid .. ": " .. storage.stored[fluid] .. " L")
  end
  print("Lock count: " .. hardware.lock:count())
  printCarousel(hardware.nanites:status())
  print("Pause asserted: " .. tostring(hardware.pause:isPaused()))
end

local function runLock(config, args)
  local action = args[2]
  local hardware = hardwareFactory.buildLock(config, action == "release")
  if action == "status" then
    print("Lock count: " .. hardware.lock:count())
  elseif action == "acquire" then
    hardware.lock:waitForAcquire(config.timing.stagingTimeoutSeconds)
    print("Lock acquired")
  elseif action == "release" then
    safeToMutateIdle(hardware.io, contains(args, "--force"))
    local released = hardware.lock:release()
    print(released and "Lock released" or "Lock already clear")
  else
    error("Expected: lock status|acquire|release")
  end
end

local function runGate(config, args)
  local hardware = hardwareFactory.build(config)
  local action = args[2]
  if action == "show" then
    printMap("Gate filters", hardware.gate:get())
  elseif action == "set" then
    local fluids = {}
    for index = 3, #args do
      if args[index] ~= "--force" then
        fluids[#fluids + 1] = args[index]
      end
    end
    if #fluids == 0 then
      error("At least one fluid name is required")
    end
    safeToMutateIdle(hardware.io, contains(args, "--force"))
    hardware.gate:setExact(fluids)
    printMap("Gate filters", hardware.gate:get())
  elseif action == "clear" then
    safeToMutateIdle(hardware.io, contains(args, "--force"))
    hardware.gate:clear()
    print("Gate water barrier restored")
  else
    error("Expected: gate show|set|clear")
  end
end

local function runNanite(config, args)
  local hardware = hardwareFactory.build(config)
  local action = args[2]
  if action == "status" then
    printCarousel(hardware.nanites:status())
  elseif action == "load" then
    local state = hardware.io.getState()
    if state == "crafting" then
      error("Refusing nanite load while IO Node is crafting")
    end
    hardware.pause:setPaused(true)
    local tier = util.requirePositiveInteger(tonumber(args[3]), "Nanite tier")
    if tier > 10 then error("Nanite tier must be between 1 and 10") end
    local count = tonumber(args[4]) or config.cycle.naniteCount
    hardware.nanites:load(tier, count, false)
    printCarousel(hardware.nanites:status())
  elseif action == "unload" then
    hardware.pause:setPaused(true)
    local tier = util.requirePositiveInteger(tonumber(args[3]), "Nanite tier")
    if tier > 10 then error("Nanite tier must be between 1 and 10") end
    hardware.nanites:setLoadedTier(tier)
    hardware.nanites:unload(tier)
    print("Tier-" .. tier .. " cell returned home")
  else
    error("Expected: nanite status|load <tier> [minimum]|unload <tier>")
  end
end

local function runCycle(config, args)
  local simulate = contains(args, "--simulate")
  local automatic = contains(args, "--automatic")
  local step = contains(args, "--step")
  local daemon = contains(args, "--daemon")
  local modeCount = (simulate and 1 or 0)
    + (automatic and 1 or 0)
    + (step and 1 or 0)
    + (daemon and 1 or 0)
  if modeCount ~= 1 then
    error("Choose exactly one of --simulate, --step, --automatic, or --daemon")
  end

  if simulate then
    local simulator = require("lib.simulator")
    local simulated = simulator.build()
    local instance = controllerClass.new(simulated, config, {
      journal = simulated.journal,
      log = log,
    })
    instance:run()
    return
  end

  local journalClass = require("lib.journal")
  local hardware = hardwareFactory.build(config)
  local journal = journalClass.new(config.cycle.journalPath)

  local function runOne(lockTimeoutSeconds)
    controllerClass.new(hardware, config, {
      journal = journal,
      stepMode = step,
      confirm = confirm,
      lockTimeoutSeconds = lockTimeoutSeconds,
      log = log,
    }):run()
  end

  if daemon then
    local batch = 1
    log("[DAEMON] online; faults stop the process")
    while true do
      log("[DAEMON] waiting for batch #" .. batch)
      runOne(math.huge)
      log("[DAEMON] batch #" .. batch .. " complete; safe idle")
      batch = batch + 1
    end
  else
    runOne(config.timing.stagingTimeoutSeconds)
  end
end

function cli.run(config, args)
  local command = args[1]
  if command == nil or command == "help" or command == "--help" then
    usage()
  elseif command == "probe" then
    probe(config)
  elseif command == "status" then
    status(config)
  elseif command == "lock" then
    runLock(config, args)
  elseif command == "gate" then
    runGate(config, args)
  elseif command == "nanite" then
    runNanite(config, args)
  elseif command == "cycle" then
    runCycle(config, args)
  else
    usage()
    error("Unknown command: " .. tostring(command))
  end
end

return cli
