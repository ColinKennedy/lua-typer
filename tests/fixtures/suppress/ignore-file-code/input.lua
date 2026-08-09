-- Whole file, but only for the code named.
-- typer: ignore-file[table-decl]

local first = {}
local second = {}

local function untyped(a)
  return a
end

return { first, second, untyped }
