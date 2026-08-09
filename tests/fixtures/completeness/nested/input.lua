---@class Node
---@field label string
---@field children Node[]
---@field meta table<string, Node>
local Node = {}

---@class Bad
---@field payload table
---@field handler fun(x: any): table
local Bad = {}

return { Node, Bad }
