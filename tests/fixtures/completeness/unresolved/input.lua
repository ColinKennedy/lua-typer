---@class Known
---@field id integer
local Known = {}

---@param a Known
---@param b Missing
---@return Known
local function use(a, b)
  print(b)
  return a
end

return { Known, use }
