---@param a string
---@return integer
local annotated_local = function(a)
  return #a
end

local bare_local = function(a)
  return #a
end

---@class Holder
local Holder = {}

---@param b integer
---@return boolean
Holder.check = function(b)
  return b > 0
end

Holder.unchecked = function(b)
  return b > 0
end

---@return fun(x: integer): integer
local function make()
  ---@param x integer
  ---@return integer
  return function(x)
    return x * 2
  end
end

local iife = (function()
  return 1
end)()

return { annotated_local, bare_local, Holder, make, iife }
