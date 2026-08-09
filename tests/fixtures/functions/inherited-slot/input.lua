---@class Slots
---@field seam fun(name: string): nil
local M = {}

--- A local whose ---@type states the signature. The function assigned into it
--- inherits that, and annotating it again would be duplication typer cannot
--- check and drift it cannot catch.
---@type fun(name: string): nil
local callback

callback = function(name)
  print(name)
end

--- A parameter is a slot like any other, and `or` is how Lua spells a default.
---@param configure? fun(name: string, level: integer): nil A test seam.
---@return nil
function M.setup(configure)
  configure = configure or function(name, level)
    print(name, level)
  end

  configure("x", 1)
end

--- Declared once, with annotations.
---@param value string The value to echo.
---@return string # The same value.
function M.echo(value)
  return value
end

--- Overriding it inherits the declaration above.
M.echo = function(value)
  return value .. "!"
end

--- Declared with no annotations at all, so there is no type to inherit and the
--- override is as undeclared as the original.
function M.bare(value)
  return value
end

M.bare = function(value)
  return value
end

--- A returned closure is named by its return position, and the enclosing
--- ---@return is the name it is given.
---@param values string[] Values to walk.
---@return fun(): string? # An iterator over `values`.
function M.iterate(values)
  local index = 0

  return function()
    index = index + 1

    return values[index]
  end
end

--- The same, but the enclosing annotation promises one value and the body hands
--- back two. No annotation written here would fix that.
---@param values string[] Values to walk.
---@return fun(): [integer, string]? # A badly typed iterator.
function M.mistyped(values)
  local index = 0

  return function()
    index = index + 1

    return index, values[index]
  end
end

--- A half-written doc block is a mistake worth reporting, so the moment one
--- ---@param appears the ordinary rules take over and it has to be complete.
---@param first string The first one.
M.partial = function(first, second)
  return first, second
end

return M
