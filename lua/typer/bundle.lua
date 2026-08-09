--- Where typer itself is installed.
---
--- The bundled stdlib stubs sit beside `bin/` in both layouts typer ships in --
--- a source checkout and an installed rock -- but only the checkout keeps
--- `lua/` there too. LuaRocks splits the two: modules go to
--- `share/lua/<version>/typer/`, `copy_directories` puts `stubs/` next to the
--- rock's `bin/`. So the library cannot find the stubs relative to its own
--- source file, and `bin/typer` -- which already resolves the root from
--- `arg[0]` to bootstrap `package.path` -- hands it over here instead.
---
--- Left `nil` when typer is used as a library rather than through its
--- executable; `resolve.search` falls back to probing `package.path`.
---@class typer.bundle
local M = {}

---@type string|nil
M.root = nil

return M
