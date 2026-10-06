local component = require("component")
local filesystem = require("filesystem")
local internet = require("internet")
local shell = require("shell")

local repository = "vnesterovskyi/GTNH-OC-BEC-Line"
local revision = "main"
local baseUrl = "https://raw.githubusercontent.com/" .. repository .. "/" .. revision .. "/"

local files = {
  "becctl.lua",
  "config.example.lua",
  "lib/cli.lua",
  "lib/controller.lua",
  "lib/hardware.lua",
  "lib/journal.lua",
  "lib/simulator.lua",
  "lib/util.lua",
  "tests/selftest.lua",
}

if not component.isAvailable("internet") then
  error("An Internet Card is required for installation")
end

local function ensureParent(path)
  local parent = filesystem.path(path)
  if parent and parent ~= "" and not filesystem.exists(parent) then
    local created, createError = filesystem.makeDirectory(parent)
    if not created then
      error("Unable to create " .. parent .. ": " .. tostring(createError))
    end
  end
end

local function download(path)
  io.write("Downloading " .. path .. "... ")
  local request, requestError = internet.request(baseUrl .. path)
  if request == nil then
    error("Unable to request " .. path .. ": " .. tostring(requestError))
  end

  local chunks = {}
  for chunk in request do
    chunks[#chunks + 1] = chunk
  end

  local destinationPath = shell.resolve(path)
  ensureParent(destinationPath)
  local temporaryPath = destinationPath .. ".tmp"
  local file, openError = io.open(temporaryPath, "wb")
  if not file then
    error("Unable to write " .. temporaryPath .. ": " .. tostring(openError))
  end
  file:write(table.concat(chunks))
  file:close()

  if filesystem.exists(destinationPath) then
    local removed, removeError = filesystem.remove(destinationPath)
    if not removed then
      error("Unable to replace " .. path .. ": " .. tostring(removeError))
    end
  end

  local _, renameError = filesystem.rename(temporaryPath, destinationPath)
  if not filesystem.exists(destinationPath) or filesystem.exists(temporaryPath) then
    error("Unable to publish " .. path .. ": " .. tostring(renameError))
  end
  print("ok")
end

for _, path in ipairs(files) do
  download(path)
end

local configPath = shell.resolve("config.lua")
local exampleConfigPath = shell.resolve("config.example.lua")
if not filesystem.exists(configPath) then
  local source, sourceError = io.open(exampleConfigPath, "rb")
  if not source then
    error("Unable to open config.example.lua: " .. tostring(sourceError))
  end
  local content = source:read("*a")
  source:close()

  local target, targetError = io.open(configPath, "wb")
  if not target then
    error("Unable to create config.lua: " .. tostring(targetError))
  end
  target:write(content)
  target:close()
  print("Created config.lua")
else
  print("Preserved existing config.lua")
end

print("Installation complete. Run: becctl selftest")
