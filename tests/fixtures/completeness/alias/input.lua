--- Prose in a doc block, not an alias continuation:
---   expr := term
---        | factor
---        | "literal"

---@alias Mode
---| "read"
---| "write"

---@enum Level
local Level = { debug = 1, info = 2 }

---@param mode Mode
---@param level Level
---@return Mode
local function pick(mode, level)
  print(level)
  return mode
end

return { Level = Level, pick = pick }
