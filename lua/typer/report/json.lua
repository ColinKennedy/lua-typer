--- JSON reporter (spec §7).
---@class typer.report.json
local M = {}

local json = require("typer.json")

---@param diagnostics typer.Diagnostic[]
---@param summary typer.Summary
---@return string
function M.render(diagnostics, summary)
  ---@type typer.Diagnostic[]
  local entries = {}

  for index, diag in ipairs(diagnostics) do
    entries[index] = {
      file = diag.file,
      line = diag.line,
      col = diag.col,
      end_line = diag.end_line,
      end_col = diag.end_col,
      code = diag.code,
      severity = diag.severity,
      message = diag.message,
      suggestion = diag.suggestion,
    }
  end

  return json.encode({
    version = 1,
    diagnostics = entries,
    summary = {
      files = summary.files or 0,
      indexed = summary.indexed or 0,
      errors = summary.errors or 0,
      warnings = summary.warnings or 0,
      hints = summary.hints or 0,
    },
  }) .. "\n"
end

return M
