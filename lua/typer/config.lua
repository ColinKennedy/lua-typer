--- Configuration loading and defaults (spec §9).
---@class typer.config
local M = {}

local compat = require("typer.compat")
local fs = require("typer.fs")
local json = require("typer.json")
local diagnostic = require("typer.diagnostic")

--- A per-path severity block (spec §9).
---
--- Not a baseline (§5): it names *paths*, not defects, so nothing is recorded as
--- known-bad and nothing goes stale. It is how a project holds its library code
--- to a higher standard than its tests, which is what most projects want and
--- what a single global `--severity` cannot express.
---@class typer.Override
---@field paths string[]
---@field severity table<string, string>   -- code -> level; `*` matches any code
---@field path_patterns string[]           -- `paths`, compiled once at load

---@class typer.Config
---@field overrides typer.Override[]
---@field source_roots string[]
---@field stub_paths string[]
---@field lua_path string[]
---@field lua_version string
---@field follow_requires "index"|"check"|"skip"
---@field ignore_missing string[]
---@field exclude string[]
---@field severity table<string, string>
---@field fail_on "error"|"warning"|"hint"   -- lowest severity that exits 1
---@field require_scalar_types boolean
---@field strict_globals boolean
---@field require_method_fields boolean
---@field undefined_globals boolean
---@field optional_param string
---@field optional_return string
---@field inherit_path boolean        -- inherit the interpreter's package.path
---@field cache boolean               -- use the on-disk declaration cache
---@field root string                 -- directory the config was found in
---@field path string|nil             -- the config file itself, when one was found
---@field workspace string|nil        -- workspace root, when the host supplies one
---@field global_allowlist table<string, boolean>|nil
--- Globs compiled to Lua patterns once, at load time.
---@field exclude_patterns string[]
---@field ignore_missing_patterns string[]

---@return typer.Config
function M.defaults()
    return {
        source_roots = { ".", "lua" },
        stub_paths = {},
        lua_path = {},
        lua_version = compat.is_jit and "jit" or (compat.lua_version:match("%d%.%d") or "5.1"),
        follow_requires = "index",
        ignore_missing = {},
        exclude = {},
        severity = {},
        overrides = {},
        fail_on = "hint",
        require_scalar_types = false,
        strict_globals = true,
        require_method_fields = false,
        undefined_globals = true,
        optional_param = "off",
        optional_return = "off",
        inherit_path = true,
        cache = true,
        root = ".",
    }
end

--- Loads `.typer.lua` in a sandbox. The file returns a table; it gets no I/O,
--- no `os`, and no `require` -- config is data, not a program.
---@param path string
---@return table<string, typer.PlainValue>|nil
---@return string|nil
local function load_lua_config(path)
    local source = compat.read_file(path)
    if not source then
        return nil, "cannot read " .. path
    end

    local chunk, err = compat.load_string(source, "@" .. path)
    if not chunk then
        return nil, err
    end

    ---@type table<string, (fun(...): ...)|table<string, (fun(...): ...)>>
    local sandbox = {
        pairs = pairs,
        ipairs = ipairs,
        next = next,
        type = type,
        tostring = tostring,
        tonumber = tonumber,
        string = string,
        table = table,
        math = math,
        select = select,
    }
    compat.setfenv(chunk, sandbox)

    local ok, result = pcall(chunk)
    if not ok then
        return nil, tostring(result)
    end
    if type(result) ~= "table" then
        return nil, path .. " must return a table"
    end
    return result, nil
end

---@param path string
---@return table<string, typer.PlainValue>|nil
---@return string|nil
local function load_json_config(path)
    local source = compat.read_file(path)
    if not source then
        return nil, "cannot read " .. path
    end

    local decoded, err = json.decode(source)
    if type(decoded) ~= "table" then
        return nil, err or (path .. " is not a JSON object")
    end
    ---@cast decoded table<string, typer.PlainValue>
    return decoded, nil
end

--- Searches upward from `start` for a config file.
---@param start string
---@return string|nil
local function discover(start)
    local dir = compat.normalize(start)
    local guard = 0

    while guard < 64 do
        guard = guard + 1
        for _, name in ipairs({ ".typer.lua", ".typer.json" }) do
            local candidate = compat.join(dir, name)
            if compat.file_exists(candidate) then
                return candidate
            end
        end
        local parent = compat.dirname(dir)
        if parent == dir then
            break
        end
        dir = parent
    end

    return nil
end

---@param target typer.Config
---@param source table<string, typer.PlainValue>
local function merge(target, source)
    for key, value in pairs(source) do
        if key == "severity" and type(value) == "table" then
            target.severity = target.severity or {}
            for code, level in pairs(value) do
                target.severity[code] = level
            end
        else
            target[key] = value
        end
    end
end

--- Converts a glob to a Lua pattern. `**` crosses separators, `*` does not.
---@param glob string
---@return string
local function glob_to_pattern(glob)
    local pattern = glob:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
    pattern = pattern:gsub("%*%*/?", "\1")
    pattern = pattern:gsub("%*", "\2")
    pattern = pattern:gsub("%?", ".")
    pattern = pattern:gsub("\1", ".*")
    pattern = pattern:gsub("\2", "[^/]*")
    return "^" .. pattern .. "$"
end

--- Loads configuration, applying defaults then the discovered file.
---@param explicit_path string|nil
---@param cwd string
---@return typer.Config
---@return string|nil error
function M.load(explicit_path, cwd)
    local config = M.defaults()
    local path = explicit_path or discover(cwd)

    if path then
        ---@type table<string, typer.PlainValue>|nil, string|nil
        local loaded, err
        if path:match("%.json$") then
            loaded, err = load_json_config(path)
        else
            loaded, err = load_lua_config(path)
        end
        if not loaded then
            return config, err
        end
        merge(config, loaded)
        -- The root is an identity used to key files, so it must be absolute: a
        -- relative `--config` must not produce a second spelling of the same tree.
        -- Absolutise against the *process* directory -- `cwd` here is only where
        -- discovery starts, and paths given on the command line are relative to
        -- where typer was actually invoked.
        local base = fs.cwd()
        config.root = compat.absolute(compat.dirname(path), base)
        config.path = compat.absolute(path, base)
    else
        config.root = compat.absolute(cwd, fs.cwd())
    end

    -- Normalise list-shaped options that a user may have written as a bare string.
    for _, key in ipairs({ "source_roots", "stub_paths", "lua_path", "exclude", "ignore_missing" }) do
        if type(config[key]) == "string" then
            config[key] = { config[key] }
        end
        config[key] = config[key] or {}
    end

    -- Turn the ignore_missing globs into Lua patterns once.
    config.ignore_missing_patterns = {}
    for _, glob in ipairs(config.ignore_missing) do
        config.ignore_missing_patterns[#config.ignore_missing_patterns + 1] = glob_to_pattern(glob)
    end
    config.exclude_patterns = {}
    for _, glob in ipairs(config.exclude) do
        config.exclude_patterns[#config.exclude_patterns + 1] = glob_to_pattern(glob)
    end

    config.overrides = config.overrides or {}
    for _, override in ipairs(config.overrides) do
        override.severity = override.severity or {}
        override.path_patterns = {}
        local paths = override.paths
        if type(paths) == "string" then
            paths = { paths }
        end
        for _, glob in ipairs(paths or {}) do
            override.path_patterns[#override.path_patterns + 1] = glob_to_pattern(glob)
        end
    end

    return config, nil
end

---@param config typer.Config
---@param path string
---@return boolean
function M.is_excluded(config, path)
    local normalized = compat.normalize(path)
    for _, pattern in ipairs(config.exclude_patterns or {}) do
        if normalized:match(pattern) then
            return true
        end
    end
    return false
end

---@param config typer.Config
---@param module string
---@return boolean
function M.ignores_module(config, module)
    for _, pattern in ipairs(config.ignore_missing_patterns or {}) do
        if module:match(pattern) then
            return true
        end
    end
    return false
end

--- Effective severity for a code at a path, after config overrides.
---
--- Precedence, most specific first: a per-path block, then the global
--- `severity` table, then the code's default. Among per-path blocks the *last*
--- match wins, so a later, narrower entry can carve an exception out of a
--- broader one above it.
---@param config typer.Config
---@param code string
---@param path string|nil   -- relative to the config root; nil skips path rules
---@return string
function M.severity_of(config, code, path)
    if path then
        for index = #(config.overrides or {}), 1, -1 do
            local override = config.overrides[index]
            for _, pattern in ipairs(override.path_patterns or {}) do
                if path:match(pattern) then
                    local level = override.severity[code] or override.severity["*"]
                    if level then
                        return level
                    end
                    break
                end
            end
        end
    end

    local global = config.severity and config.severity[code]
    if global then
        return global
    end
    return diagnostic.DEFAULT_SEVERITY[code] or "error"
end

return M
