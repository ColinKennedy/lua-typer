--- `-- typer: ignore` suppression comments (spec §4).
---
--- Deliberately a *plain* comment rather than a doc comment: a `---@typer-ignore`
--- tag would show up as an unknown tag to lua-language-server itself.
---
--- Three forms, each covering a different span:
---
---   -- typer: ignore              the next statement, whole -- or the statement
---                                 it trails, when it shares a line with code
---   -- typer: ignore-next-line    the next line that has code on it
---   -- typer: ignore-file         every line in the file
---
--- Each narrows to a code list when given one, bracketed or bare:
---
---   -- typer: ignore[disallowed-any]
---   -- typer: ignore[disallowed-any, vague-table]
---   -- typer: ignore disallowed-any, vague-table
---
--- With no list, the comment silences every code.
---
--- Every directive records what it actually silenced, which is what lets
--- `unused-ignore` point at the ones silencing nothing. There is no baseline
--- file and never will be (spec §5): these per-site, visible-in-source comments
--- are the only suppression mechanism, and a stale one is a defect like any
--- other -- an ignore nobody can see the reason for is exactly the rot a
--- baseline would have institutionalised.
---@class typer.suppress
local M = {}

local diagnostic = require("typer.diagnostic")

--- The forms, longest first: `ignore` is a prefix of the other two, so a
--- shortest-first scan would classify every one of them as `ignore`.
---@type string[]
local FORMS = { "ignore-file", "ignore-next-line", "ignore" }

--- One suppression comment: the lines it covers, the codes it silences (nil for
--- every code), and what it turned out to silence.
---@class typer.SuppressDirective
---@field l integer
---@field c integer
---@field el integer
---@field ec integer
---@field form string                        -- "ignore" | "ignore-next-line" | "ignore-file"
---@field whole_file boolean
---@field from integer                       -- first covered line, unused when whole_file
---@field to integer                         -- last covered line, unused when whole_file
---@field codes string[]|nil                 -- nil silences every code
---@field code_set table<string, boolean>|nil
---@field used table<string, boolean>        -- codes that silenced at least one diagnostic
---@field matched boolean                    -- silenced anything at all

---@class typer.Suppressions
---@field directives typer.SuppressDirective[]

---@param text string
---@return string
local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Splits `ignore-file` / `ignore-next-line` / `ignore` off the front of a
--- directive body. The remainder has to start where a code list could, so
--- `ignoreable` is prose rather than a malformed directive.
---@param body string
---@return string|nil form
---@return string|nil rest
local function parse_form(body)
    for _, form in ipairs(FORMS) do
        if body:sub(1, #form) == form then
            local rest = body:sub(#form + 1)
            if rest == "" or rest:sub(1, 1) == "[" or rest:match("^%s") then
                return form, rest
            end
        end
    end
    return nil, nil
end

--- Reads a code list in either spelling, or nil when the comment names none and
--- so suppresses everything.
---@param rest string
---@return string[]|nil
local function parse_codes(rest)
    local trimmed = trim(rest)
    if trimmed == "" then
        return nil
    end

    -- An unclosed `[` is read as if it closed: the codes are still legible, and
    -- a stricter reading would only turn a typo into silent full suppression.
    local inner = trimmed:match("^%[(.*)%]$") or trimmed:match("^%[(.*)$") or trimmed

    ---@type string[]
    local codes = {}
    ---@type table<string, boolean>
    local seen = {}
    for code in inner:gmatch("[%w%-]+") do
        if not seen[code] then
            seen[code] = true
            codes[#codes + 1] = code
        end
    end

    if #codes == 0 then
        return nil
    end
    return codes
end

---@param codes string[]|nil
---@return table<string, boolean>|nil
local function code_set(codes)
    if not codes then
        return nil
    end
    ---@type table<string, boolean>
    local set = {}
    for _, code in ipairs(codes) do
        set[code] = true
    end
    return set
end

--- Finds the statement a suppression comment applies to.
---@param statements typer.StatementSpan[]
---@param line integer
---@return typer.StatementSpan|nil
local function statement_after(statements, line)
    ---@type typer.StatementSpan|nil
    local best = nil
    for _, span in ipairs(statements) do
        if span.l > line and (not best or span.l < best.l) then
            best = span
        end
    end
    return best
end

---@param statements typer.StatementSpan[]
---@param line integer
---@return typer.StatementSpan|nil
local function statement_on(statements, line)
    ---@type typer.StatementSpan|nil
    local best = nil
    for _, span in ipairs(statements) do
        if span.l <= line and span.el >= line then
            if not best or span.l > best.l then
                best = span
            end
        end
    end
    return best
end

--- Where a target's suppression range starts: its own line, unless a doc block
--- sits directly above it, in which case that block's first line.
---
--- The block has to be inside the range because most of what typer reports is
--- anchored on a *tag* -- `---@return any` is a `disallowed-any` at the tag's
--- own line and column, above the statement it documents. A directive cannot
--- simply be written closer, either: a plain `--` line in the middle of a `---`
--- run severs it, and the statement loses every annotation below the cut (see
--- `docblock.build`). Above the block is the only place a directive can go, so
--- that is the place it has to work from.
---@param docs typer.DocIndex
---@param line integer
---@return integer
local function block_start(docs, line)
    local block = docs.by_end[line - 1]
    if block then
        return block.l
    end
    return line
end

--- The next line carrying code, skipping blanks and comments.
---@param code_lines table<integer, boolean>
---@param after integer
---@return integer
local function next_code_line(code_lines, after)
    ---@type integer|nil
    local best = nil
    for line in pairs(code_lines) do
        if line > after and (not best or line < best) then
            best = line
        end
    end
    return best or (after + 1)
end

--- A comment's directive body, and the source column the `--` opening it sits
--- at. Nil for ordinary prose.
---
--- A directive can also trail an *annotation*, inside the `---` line itself:
---
---   ---@field value any  -- typer: ignore[disallowed-any]
---
--- which is not a nicety. Half of what typer reports is anchored on a tag, and
--- a tag inside a doc block has nowhere else to take a directive: a plain `--`
--- on its own line mid-run severs the block and everything below the cut stops
--- annotating the statement (see `docblock.build`). Writing it above the whole
--- block is the alternative, and on a twenty-field `---@class` that is nowhere
--- near the field it is about.
---
--- Only a line that *is* an annotation is scanned, never a prose line of the
--- block. Documentation that mentions the syntax is the common case here --
--- this very comment is one -- and a `---` description that talks about
--- `-- typer: ignore` must not thereby become one.
---@param comment typer.Comment
---@return string|nil body
---@return integer|nil column
local function directive_body(comment)
    if not comment.doc then
        local body = comment.text:match("^%s*typer%s*:%s*(.*)$")
        if not body then
            return nil, nil
        end
        return body, comment.c
    end

    -- The tag sigil exactly as `tags.parse_line` reads it.
    if not comment.text:match("^%s*@[%a_][%w_]*") then
        return nil, nil
    end

    local start, _, body = comment.text:find("%-%-%s*typer%s*:%s*(.*)$")
    if not body or not start then
        return nil, nil
    end

    -- `text` begins one past the `---`, so a 1-based index into it maps to a
    -- source column by adding the two dashes it does not cover.
    return body, comment.c + 2 + start
end

--- Reads one comment as a directive, or nil when it is ordinary prose.
---@param comment typer.Comment
---@param model typer.FileModel
---@param doc_lines table<integer, boolean>
---@return typer.SuppressDirective|nil
local function directive_of(comment, model, doc_lines)
    local body, column = directive_body(comment)
    if not body or not column then
        return nil
    end

    local form, rest = parse_form(trim(body))
    if not form or not rest then
        return nil
    end

    local codes = parse_codes(rest)
    ---@type typer.SuppressDirective
    local directive = {
        l = comment.l,
        c = column,
        el = comment.el,
        ec = comment.ec,
        form = form,
        whole_file = form == "ignore-file",
        from = comment.l,
        to = comment.l,
        codes = codes,
        code_set = code_set(codes),
        used = {},
        matched = false,
    }

    local statements = model.statements or {}
    local code_lines = model.docs.code_lines

    if comment.doc then
        -- Trailing an annotation, the directive covers that annotation's line
        -- and nothing else -- it is written next to the tag precisely because
        -- that tag is the thing it is about. `ignore-next-line` still steps
        -- one line down, which inside a doc block is the next tag; there are
        -- no blanks or comments to skip over in the middle of a `---` run.
        if form == "ignore-next-line" then
            directive.from, directive.to = comment.l + 1, comment.l + 1
        end
        return directive
    end

    if form == "ignore-next-line" then
        if doc_lines[comment.l + 1] then
            -- Written inside a doc block, where the next line is the next
            -- annotation. That tag is the whole reason the directive is here,
            -- so it is the whole range: reaching down to the statement as well
            -- would silence tags the author never pointed at.
            directive.from, directive.to = comment.l + 1, comment.l + 1
        else
            local line = next_code_line(code_lines, comment.l)
            directive.from, directive.to = block_start(model.docs, line), line
        end
    elseif form == "ignore" then
        local on_line = statement_on(statements, comment.l)
        if on_line and code_lines[comment.l] then
            -- Trailing form: applies to the statement it shares a line with.
            directive.from, directive.to = block_start(model.docs, on_line.l), on_line.el
        else
            local target = statement_after(statements, comment.l)
            if target then
                directive.from, directive.to = block_start(model.docs, target.l), target.el
            end
            -- Otherwise it keeps its own line, which is the only sensible
            -- reading of a directive with nothing after it.
        end
    end

    return directive
end

--- Collects suppressions from a chunk's plain comments.
---@param chunk typer.Chunk
---@param model typer.FileModel
---@return typer.Suppressions
function M.collect(chunk, model)
    ---@type typer.Suppressions
    local result = { directives = {} }

    ---@type table<integer, boolean>
    local doc_lines = {}
    for _, comment in ipairs(chunk.comments) do
        if comment.doc then
            for line = comment.l, comment.el do
                doc_lines[line] = true
            end
        end
    end

    for _, comment in ipairs(chunk.comments) do
        local directive = directive_of(comment, model, doc_lines)
        if directive then
            result.directives[#result.directives + 1] = directive
        end
    end

    return result
end

--- Records a hit and reports whether the directive covers the diagnostic.
---@param directive typer.SuppressDirective
---@param diag typer.Diagnostic
---@return boolean
local function claims(directive, diag)
    if not directive.whole_file and (diag.line < directive.from or diag.line > directive.to) then
        return false
    end

    if not directive.code_set then
        directive.matched = true
        return true
    end

    if directive.code_set[diag.code] then
        directive.matched = true
        directive.used[diag.code] = true
        return true
    end

    return false
end

--- True when a comment is a directive rather than prose.
---
--- `docblock.build` needs this, and is the reason it is public: a plain `--`
--- line in the middle of a `---` run normally severs the run, but a directive
--- is metadata *about* the block rather than prose between two of them. Left
--- to sever, writing a directive next to the tag it is about would silently
--- cost the statement every annotation above the directive -- trading the
--- diagnostic you meant to silence for two you did not.
---@param comment typer.Comment
---@return boolean
function M.is_directive(comment)
    local body = directive_body(comment)
    if not body then
        return false
    end
    return parse_form(trim(body)) ~= nil
end

---@param suppressions typer.Suppressions
---@param diag typer.Diagnostic
---@return boolean
function M.is_suppressed(suppressions, diag)
    -- Every directive is asked, not just the first to answer yes: two comments
    -- covering the same diagnostic are both doing their job, and stopping early
    -- would report the second one as unused.
    local suppressed = false
    for _, directive in ipairs(suppressions.directives) do
        if claims(directive, diag) then
            suppressed = true
        end
    end
    return suppressed
end

--- `'a'`, `'a' or 'b'`, `'a', 'b' or 'c'`.
---@param codes string[]
---@param conjunction string
---@return string
local function quote_list(codes, conjunction)
    ---@type string[]
    local parts = {}
    for _, code in ipairs(codes) do
        parts[#parts + 1] = ("'%s'"):format(code)
    end
    if #parts == 1 then
        return parts[1]
    end
    return table.concat(parts, ", ", 1, #parts - 1) .. " " .. conjunction .. " " .. parts[#parts]
end

--- Diagnostics for the directives that silenced nothing.
---
--- Call it only once every diagnostic has been offered to `is_suppressed`:
--- until then a live directive is indistinguishable from a stale one.
---@param suppressions typer.Suppressions
---@param file string
---@return typer.Diagnostic[]
function M.unused(suppressions, file)
    ---@type typer.Diagnostic[]
    local out = {}

    for _, directive in ipairs(suppressions.directives) do
        local label = ("`-- typer: %s`"):format(directive.form)

        if not directive.codes then
            if not directive.matched then
                out[#out + 1] = diagnostic.new(
                    file,
                    directive,
                    "unused-ignore",
                    ("%s suppresses nothing"):format(label),
                    "remove it"
                )
            end
        else
            ---@type string[]
            local dead = {}
            ---@type string[]
            local unknown = {}
            for _, code in ipairs(directive.codes) do
                if not directive.used[code] then
                    if diagnostic.DEFAULT_SEVERITY[code] then
                        dead[#dead + 1] = code
                    else
                        unknown[#unknown + 1] = code
                    end
                end
            end

            ---@type string[]
            local reasons = {}
            if #dead > 0 then
                reasons[#reasons + 1] = ("no %s diagnostic here"):format(quote_list(dead, "or"))
            end
            if #unknown > 0 then
                reasons[#reasons + 1] = ("%s %s not a typer diagnostic code"):format(
                    quote_list(unknown, "and"),
                    #unknown == 1 and "is" or "are"
                )
            end

            if #reasons > 0 then
                out[#out + 1] = diagnostic.new(
                    file,
                    directive,
                    "unused-ignore",
                    ("%s suppresses nothing: %s"):format(label, table.concat(reasons, "; ")),
                    #unknown > 0 and "check the spelling, or remove it" or "remove it"
                )
            end
        end
    end

    return out
end

return M
