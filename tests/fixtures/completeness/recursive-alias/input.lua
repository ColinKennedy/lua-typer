--- A recursive alias is the honest type for a serialisation boundary, and it
--- terminates: a named type is complete once it resolves.
---@alias Plain nil|boolean|number|string|Plain[]|table<string, Plain>

---@param value Plain
---@return string
local function render(value)
  return tostring(value)
end

---@param value Missing
---@return string
local function broken(value)
  return tostring(value)
end

return { render, broken }
