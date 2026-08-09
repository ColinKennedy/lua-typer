--- Filesystem access.
---
--- Pure Lua cannot list a directory or stat a file, so this uses LuaFileSystem
--- when it is installed and falls back to shelling out otherwise. `lfs` is an
--- optional dependency of the rock: without it typer is slower but correct.
---@class typer.fs
local M = {}

local compat = require("typer.compat")

local ok_lfs, lfs = pcall(require, "lfs")

---@type boolean
M.has_lfs = ok_lfs and type(lfs) == "table"

---@param path string
---@return boolean
function M.is_dir(path)
    if M.has_lfs then
        local attributes = lfs.attributes(path)
        return attributes ~= nil and attributes.mode == "directory"
    end
    -- `io.open` on a directory succeeds on some platforms but reads nothing.
    local handle = io.open(path, "r")
    if not handle then
        return false
    end
    local _, _, code = handle:read(1)
    handle:close()
    return code == 21 -- EISDIR
end

---@param path string
---@return boolean
function M.is_file(path)
    if M.has_lfs then
        local attributes = lfs.attributes(path)
        return attributes ~= nil and attributes.mode == "file"
    end
    return compat.file_exists(path) and not M.is_dir(path)
end

--- Signature used to validate cache entries: `mtime:size`, one stat per file.
---
--- Returns nil without lfs, which disables caching entirely. That is
--- deliberate: the alternatives are a content hash (O(n) in pure Lua over the
--- whole tree -- slower than the parse it would save) or sampling bytes (fast
--- but silently stale on a middle-of-file edit). A slower correct run beats a
--- fast wrong one.
---@param path string
---@return string|nil
function M.signature(path)
    if not M.has_lfs then
        return nil
    end

    local attributes = lfs.attributes(path)
    if not attributes then
        return nil
    end
    return ("%d:%d"):format(attributes.modification or 0, attributes.size or 0)
end

--- Lists `*.lua` files under a directory, recursively.
---@param root string
---@return string[]
function M.list_lua(root)
    ---@type string[]
    local out = {}

    if M.has_lfs then
        ---@type string[]
        local stack = { root }
        while #stack > 0 do
            local dir = table.remove(stack)
            -- `lfs.dir` returns the iterator *and* the directory object it walks;
            -- the iterator is called with that object as its state, so dropping
            -- the second value makes the very first step error out.
            local ok, iterator, directory = pcall(lfs.dir, dir)
            if ok and iterator then
                for entry in iterator, directory do
                    if entry ~= "." and entry ~= ".." then
                        local full = compat.join(dir, entry)
                        local attributes = lfs.attributes(full)
                        if attributes then
                            if attributes.mode == "directory" then
                                stack[#stack + 1] = full
                            elseif attributes.mode == "file" and full:sub(-4) == ".lua" then
                                out[#out + 1] = full
                            end
                        end
                    end
                end
            end
        end
    else
        ---@type string
        local command
        if compat.is_windows then
            command = ('dir /b /s "%s\\*.lua" 2>nul'):format(root:gsub("/", "\\"))
        else
            command = ("find %q -name '*.lua' -type f 2>/dev/null"):format(root)
        end
        local pipe = io.popen(command)
        if pipe then
            for line in pipe:lines() do
                if line ~= "" then
                    out[#out + 1] = compat.normalize(line)
                end
            end
            pipe:close()
        end
    end

    table.sort(out)
    return out
end

---@param path string
---@return boolean
function M.mkdir_p(path)
    if M.has_lfs then
        local accumulated = ""
        for piece in path:gmatch("[^/]+") do
            accumulated = accumulated == "" and (path:sub(1, 1) == "/" and "/" .. piece or piece)
                or accumulated .. "/" .. piece
            if not M.is_dir(accumulated) then
                lfs.mkdir(accumulated)
            end
        end
        return M.is_dir(path)
    end

    local command = compat.is_windows and ('mkdir "%s" 2>nul'):format(path:gsub("/", "\\"))
        or ("mkdir -p %q 2>/dev/null"):format(path)
    os.execute(command)
    return true
end

---@return string
function M.cwd()
    if M.has_lfs then
        return compat.normalize(lfs.currentdir())
    end
    local pipe = io.popen(compat.is_windows and "cd" or "pwd")
    if not pipe then
        return "."
    end
    local dir = pipe:read("*l")
    pipe:close()
    return compat.normalize(dir or ".")
end

return M
