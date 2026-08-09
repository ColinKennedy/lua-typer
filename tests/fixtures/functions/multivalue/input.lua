local function inner()
  return 1, "two"
end

---@return integer
---@return string
local function forwards()
  return inner()
end

---@return boolean
local function under_declared_tail()
  return inner()
end

---@param ... any
---@return any
local function forwards_varargs(...)
  return ...
end

local function unannotated_tail()
  return inner()
end

return { forwards, under_declared_tail, forwards_varargs, unannotated_tail }
