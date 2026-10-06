local shell = require("shell")
local programPath = shell.getRunningProgram()
local programDirectory = programPath:match("^(.*[/\\])") or "./"
package.path = programDirectory .. "?.lua;"
  .. programDirectory .. "?/init.lua;"
  .. package.path

local args = {...}

local function removeOption(name)
  for index = #args, 1, -1 do
    local value = args[index]
    local prefix = name .. "="
    if value == name then
      local optionValue = args[index + 1]
      if optionValue == nil then
        error(name .. " requires a value")
      end
      table.remove(args, index + 1)
      table.remove(args, index)
      return optionValue
    elseif value:sub(1, #prefix) == prefix then
      table.remove(args, index)
      return value:sub(#prefix + 1)
    end
  end
  return nil
end

local configPath = removeOption("--config") or (programDirectory .. "config.lua")
local ok, config = pcall(dofile, configPath)
if not ok then
  io.stderr:write("Unable to load " .. configPath .. ": " .. tostring(config) .. "\n")
  os.exit(1)
end

local cli = require("lib.cli")
local success, err = xpcall(function()
  cli.run(config, args)
end, debug.traceback)

if not success then
  io.stderr:write(tostring(err) .. "\n")
  os.exit(1)
end
