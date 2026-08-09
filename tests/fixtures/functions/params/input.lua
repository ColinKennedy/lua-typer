local function two(a, b)
  print(a, b)
end

---@param a string
local function partial(a, b)
  print(a, b)
end

---@param a string
---@param b integer
local function complete(a, b)
  print(a, b)
end

---@param wrong string
---@param b integer
local function mismatched(a, b)
  print(a, b)
end

---@param a string
---@param b integer
---@param extra boolean
local function too_many(a, b)
  print(a, b)
end

return { two, partial, complete, mismatched, too_many }
