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
    -- The `local M = {}` module preamble. Split out of `table-decl` because the
    -- literal-or-class question it asks has no consumer for a table whose every
    -- member is a function, and off by default because that made it a fifth of
    -- every report on real code. See `analyze.is_namespace`.
    ["namespace-decl"] = "off",
    ["global-decl"] = "error",
    ["undefined-global"] = "error",
    -- functions
    ["missing-param"] = "error",
    -- Placeholders (`self`, `_`, `_a`, ...) are exempt the way LuaLS exempts
    -- them; this is the opt-in that takes the exemption away.
    ["missing-param-placeholder"] = "off",
    ["missing-vararg"] = "error",
    ["missing-return"] = "error",
    ["param-name-mismatch"] = "error",
    ["param-arity-mismatch"] = "error",
    ["duplicate-param"] = "error",
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

--- Anything positional enough to hang a diagnostic on: an AST node, a token, a
--- tag, or an ad-hoc `{ l = , c = }` pair.
--- The shape itself, for the ad-hoc `{ l = , c = }` pairs rules build inline.
---@class typer.Span
---@field l integer
---@field c integer
---@field el integer|nil
---@field ec integer|nil

--- Everything positional enough to hang a diagnostic on. LuaLS matches classes
--- by name rather than by shape, so each one has to be spelled out here even
--- though they all carry the same `l`/`c`/`ec` triple.
---@alias typer.Anchor
---| typer.Span
---| typer.Node
---| typer.Token
---| typer.Tag
---| typer.TypeNode
---| typer.Binding
---| typer.FieldEntry
---| typer.FuncInfo
---| typer.Param
---| typer.GlobalRead
---| typer.RequireSite
---| typer.TypeDecl

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
    if a.file ~= b.file then
        return a.file < b.file
    end
    if a.line ~= b.line then
        return a.line < b.line
    end
    if a.col ~= b.col then
        return a.col < b.col
    end
    return a.code < b.code
end

return M
