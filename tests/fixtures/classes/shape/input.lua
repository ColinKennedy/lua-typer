local Colon = {}
function Colon:method() end

local Indexed = {}
Indexed.__index = Indexed

local Meta = {}
local instance = setmetatable({}, Meta)

---@class Declared
local Declared = {}
function Declared:method() end

return { Colon, Indexed, Meta, instance, Declared }
