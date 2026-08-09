---@class app.helpers
local M = {}

---@param buffer integer The buffer to inspect.
---@return string # The project root.
function M.get_root(buffer)
  return tostring(buffer)
end

---@param command string The command to look for.
---@return boolean # Whether it exists.
function M.exists_command(command)
  return #command > 0
end

--- Declared with no annotations, so it declares no signature to inherit.
function M.undocumented(value)
  return value
end

return M
