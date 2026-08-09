---@class Point
---@field x integer
local Point = {}
Point.__index = Point

---@return Point
function Point.new()
  local self = setmetatable({}, Point)
  self.x = 0
  self.y = 0
  return self
end

Point.origin = true

---@param dx integer
function Point:move(dx)
  self.x = self.x + dx
end

return Point
