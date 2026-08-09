local bar = {}

local populated = { name = "x", age = 1 }

---@type table<string, integer>
local ok = {}

---@class Config
---@field debug boolean
local cfg = { debug = false }

return { bar, populated, ok, cfg }
