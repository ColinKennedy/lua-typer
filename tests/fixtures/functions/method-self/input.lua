---@class Widget
local Widget = {}

---@param self Widget
---@param value integer
function Widget:set(value)
  self.value = value
end

---@param value integer
function Widget:ok(value)
  print(self, value)
end

return Widget
