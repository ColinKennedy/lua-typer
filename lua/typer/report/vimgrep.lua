--- vimgrep reporter (spec §7).
---
--- `<path>:<line>:<col>: <severity>: [<code>] <message>` matches vim's default
--- errorformat (`%f:%l:%c:%m`), so `:cexpr`, nvim-lint and null-ls consume it
--- with no custom parser.
---@class typer.report.vimgrep
local M = {}

--- `_summary` is part of the reporter signature, but vimgrep output is one
--- line per diagnostic and nothing else: a trailing count would not parse.
---@param diagnostics typer.Diagnostic[]
---@param _summary typer.Summary
---@return string
function M.render(diagnostics, _summary)
    ---@type string[]
    local lines = {}

    for _, diag in ipairs(diagnostics) do
        lines[#lines + 1] = ("%s:%d:%d: %s: [%s] %s"):format(
            diag.file,
            diag.line,
            diag.col,
            diag.severity,
            diag.code,
            diag.message
        )
    end

    return table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
end

return M
