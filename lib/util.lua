local util = {}

function util.copy(value)
  if type(value) ~= "table" then
    return value
  end

  local result = {}
  for key, child in pairs(value) do
    result[util.copy(key)] = util.copy(child)
  end
  return result
end

function util.sortedKeys(value)
  local keys = {}
  for key in pairs(value or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(left, right)
    return tostring(left) < tostring(right)
  end)
  return keys
end

function util.tableLength(value)
  local count = 0
  for _ in pairs(value or {}) do
    count = count + 1
  end
  return count
end

function util.isEmptyStack(stack)
  if stack == nil then
    return true
  elseif type(stack) ~= "table" then
    error("Expected an item stack table, got " .. type(stack), 2)
  end
  return next(stack) == nil or (stack.size or 0) <= 0
end

function util.itemMatches(stack, filter)
  if stack == nil or type(stack) ~= "table" or next(stack) == nil then
    return false
  elseif stack.size ~= nil and stack.size <= 0 then
    return false
  end

  for key, expected in pairs(filter or {}) do
    if key ~= "size" and not util.valuesEqual(stack[key], expected) then
      return false
    end
  end
  return true
end

function util.valuesEqual(left, right)
  if type(left) ~= type(right) then
    return false
  elseif type(left) ~= "table" then
    return left == right
  end

  for key, value in pairs(left) do
    if not util.valuesEqual(value, right[key]) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

function util.itemIdentity(stack)
  if util.isEmptyStack(stack) then
    return nil
  end

  local result = {}
  for _, key in ipairs({"name", "damage", "label", "hasTag", "tag"}) do
    if stack[key] ~= nil then
      result[key] = stack[key]
    end
  end
  return result
end

function util.join(values, separator)
  local strings = {}
  for index, value in ipairs(values or {}) do
    strings[index] = tostring(value)
  end
  return table.concat(strings, separator or ", ")
end

function util.describe(value, depth)
  depth = depth or 0
  if type(value) ~= "table" then
    return tostring(value)
  end
  if depth >= 3 then
    return "{...}"
  end

  local parts = {}
  for _, key in ipairs(util.sortedKeys(value)) do
    parts[#parts + 1] = tostring(key) .. "=" .. util.describe(value[key], depth + 1)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

function util.waitUntil(environment, predicate, timeoutSeconds, description)
  local deadline = environment.now() + timeoutSeconds
  local lastReason = nil

  while environment.now() <= deadline do
    local complete, reason = predicate()
    if complete then
      return reason
    end
    lastReason = reason
    environment.sleep(environment.pollSeconds)
  end

  local suffix = lastReason and (": " .. tostring(lastReason)) or ""
  error("Timed out waiting for " .. description .. suffix, 2)
end

function util.requirePositiveInteger(value, name)
  if type(value) ~= "number" or value < 1 or value ~= math.floor(value) then
    error(name .. " must be a positive integer", 2)
  end
  return value
end

return util
