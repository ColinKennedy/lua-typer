--- A lazy list. `__index` here is a computed-lookup metamethod, not
--- inheritance: it generates values on demand rather than falling back to a
--- base, so there are no fields to declare and `---@type string[]` describes it
--- completely.
---@type string[]
local generated = {}

setmetatable(generated, {
  __index = function(_, key)
    return tostring(key)
  end,
})

--- The same shape without any annotation still has to say what it is.
local undeclared = {}

setmetatable(undeclared, {
  __index = function(_, key)
    return tostring(key)
  end,
})

--- Real inheritance: `__index` is a table, so instances fall back to it.
---@class Base
local Base = {}

---@return Base # A new instance.
function Base.new()
  return setmetatable({}, Base)
end

--- A class-shaped table with no ---@class is still the finding it always was.
local Untyped = {}
Untyped.__index = Untyped

---@return table<string, string> # A new instance.
function Untyped.new()
  return setmetatable({}, Untyped)
end

return { generated, undeclared, Base, Untyped }
