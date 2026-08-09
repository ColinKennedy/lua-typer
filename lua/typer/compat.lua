--- Portability shims. typer ships as a rock and must run on Lua 5.1-5.4 and
--- LuaJIT, so nothing outside this file may reference a version-specific API.
---@class typer.compat
local M = {}

---@type string
M.lua_version = _VERSION or "Lua 5.1"

---@type boolean
M.is_jit = type(rawget(_G, "jit")) == "table"

--- `load` with a string chunk, present on every version.
---@param chunk string
---@param name string
---@return (fun(...): ...)|nil
---@return string|nil
function M.load_string(chunk, name)
    if _VERSION == "Lua 5.1" and not M.is_jit then
        return loadstring(chunk, name)
    end
    -- 5.2+ `load` takes a mode argument; the 5.1 definitions LuaLS checks against
    -- describe the two-argument form, which this branch never runs under.
    ---@diagnostic disable-next-line: param-type-mismatch, redundant-parameter
    return load(chunk, name, "b" == chunk:sub(1, 1) and "b" or "bt")
end

--- `load` a binary (string.dump) chunk.
---@param chunk string
---@param name string
---@return (fun(...): ...)|nil
---@return string|nil
function M.load_binary(chunk, name)
    if _VERSION == "Lua 5.1" and not M.is_jit then
        return loadstring(chunk, name)
    end
    ---@diagnostic disable-next-line: param-type-mismatch, redundant-parameter
    return load(chunk, name, "b")
end

--- setfenv/`_ENV` bridge, used to sandbox `.typer.lua` config files.
---@param fn fun(...): ...
---@param env table<string, typer.PlainValue|(fun(...): ...)>
---@return fun(...): ...
function M.setfenv(fn, env)
    if rawget(_G, "setfenv") then
        return rawget(_G, "setfenv")(fn, env) or fn
    end
    -- 5.2+: _ENV is the first upvalue of any chunk that touches a global.
    local i = 1
    while true do
        local name = debug.getupvalue(fn, i)
        if not name then
            break
        end
        if name == "_ENV" then
            -- 5.2+ only, which is exactly the case this branch exists for: 5.1
            -- took the `setfenv` path above and never reaches here.
            ---@diagnostic disable-next-line: deprecated
            debug.upvaluejoin(fn, i, function()
                return env
            end, 1)
            break
        end
        i = i + 1
    end
    return fn
end

--- A stable identifier for the bytecode format, so a cache written by one
--- interpreter is never `load()`ed by an incompatible one. Loading a mismatched
--- binary chunk can abort the process outright, so this must be conservative.
---@return string
function M.bytecode_tag()
    local probe = string.dump(function()
        return 1
    end)
    -- Lua's binary header: signature, version, format, then size fields whose
    -- widths differ per platform. The first 12 bytes capture all of it.
    local header = probe:sub(1, 12):gsub(".", function(c)
        return string.format("%02x", string.byte(c))
    end)
    return (M.is_jit and "jit-" or "puc-") .. M.lua_version:gsub("%s", "") .. "-" .. header
end

---@param path string
---@return boolean
function M.file_exists(path)
    local fh = io.open(path, "r")
    if fh then
        fh:close()
        return true
    end
    return false
end

---@param path string
---@return string|nil
function M.read_file(path)
    local fh = io.open(path, "rb")
    if not fh then
        return nil
    end
    local content = fh:read("*a")
    fh:close()
    return content
end

---@param path string
---@param content string
---@return boolean
function M.write_file(path, content)
    local fh = io.open(path, "wb")
    if not fh then
        return false
    end
    fh:write(content)
    fh:close()
    return true
end

---@type string
local sep = package.config and package.config:sub(1, 1) or "/"

---@type boolean
M.is_windows = sep == "\\"

--- Normalise a path to forward slashes and collapse `.`/`..`/duplicate slashes.
---@param path string
---@return string
function M.normalize(path)
    path = path:gsub("\\", "/")
    local absolute = path:sub(1, 1) == "/"
    local drive = path:match("^(%a:)/") or ""
    if drive ~= "" then
        path = path:sub(#drive + 1)
    end

    ---@type string[]
    local parts = {}
    for piece in path:gmatch("[^/]+") do
        if piece == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                table.remove(parts)
            elseif not absolute then
                parts[#parts + 1] = piece
            end
        elseif piece ~= "." then
            parts[#parts + 1] = piece
        end
    end

    local joined = table.concat(parts, "/")
    if absolute then
        joined = "/" .. joined
    end
    return drive .. (joined == "" and (absolute and "/" or ".") or joined)
end

--- Absolute, normalised form of a path. This is the *identity* of a file: the
--- same file reached as `lua/x.lua` from the command line and as
--- `/abs/lua/x.lua` from a workspace scan must compare equal, or it gets
--- indexed twice and every class in it duplicates against itself.
---@param path string
---@param cwd string
---@return string
function M.absolute(path, cwd)
    local normalized = M.normalize(path)
    if normalized:sub(1, 1) == "/" or normalized:match("^%a:") then
        return normalized
    end
    return M.normalize(cwd .. "/" .. normalized)
end

--- Renders an absolute path for display, relative to `base` when it is inside.
---@param path string
---@param base string
---@return string
function M.relative(path, base)
    local normalized = M.normalize(path)
    local root = M.normalize(base)
    if root ~= "/" then
        root = root .. "/"
    end
    if normalized:sub(1, #root) == root then
        return normalized:sub(#root + 1)
    end
    return normalized
end

---@param ... string
---@return string
function M.join(...)
    ---@type string[]
    local parts = { ... }
    ---@type string[]
    local out = {}
    for i = 1, #parts do
        local piece = parts[i]
        if piece and piece ~= "" then
            out[#out + 1] = (piece:gsub("/+$", ""))
        end
    end
    return M.normalize(table.concat(out, "/"))
end

---@param path string
---@return string
function M.dirname(path)
    path = M.normalize(path)
    local dir = path:match("^(.*)/[^/]*$")
    if not dir or dir == "" then
        return path:sub(1, 1) == "/" and "/" or "."
    end
    return dir
end

return M
