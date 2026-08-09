--- Declaration-index cache (spec §10.2).
---
--- The whole index is written as ONE file, precompiled with `string.dump`, so
--- loading it is `load()` at C speed with no parsing at all -- that is what
--- makes the cold-process/warm-cache path viable in pure Lua.
---
--- Bytecode is version- and architecture-specific. A mismatched binary chunk
--- can abort the interpreter outright rather than erroring cleanly, so the
--- header is checked before `load()` is ever called, and any mismatch rebuilds.
---@class typer.resolve.cache
local M = {}

local compat = require("typer.compat")
local fs = require("typer.fs")

local FORMAT_VERSION = 1

---@class typer.Cache
---@field enabled boolean
---@field dir string
---@field path string
---@field entries table<string, table>
---@field dirty boolean
---@field tag string

--- Serialises a table of plain data back to Lua source.
---@param value any
---@param out string[]
local function serialize(value, out)
  local kind = type(value)

  if kind == "string" then
    out[#out + 1] = string.format("%q", value)
  elseif kind == "number" or kind == "boolean" then
    out[#out + 1] = tostring(value)
  elseif kind == "table" then
    out[#out + 1] = "{"
    for index, item in ipairs(value) do
      if index > 1 then out[#out + 1] = "," end
      serialize(item, out)
    end
    local first = #value == 0
    for key, item in pairs(value) do
      if type(key) == "string" then
        out[#out + 1] = first and "" or ","
        first = false
        out[#out + 1] = "[" .. string.format("%q", key) .. "]="
        serialize(item, out)
      end
    end
    out[#out + 1] = "}"
  else
    out[#out + 1] = "nil"
  end
end

--- Opens the cache for a run. Disabled when `lfs` is unavailable, because
--- without a cheap stat there is no safe way to tell a stale entry from a fresh
--- one (see fs.signature).
---@param config typer.Config
---@param enabled boolean
---@return typer.Cache
function M.open(config, enabled)
  local dir = compat.join(config.root or ".", ".typer_cache")

  ---@type typer.Cache
  local cache = {
    enabled = enabled ~= false and config.cache ~= false and fs.has_lfs,
    dir = dir,
    path = compat.join(dir, "index"),
    entries = {},
    dirty = false,
    tag = compat.bytecode_tag(),
  }

  if not cache.enabled then return cache end

  local blob = compat.read_file(cache.path)
  if not blob then return cache end

  -- Header line, in plain text, read *before* any attempt to load bytecode.
  local header, body_offset = blob:match("^(typer%-cache [^\n]*)\n()")
  if not header then return cache end

  local version, tag = header:match("^typer%-cache (%d+) (.*)$")
  if tonumber(version) ~= FORMAT_VERSION or tag ~= cache.tag then
    return cache
  end

  local chunk = compat.load_binary(blob:sub(body_offset), "=typer-cache")
  if not chunk then return cache end

  local ok, data = pcall(chunk)
  if ok and type(data) == "table" then
    cache.entries = data
  end

  return cache
end

--- Returns a cached entry when its signature still matches the file on disk.
---@param cache typer.Cache
---@param path string
---@return table|nil
function M.get(cache, path)
  if not cache.enabled then return nil end

  local entry = cache.entries[path]
  if not entry then return nil end

  local signature = fs.signature(path)
  if not signature or signature ~= entry.signature then
    cache.entries[path] = nil
    cache.dirty = true
    return nil
  end

  return entry
end

---@param cache typer.Cache
---@param path string
---@param data table
function M.put(cache, path, data)
  if not cache.enabled then return end

  local signature = fs.signature(path)
  if not signature then return end

  data.signature = signature
  cache.entries[path] = data
  cache.dirty = true
end

---@param cache typer.Cache
function M.save(cache)
  if not cache.enabled or not cache.dirty then return end

  ---@type string[]
  local out = { "return " }
  serialize(cache.entries, out)

  local chunk = compat.load_string(table.concat(out), "=typer-cache")
  if not chunk then return end

  local ok, dumped = pcall(string.dump, chunk)
  if not ok then return end

  fs.mkdir_p(cache.dir)
  compat.write_file(cache.path,
    ("typer-cache %d %s\n"):format(FORMAT_VERSION, cache.tag) .. dumped)
end

return M
