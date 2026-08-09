-- The bracketed code list, and the range reaching back over the doc block the
-- directive cannot be written inside.
-- typer: ignore[disallowed-any]
---@param opts table<string, integer>
---@return any
local function loose(opts)
  return opts
end

-- One directive, several codes.
-- typer: ignore[vague-table, disallowed-unknown]
---@param opts table
---@return unknown
local function vague(opts)
  return opts
end

-- Only the code named is silenced; the rest still report.
-- typer: ignore[vague-table]
---@param opts table
---@return any
local function partial(opts)
  return opts
end

local trailing = {} -- typer: ignore[table-decl]

---@class Fixture.Heterogeneous A directive trailing the tag it is about.
---@field display string
---@field value any The original data, unformatted. -- typer: ignore[disallowed-any]
---@field other any Not covered: the one above is scoped to its own line.

---@param name string
---@return any # The previous value. -- typer: ignore
local function saved(name)
  return name
end

return { loose, vague, partial, trailing, saved }
