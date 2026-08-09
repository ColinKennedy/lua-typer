--- typer -- `mypy --strict`, for Lua.
---
--- Reports where LuaLS type annotations are missing or too vague. Report-only:
--- it never edits files.
---@class typer
local M = {}

M.VERSION = "0.1.0"

M.check = require("typer.check")
M.config = require("typer.config")
M.parser = require("typer.parser")
M.lexer = require("typer.lexer")
M.analyze = require("typer.analyze")
M.registry = require("typer.registry")
M.diagnostic = require("typer.diagnostic")

--- Convenience wrapper: check paths with default configuration.
---@param paths string[]
---@param options? table
---@return typer.Diagnostic[]
---@return table
function M.run(paths, options)
  options = options or {}
  if not options.config then
    local fs = require("typer.fs")
    options.config = M.config.load(options.config_path, fs.cwd())
  end
  return M.check.run(paths, options)
end

return M
