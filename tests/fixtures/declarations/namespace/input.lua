--- The module preamble. Every member is a function that annotates itself, so
--- there is no data shape left for an annotation to describe.
local M = {}

--- The private-namespace convention, which never leaves the file.
local _P = {}

---@return string # Anything.
function _P.helper()
  return "x"
end

---@return string # Anything.
function M.run()
  return _P.helper()
end

--- Holds data, so its shape really is unrecovered.
local state = {}
state.count = 0

--- Nothing is known about it at all.
local opaque = {}
opaque.value = "a"

--- A namespace that also exposes data is not a pure namespace.
local mixed = {}
mixed.LIMIT = 10

---@return integer # The limit.
function mixed.limit()
  return mixed.LIMIT
end

return { M, state, opaque, mixed }
