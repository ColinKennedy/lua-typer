-- typer: ignore table-decl
local only_table_suppressed = {}

-- typer: ignore missing-param
local function f(a)
  print(a)
  return 1
end

return { only_table_suppressed, f }
