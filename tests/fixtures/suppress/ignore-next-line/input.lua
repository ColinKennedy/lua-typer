-- Line-scoped: only the next line of code, not the whole statement.
-- typer: ignore-next-line
local bad = {}

-- The body of the function below is *not* covered, so its own defects report.
-- typer: ignore-next-line[missing-param]
local function outer(a)
  local inner = {}
  return inner, a
end

-- Same code list spellings as `ignore`.
-- typer: ignore-next-line vague-table
---@param opts table
local function bare_list(opts)
  return opts
end

--- Inside a doc block, the directive covers the next annotation and nothing
--- else -- and does not sever the run, so the `---@param` above it still binds.
---@param name string The name to save.
-- typer: ignore-next-line[disallowed-any]
---@return any # The previous value.
local function save_global(name)
  return name
end

--- The tag below the directive is covered; the one above it is not.
---@param first any Reported: the directive points down, not up.
-- typer: ignore-next-line[disallowed-any]
---@param second any Silenced.
---@return integer
local function pair(first, second)
  return 1
end

return { bad, outer, bare_list, save_global, pair }
