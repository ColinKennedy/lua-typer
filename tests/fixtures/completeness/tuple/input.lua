---@class Pair
local Pair = {}

--- LuaLS tuple types. In primary position a `[` opens a tuple; after a type it
--- is the `[]` array suffix.
---@param entries [integer, string][]
---@param single [Pair, Missing]
---@return fun(): [integer, string]?
local function iterate(entries, single)
  print(single)
  return function()
    return nil
  end
end

return { Pair, iterate }
