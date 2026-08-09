-- `unresolved-module` is raised while the index is built, before this file's
-- own rules run. A directive still has to reach it.
-- typer: ignore[unresolved-module]
local absent = require("definitely.not.here")

local also_absent = require("nor.is.this")

return { absent, also_absent }
