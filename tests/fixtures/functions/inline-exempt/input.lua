---@param cb fun(x: integer): boolean
---@return boolean
local function apply(cb)
  return cb(1)
end

apply(function(x)
  return x > 0
end)

---@class Handlers
---@field on_click fun(x: integer)
local handlers = {
  on_click = function(x)
    print(x)
  end,
}

local named = function(y)
  print(y)
end

return { apply, handlers, named }
