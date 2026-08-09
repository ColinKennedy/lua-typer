--- Builds the module search path (spec §8.3).
---
--- Precedence, first hit wins:
---   1. --stub-path / config.stub_paths
---   2. bundled stdlib stubs for the target Lua version
---   3. config.source_roots
---   4. config.lua_path
---   5. $LUA_PATH and the versioned $LUA_PATH_5_x
---   6. package.path of the running interpreter (unless --no-inherit-path)
---   7. workspace.library from .luarc.json
---
--- Stubs deliberately outrank real source: a hand-written `---@meta` file is
--- the escape hatch for a dependency that cannot be annotated.
---@class typer.resolve.search
local M = {}

local bundle = require("typer.bundle")
local compat = require("typer.compat")
local fs = require("typer.fs")
local json = require("typer.json")

---@class typer.SearchEntry
---@field pattern string        -- a `?`-bearing path template
---@field role "stub"|"workspace"|"library"
---@field eager boolean|nil     -- scanned up front rather than on first require

--- Expands `$VAR` / `${VAR}` / a leading `~` in a path.
---
--- `.luarc.json` routinely contains `$VIMRUNTIME/lua`, which is the whole point
--- of reading the file for a Neovim project.
---@param path string
---@return string
local function expand(path)
    local expanded = path:gsub("^~", os.getenv("HOME") or "~")
    expanded = expanded:gsub("%${([%w_]+)}", function(name)
        return os.getenv(name) or ""
    end)
    expanded = expanded:gsub("%$([%w_]+)", function(name)
        return os.getenv(name) or ""
    end)
    return expanded
end

--- Where the bundled stubs live.
---@return string|nil
local function bundled_stub_root()
    -- `bin/typer` resolved the install root from `arg[0]`. It is the only thing
    -- that knows where an installed rock put `stubs/`, so it wins.
    if bundle.root then
        local root = compat.join(bundle.root, "stubs")
        if fs.is_dir(root) then
            return root
        end
    end

    -- `package.searchpath` is 5.2+; probe `package.path` entries by hand so this
    -- works identically on 5.1.
    for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", "typer/compat")
        if compat.file_exists(candidate) then
            -- <...>/lua/typer/compat.lua -> <...>/stubs
            local lua_dir = compat.dirname(compat.dirname(candidate))
            local root = compat.join(compat.dirname(lua_dir), "stubs")
            if fs.is_dir(root) then
                return root
            end
        end
    end
    return nil
end

--- Expands a directory into the two conventional `?` patterns.
---@param dir string
---@param role string
---@param out typer.SearchEntry[]
---@param eager? boolean
local function add_dir(dir, role, out, eager)
    out[#out + 1] = { pattern = compat.join(dir, "?.lua"), role = role, eager = eager }
    out[#out + 1] = { pattern = compat.join(dir, "?/init.lua"), role = role, eager = eager }
end

--- Splits a `;`-separated Lua path, expanding `;;` to the interpreter default.
---@param value string
---@param role string
---@param out typer.SearchEntry[]
local function add_path_string(value, role, out)
    if not value or value == "" then
        return
    end

    local expanded = value:gsub(";;", ";" .. package.path .. ";")
    for template in expanded:gmatch("[^;]+") do
        if template:find("?", 1, true) then
            out[#out + 1] = { pattern = compat.normalize(template), role = role }
        end
    end
end

--- Reads `workspace.library` out of a `.luarc.json`, if one exists. This is how
--- Neovim projects pick up the `vim.*` definitions.
---@param root string
---@param out typer.SearchEntry[]
local function add_luarc(root, out)
    local path = compat.join(root, ".luarc.json")
    if not compat.file_exists(path) then
        return
    end

    local decoded = json.decode(compat.read_file(path) or "")
    if type(decoded) ~= "table" then
        return
    end
    ---@cast decoded table<string, typer.PlainValue>

    local library = decoded["workspace.library"] or (type(decoded.workspace) == "table" and decoded.workspace.library)
    if type(library) ~= "table" then
        return
    end

    for _, entry in ipairs(library) do
        if type(entry) == "string" then
            -- Relative entries are relative to the .luarc.json, not to the cwd.
            local dir = compat.absolute(expand(entry), root)
            -- Eager: `workspace.library` is the user declaring "these are my type
            -- sources". Nothing in the project need `require` them -- the `vim`
            -- global lives in a runtime file no config ever requires -- so lazy
            -- indexing would never reach them. LuaLS scans them up front too.
            if fs.is_dir(dir) then
                add_dir(dir, "library", out, true)
            end
        end
    end
end

---@param config typer.Config
---@return string[]
local function version_env_names(config)
    local version = config.lua_version or "5.1"
    if version == "jit" then
        return { "LUA_PATH", "LUA_PATH_5_1" }
    end
    local suffix = version:gsub("%.", "_")
    return { "LUA_PATH", "LUA_PATH_" .. suffix }
end

--- Command-line overrides that outrank the config file.
---@class typer.SearchOverrides
---@field stub_paths string[]|nil
---@field lua_path string[]|nil
---@field inherit_path boolean|nil

---@class typer.SearchPath
---@field entries typer.SearchEntry[]
---@field cpath_patterns string[]
---@field stub_root string|nil
---@field cache table<string, typer.ModuleResolution>|nil  -- memoised by modpath.resolve

--- Builds the search path for a run.
---@param config typer.Config
---@param overrides typer.SearchOverrides
---@return typer.SearchPath
function M.build(config, overrides)
    overrides = overrides or {}

    ---@type typer.SearchEntry[]
    local entries = {}

    -- `absolute`, not `join`: a `--stub-path` naming a stub directory outside the
    -- project is the normal case, and `join` would glue it onto the root.
    for _, dir in ipairs(overrides.stub_paths or {}) do
        add_dir(compat.absolute(expand(dir), config.root), "stub", entries)
    end
    for _, dir in ipairs(config.stub_paths or {}) do
        add_dir(compat.absolute(expand(dir), config.root), "stub", entries)
    end

    local stub_root = bundled_stub_root()
    if stub_root then
        local version_dir =
            compat.join(stub_root, config.lua_version == "jit" and "5.1" or (config.lua_version or "5.1"))
        if fs.is_dir(version_dir) then
            add_dir(version_dir, "stub", entries)
        elseif fs.is_dir(compat.join(stub_root, "5.1")) then
            add_dir(compat.join(stub_root, "5.1"), "stub", entries)
        end
    end

    for _, dir in ipairs(config.source_roots or {}) do
        local resolved = compat.join(config.root, dir)
        if fs.is_dir(resolved) then
            add_dir(resolved, "workspace", entries)
        end
    end

    for _, template in ipairs(overrides.lua_path or {}) do
        add_path_string(template, "library", entries)
    end
    for _, template in ipairs(config.lua_path or {}) do
        -- Bare directories are accepted as a convenience alongside `?` templates.
        if template:find("?", 1, true) then
            add_path_string(template, "library", entries)
        else
            add_dir(compat.absolute(expand(template), config.root), "library", entries)
        end
    end

    for _, name in ipairs(version_env_names(config)) do
        add_path_string(os.getenv(name) or "", "library", entries)
    end

    if overrides.inherit_path ~= false and config.inherit_path ~= false then
        add_path_string(package.path, "library", entries)
    end

    add_luarc(config.root, entries)

    -- `LUA_CPATH`/`package.cpath` are searched only to *detect* C modules, never
    -- to read them: typer cannot pull annotations out of a shared object.
    ---@type string[]
    local cpath_patterns = {}
    local cpath = (os.getenv("LUA_CPATH") or "") .. ";" .. (package.cpath or "")
    for template in cpath:gmatch("[^;]+") do
        if template:find("?", 1, true) then
            cpath_patterns[#cpath_patterns + 1] = template
        end
    end

    -- De-duplicate while preserving precedence.
    ---@type typer.SearchEntry[]
    local unique = {}
    ---@type table<string, boolean>
    local seen = {}
    for _, entry in ipairs(entries) do
        if not seen[entry.pattern] then
            seen[entry.pattern] = true
            unique[#unique + 1] = entry
        end
    end

    return { entries = unique, cpath_patterns = cpath_patterns, stub_root = stub_root }
end

return M
