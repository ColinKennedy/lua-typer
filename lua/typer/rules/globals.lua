--- `undefined-global`: reading a global that resolves to nothing (spec §3.1).
---
--- This is the `mypy --strict` "undefined name" check and the highest-value
--- rule in the tool -- it catches typos, missing `require`s, and accidental
--- reliance on globals another module leaked. It is also the rule most
--- dependent on stub quality, so it stays off until the stdlib stubs are loaded.
---@class typer.rules.globals
local M = {}

local diagnostic = require("typer.diagnostic")

---@param model typer.FileModel
---@param ctx typer.RuleContext
function M.run(model, ctx)
    if not ctx.config.undefined_globals then
        return
    end

    local registry = ctx.registry
    local ignore = ctx.config.global_allowlist or {}

    ---@type table<string, boolean>
    local reported = {}

    for _, read in ipairs(model.global_reads) do
        local name = read.name
        if not reported[name] and not model.globals[name] and not registry.globals[name] and not ignore[name] then
            -- Report once per name per file; a typo repeated ten times is one defect.
            reported[name] = true
            ctx.emit(
                diagnostic.new(
                    model.path,
                    read,
                    "undefined-global",
                    ("undefined global '%s'"):format(name),
                    "declare it with ---@type, add a stub, or fix the missing require"
                )
            )
        end
    end
end

return M
