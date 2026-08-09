--- typer -- `mypy --strict`, for Lua.
---
--- Reports where LuaLS type annotations are missing or too vague. Report-only:
--- it never edits files.
---@class typer
---@field VERSION string
---@field check typer.check
---@field config typer.config
---@field parser typer.parser
---@field lexer typer.lexer
---@field analyze typer.analyze
---@field registry typer.registry
---@field diagnostic typer.diagnostic
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
---@param options? typer.CheckOptions
---@return typer.Diagnostic[]
---@return typer.Summary
function M.run(paths, options)
  options = options or {}
  if not options.config then
    local fs = require("typer.fs")
    options.config = M.config.load(options.config_path, fs.cwd())
  end
  return M.check.run(paths, options)
end

return M
