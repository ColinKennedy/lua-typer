---@meta
--- Lua 5.4 standard library definitions.
---
--- Differs from 5.1 by design: no `getfenv`/`setfenv`/`loadstring`/`unpack`/
--- `module`/`newproxy`, and `warn`/`rawlen` are added. Selecting the wrong
--- `--lua-version` should therefore produce real `undefined-global` reports.

---@type table<string, any>
_G = {}

---@type string
_VERSION = ""

---@generic T
---@param v T
---@param message? any
---@return T
function assert(v, message) end

---@param opt? string
---@param arg? number
---@return any
function collectgarbage(opt, arg) end

---@param filename? string
---@return any
function dofile(filename) end

---@param message any
---@param level? integer
function error(message, level) end

---@param object any
---@return table|nil
function getmetatable(object) end

---@generic K, V
---@param t table<K, V>
---@return fun(t: table<K, V>, k: K|nil): K, V
---@return table<K, V>
---@return nil
function ipairs(t) end

---@param chunk string|function
---@param chunkname? string
---@param mode? string
---@param env? table
---@return function|nil
---@return string|nil
function load(chunk, chunkname, mode, env) end

---@param filename? string
---@param mode? string
---@param env? table
---@return function|nil
---@return string|nil
function loadfile(filename, mode, env) end

---@generic K, V
---@param t table<K, V>
---@param index? K
---@return K|nil
---@return V|nil
function next(t, index) end

---@generic K, V
---@param t table<K, V>
---@return fun(t: table<K, V>, k: K|nil): K, V
---@return table<K, V>
---@return nil
function pairs(t) end

---@param f function
---@param ... any
---@return boolean
---@return any
function pcall(f, ...) end

---@param ... any
function print(...) end

---@param v1 any
---@param v2 any
---@return boolean
function rawequal(v1, v2) end

---@param t table
---@param index any
---@return any
function rawget(t, index) end

---@param v table|string
---@return integer
function rawlen(v) end

---@param t table
---@param index any
---@param value any
---@return table
function rawset(t, index, value) end

---@param modname string
---@return any
---@return any
function require(modname) end

---@param index integer|string
---@param ... any
---@return any
function select(index, ...) end

---@generic T
---@param t T
---@param metatable table|nil
---@return T
function setmetatable(t, metatable) end

---@param e any
---@param base? integer
---@return number|nil
function tonumber(e, base) end

---@param v any
---@return string
function tostring(v) end

---@param v any
---@return string
function type(v) end

---@param ... string
function warn(...) end

---@param f function
---@param msgh function
---@param ... any
---@return boolean
---@return any
function xpcall(f, msgh, ...) end

---@type string[]
arg = {}
