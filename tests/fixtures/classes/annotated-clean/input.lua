---@class Base
local Base = {}

---@class Stack : Base
---@field items integer[]
---@field size integer
local Stack = {}
Stack.__index = Stack
setmetatable(Stack, { __index = Base })

---@return Stack
function Stack.new()
  local self = setmetatable({}, Stack)
  self.items = {}
  self.size = 0
  return self
end

---@param v integer
function Stack:push(v)
  self.items[#self.items + 1] = v
  self.size = self.size + 1
end

---@return integer?
function Stack:pop()
  if self.size == 0 then
    return nil
  end
  local value = self.items[self.size]
  self.size = self.size - 1
  return value
end

return Stack
