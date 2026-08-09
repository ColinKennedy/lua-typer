--- `require("a.b")` -> file, against the search path (spec §8.3, §8.4).
---@class typer.resolve.modpath
local M = {}

local compat = require("typer.compat")
local fs = require("typer.fs")

---@class typer.ModuleResolution
---@field kind "lua"|"c"|"missing"
---@field path string|nil
---@field role string|nil        -- "stub" | "workspace" | "library"

--- Resolves a module name, memoising per search path.
---@param search typer.SearchPath
---@param module string
---@return typer.ModuleResolution
function M.resolve(search, module)
    search.cache = search.cache or {}
    local cached = search.cache[module]
    if cached then
        return cached
    end

    local relative = module:gsub("%.", "/")

    ---@type typer.ModuleResolution
    local result = { kind = "missing" }

    for _, entry in ipairs(search.entries) do
        local candidate = compat.normalize((entry.pattern:gsub("%?", relative)))
        if fs.is_file(candidate) then
            result = { kind = "lua", path = candidate, role = entry.role }
            break
        end
    end

    if result.kind == "missing" then
        -- A binary module resolves, but typer cannot read annotations out of it.
        for _, pattern in ipairs(search.cpath_patterns) do
            local candidate = compat.normalize((pattern:gsub("%?", relative)))
            if fs.is_file(candidate) then
                result = { kind = "c", path = candidate, role = "library" }
                break
            end
            -- `a.b` also maps to `a/b` and to the top-level `a` for C loaders.
            local head = module:match("^([^%.]+)")
            if head then
                local head_candidate = compat.normalize((pattern:gsub("%?", head)))
                if fs.is_file(head_candidate) then
                    result = { kind = "c", path = head_candidate, role = "library" }
                    break
                end
            end
        end
    end

    search.cache[module] = result
    return result
end

return M
