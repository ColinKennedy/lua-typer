-- Nothing to suppress: the statement below is fully typed.
-- typer: ignore
---@type integer
local clean = 1

-- The wrong code: the directive is dead and the real defect still reports.
-- typer: ignore[vague-table]
local wrong = {}

-- A code that does not exist at all.
-- typer: ignore[table-declaration]
---@type table<string, integer>
local misspelled = {}

-- Two codes, one of which does its job.
-- typer: ignore[table-decl, missing-param]
local half = {}

-- Live directives report nothing.
-- typer: ignore-next-line[table-decl]
local live = {}

-- Prose inside a doc block is never a directive, only an annotation line is.
--- Documents `-- typer: ignore`, and stays documentation.
---@type integer
local documented = 1

return { clean, wrong, misspelled, half, live, documented }
