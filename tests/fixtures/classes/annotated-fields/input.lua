---@class Registry
---@field limit integer
local Registry = {}

--- Declared at the assignment: no ---@field on the class needed, and demanding
--- one would be two annotations for a single fact.
---@type table<string, integer>
Registry.counts = {}

--- Declared in the class block instead: also fine.
Registry.limit = 10

--- Neither: reported.
Registry.state = {}

--- `_` is a discard name and is exempt.
local _ = nil

return Registry
