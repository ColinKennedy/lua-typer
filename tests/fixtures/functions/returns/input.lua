local function one()
  return 1
end

local function multi()
  return 1, "two"
end

---@return integer
local function declared_one()
  return 1
end

---@return integer
local function under_declared()
  return 1, "two"
end

---@return integer
---@return string
---@return boolean
local function over_declared()
  return 1, "two"
end

local function bare_return()
  return
end

return { one, multi, declared_one, under_declared, over_declared, bare_return }
