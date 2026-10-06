local journal = {}
journal.__index = journal

function journal.new(path)
  local serialization = require("serialization")
  local filesystem = require("filesystem")

  return setmetatable({
    path = path,
    serialization = serialization,
    filesystem = filesystem,
  }, journal)
end

function journal:load()
  if not self.filesystem.exists(self.path) then
    return nil
  end

  local file, openError = io.open(self.path, "r")
  if not file then
    error("Unable to open journal: " .. tostring(openError))
  end
  local content = file:read("*a")
  file:close()

  local data, parseError = self.serialization.unserialize(content)
  if data == nil then
    error("Unable to parse journal: " .. tostring(parseError))
  end
  return data
end

function journal:save(data)
  local temporaryPath = self.path .. ".tmp"
  local file, openError = io.open(temporaryPath, "w")
  if not file then
    error("Unable to write journal: " .. tostring(openError))
  end

  file:write(self.serialization.serialize(data))
  file:close()

  if self.filesystem.exists(self.path) then
    local removed, removeError = self.filesystem.remove(self.path)
    if not removed then
      error("Unable to replace journal: " .. tostring(removeError))
    end
  end

  local _, renameError = self.filesystem.rename(temporaryPath, self.path)
  if not self.filesystem.exists(self.path) or self.filesystem.exists(temporaryPath) then
    error("Unable to publish journal: " .. tostring(renameError))
  end
end

function journal:clear()
  if self.filesystem.exists(self.path) then
    local removed, removeError = self.filesystem.remove(self.path)
    if not removed then
      error("Unable to clear journal: " .. tostring(removeError))
    end
  end
end

return journal
