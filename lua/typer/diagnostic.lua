--- Diagnostic construction and the code registry.
---@class typer.diagnostic
local M = {}

--- Every code typer can emit, with its default severity. Codes are stable:
--- they appear in output, in config, and in `-- typer: ignore <code>`.
---@type table<string, string>
M.DEFAULT_SEVERITY = {
  -- declarations
  ["bare-decl"] = "error",
  ["nil-decl"] = "error",
  ["table-decl"] = "error",
  ["global-decl"] = "error",
  ["undefined-global"] = "error",
  -- functions
  ["missing-param"] = "error",
  ["missing-vararg"] = "error",
  ["missing-return"] = "error",
  ["param-name-mismatch"] = "error",
  ["param-arity-mismatch"] = "error",
  ["return-arity-mismatch"] = "error",
  ["self-param"] = "error",
  ["optional-param"] = "off",
  ["optional-return"] = "off",
  -- classes
  ["missing-class"] = "error",
  ["missing-field"] = "error",
  ["missing-inherit"] = "error",
  -- type completeness
  ["vague-table"] = "error",
  ["vague-function"] = "error",
  ["disallowed-any"] = "error",
  ["disallowed-unknown"] = "error",
  ["unresolved-type"] = "error",
  -- resolution
  ["unresolved-module"] = "error",
  ["untyped-module"] = "error",
  ["duplicate-class"] = "error",
  -- tool
  ["parse-error"] = "error",
  ["annotation-syntax"] = "error",
}

---@type table<string, integer>
M.SEVERITY_RANK = { error = 3, warning = 2, hint = 1, off = 0 }

--- Anything positional enough to hang a diagnostic on: an AST node, a token, a
--- tag, or an ad-hoc `{ l = , c = }` pair.
---@class typer.Anchor
---@field l integer
---@field c integer
---@field el integer|nil
---@field ec integer|nil

---@class typer.Diagnostic
---@field file string
---@field line integer
---@field col integer
---@field end_line integer
---@field end_col integer
---@field code string
---@field severity string
---@field message string
---@field suggestion string|nil

--- Builds a diagnostic anchored at a node or position table.
---@param file string
---@param anchor typer.Anchor    -- anything with l/c and optionally el/ec
---@param code string
---@param message string
---@param suggestion? string
---@return typer.Diagnostic
function M.new(file, anchor, code, message, suggestion)
  local line = anchor.l or 1
  local col = anchor.c or 1
  return {
    file = file,
    line = line,
    col = col,
    end_line = anchor.el or line,
    end_col = anchor.ec or (col + 1),
    code = code,
    severity = M.DEFAULT_SEVERITY[code] or "error",
    message = message,
    suggestion = suggestion,
  }
end

--- Orders diagnostics for stable output: by file, then position, then code.
---@param a typer.Diagnostic
---@param b typer.Diagnostic
---@return boolean
function M.compare(a, b)
  if a.file ~= b.file then return a.file < b.file end
  if a.line ~= b.line then return a.line < b.line end
  if a.col ~= b.col then return a.col < b.col end
  return a.code < b.code
end

return M
