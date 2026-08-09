---@class Fixture
local Fixture = {}

-- A `_` standing in for a discarded `self` needs no ---@param.
---@param callback fun(count: integer): nil
Fixture.count_async = function(_, callback)
  callback(20)
end

-- Documenting it anyway is equally valid, and bare `any` is allowed there.
---@param _ any Unused. Kept for the `:` call convention.
---@param callback fun(count: integer): nil
Fixture.documented = function(_, callback)
  callback(20)
end

-- A typed placeholder is checked like any other parameter.
---@param _ string
---@param callback fun(count: integer): nil
Fixture.typed = function(_, callback)
  callback(20)
end

-- Several placeholders in one signature, none of them annotated.
---@param on_complete fun(): nil
local function several(_, _, on_complete)
  on_complete()
end

-- The `_a` / `_b` spelling is what lets each of them be documented.
---@param _a string
---@param _b boolean
---@param on_complete fun(): nil
local function distinct(_a, _b, on_complete)
  on_complete()
end

-- `self` on a `.`-defined function comes from the class, not from ---@param.
---@param value integer
Fixture.set = function(self, value)
  print(self, value)
end

-- Both lines bind to the first `_`; the second parameter stays undocumented.
---@param _ string
---@param _ boolean
---@param on_complete fun(): nil
local function duplicated(_, _, on_complete)
  on_complete()
end

-- A real parameter still has to be annotated.
local function real(count)
  print(count)
end

return { Fixture, several, distinct, duplicated, real }
