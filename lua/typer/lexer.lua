--- Hand-rolled Lua lexer covering the union of 5.1/LuaJIT and 5.4 syntax.
---
--- Hot path: `string.byte` and numeric `for`, never per-character `string.sub`.
--- Comments are not discarded -- annotations live in them -- but they are kept
--- out of the token stream so the parser never has to skip them.
---@class typer.lexer
local M = {}

local byte, sub, find = string.byte, string.sub, string.find

local B_NEWLINE, B_RETURN, B_SPACE, B_TAB = 10, 13, 32, 9
local B_VTAB, B_FORMFEED = 11, 12
local B_DASH, B_LBRACKET, B_EQ = 45, 91, 61
local B_QUOTE, B_DQUOTE, B_BACKSLASH = 39, 34, 92
local B_DOT, B_ZERO, B_NINE = 46, 48, 57
local B_a, B_z, B_A, B_Z, B_UNDERSCORE = 97, 122, 65, 90, 95
local B_x, B_X = 120, 88

---@type table<string, boolean>
local KEYWORDS = {}
for word in
    (
        "and break do else elseif end false for function goto if in local "
        .. "nil not or repeat return then true until while"
    ):gmatch("%S+")
do
    KEYWORDS[word] = true
end

--- Multi-byte operators, longest first. Single-byte operators fall through to a
--- membership test so the table stays small.
---@type table<string, boolean>
local OPS3 = { ["..."] = true }
---@type table<string, boolean>
local OPS2 = {
    [".."] = true,
    ["=="] = true,
    ["~="] = true,
    ["<="] = true,
    [">="] = true,
    ["::"] = true,
    ["<<"] = true,
    [">>"] = true,
    ["//"] = true,
}
---@type table<string, boolean>
local OPS1 = {}
for char in ("+-*/%^#&~|<>=(){}[];:,."):gmatch(".") do
    OPS1[char] = true
end

---@class typer.Token
---@field t "name"|"number"|"string"|"keyword"|"op"|"eof"
---@field v string          -- raw lexeme for ops/names/keywords; decoded value for strings
---@field l integer         -- 1-based start line
---@field c integer         -- 1-based start column, in bytes
---@field el integer        -- 1-based end line
---@field ec integer        -- 1-based end column, in bytes (exclusive)

---@class typer.Comment
---@field text string       -- comment body, with the leading `--`/`---` stripped
---@field doc boolean       -- true when the comment opened with exactly `---`
---@field long boolean      -- true for `--[[ ]]` form
---@field l integer
---@field c integer
---@field el integer
---@field ec integer

---@class typer.LexError
---@field typer_error true
---@field kind "lex"
---@field msg string
---@field l integer
---@field c integer

---@class typer.LexResult
---@field tokens typer.Token[]
---@field comments typer.Comment[]

---@class typer.LexState
---@field src string
---@field pos integer
---@field line integer
---@field line_start integer   -- byte offset of the current line's first character
---@field len integer
---@field tokens typer.Token[]
---@field comments typer.Comment[]

---@param state typer.LexState
---@param msg string
---@param pos? integer
local function fail(state, msg, pos)
    pos = pos or state.pos
    error({
        typer_error = true,
        kind = "lex",
        msg = msg,
        l = state.line,
        c = pos - state.line_start + 1,
    }, 0)
end

---@param state typer.LexState
---@param pos integer
---@return integer
local function column(state, pos)
    return pos - state.line_start + 1
end

---@param b integer|nil
---@return boolean
local function is_digit(b)
    return b ~= nil and b >= B_ZERO and b <= B_NINE
end

---@param b integer|nil
---@return boolean
local function is_hex(b)
    if b == nil then
        return false
    end
    return (b >= B_ZERO and b <= B_NINE) or (b >= 97 and b <= 102) or (b >= 65 and b <= 70)
end

---@param b integer|nil
---@return boolean
local function is_name_start(b)
    if b == nil then
        return false
    end
    return (b >= B_a and b <= B_z) or (b >= B_A and b <= B_Z) or b == B_UNDERSCORE
end

---@param b integer|nil
---@return boolean
local function is_name_part(b)
    return is_name_start(b) or is_digit(b)
end

--- Consumes a newline, handling `\n`, `\r`, `\r\n` and `\n\r`.
---@param state typer.LexState
local function newline(state)
    local src, pos = state.src, state.pos
    local first = byte(src, pos)
    state.pos = pos + 1
    local second = byte(src, state.pos)
    if (second == B_NEWLINE or second == B_RETURN) and second ~= first then
        state.pos = state.pos + 1
    end
    state.line = state.line + 1
    state.line_start = state.pos
end

--- Measures a long-bracket opener at `pos`. Returns the `=` count, or nil.
---@param state typer.LexState
---@param pos integer
---@return integer|nil level
---@return integer|nil body_start
local function long_bracket_level(state, pos)
    if byte(state.src, pos) ~= B_LBRACKET then
        return nil
    end
    local probe = pos + 1
    while byte(state.src, probe) == B_EQ do
        probe = probe + 1
    end
    if byte(state.src, probe) ~= B_LBRACKET then
        return nil
    end
    return probe - pos - 1, probe + 1
end

--- Reads a long-bracket body `[[...]]` / `[==[...]==]`, already past the opener.
---@param state typer.LexState
---@param level integer
---@param what string
---@return string
local function read_long_body(state, level, what)
    local closer = "]" .. string.rep("=", level) .. "]"
    -- A newline immediately after the opener is dropped, per the reference manual.
    local b = byte(state.src, state.pos)
    if b == B_NEWLINE or b == B_RETURN then
        newline(state)
    end

    local body_start = state.pos
    local found = find(state.src, closer, state.pos, true)
    if not found then
        fail(state, "unfinished " .. what)
    end

    -- Walk the body to keep line accounting correct.
    local scan = state.pos
    while scan < found do
        local c = byte(state.src, scan)
        if c == B_NEWLINE or c == B_RETURN then
            state.pos = scan
            newline(state)
            scan = state.pos
        else
            scan = scan + 1
        end
    end

    local body = sub(state.src, body_start, found - 1)
    state.pos = found + #closer
    return body
end

---@type table<integer, string>
local SIMPLE_ESCAPES = {
    [97] = "\a",
    [98] = "\b",
    [102] = "\f",
    [110] = "\n",
    [114] = "\r",
    [116] = "\t",
    [118] = "\v",
    [B_BACKSLASH] = "\\",
    [B_QUOTE] = "'",
    [B_DQUOTE] = '"',
}

--- Reads a quoted string, decoding escapes. The decoded value matters because
--- `require("a.b")` argument text drives module resolution.
---@param state typer.LexState
---@return string
local function read_quoted(state)
    local src = state.src
    local quote = byte(src, state.pos)
    state.pos = state.pos + 1

    ---@type string[]
    local pieces = {}
    local n = 0
    while true do
        local b = byte(src, state.pos)
        if b == nil then
            fail(state, "unfinished string")
        end
        if b == quote then
            state.pos = state.pos + 1
            break
        elseif b == B_NEWLINE or b == B_RETURN then
            fail(state, "unfinished string")
        elseif b == B_BACKSLASH then
            state.pos = state.pos + 1
            local e = byte(src, state.pos)
            if e == nil then
                fail(state, "unfinished string")
            end
            local simple = SIMPLE_ESCAPES[e]
            if simple then
                n = n + 1
                pieces[n] = simple
                state.pos = state.pos + 1
            elseif e == B_NEWLINE or e == B_RETURN then
                newline(state)
                n = n + 1
                pieces[n] = "\n"
            elseif e == 120 or e == 88 then -- \xXX
                local hex = sub(src, state.pos + 1, state.pos + 2)
                if not hex:match("^%x%x$") then
                    fail(state, "hexadecimal digit expected")
                end
                n = n + 1
                pieces[n] = string.char(tonumber(hex, 16))
                state.pos = state.pos + 3
            elseif e == 122 then -- \z skips following whitespace
                state.pos = state.pos + 1
                while true do
                    local w = byte(src, state.pos)
                    if w == B_NEWLINE or w == B_RETURN then
                        newline(state)
                    elseif w == B_SPACE or w == B_TAB or w == B_VTAB or w == B_FORMFEED then
                        state.pos = state.pos + 1
                    else
                        break
                    end
                end
            elseif e == 117 then -- \u{XXX}
                local closing = find(src, "}", state.pos, true)
                if not closing then
                    fail(state, "missing '}' in \\u{xxxx}")
                end
                -- Value is irrelevant to typer; preserve a placeholder byte.
                n = n + 1
                pieces[n] = "?"
                state.pos = closing + 1
            elseif is_digit(e) then -- \ddd
                local digits = 0
                local value = 0
                while digits < 3 and is_digit(byte(src, state.pos)) do
                    value = value * 10 + (byte(src, state.pos) - B_ZERO)
                    state.pos = state.pos + 1
                    digits = digits + 1
                end
                if value > 255 then
                    fail(state, "decimal escape too large")
                end
                n = n + 1
                pieces[n] = string.char(value)
            else
                fail(state, "invalid escape sequence")
            end
        else
            -- Fast path: consume a run of ordinary bytes in one slice.
            local run = state.pos
            repeat
                run = run + 1
                local c = byte(src, run)
            until c == nil or c == quote or c == B_BACKSLASH or c == B_NEWLINE or c == B_RETURN
            n = n + 1
            pieces[n] = sub(src, state.pos, run - 1)
            state.pos = run
        end
    end

    return table.concat(pieces, "", 1, n)
end

--- Reads a numeral. typer never evaluates numbers, so this only has to find the
--- correct end of the lexeme -- including LuaJIT's `LL`/`ULL`/`i` suffixes.
---@param state typer.LexState
---@return string
local function read_number(state)
    local src = state.src
    local start = state.pos
    local is_hex_literal = false

    if byte(src, state.pos) == B_ZERO then
        local next_b = byte(src, state.pos + 1)
        if next_b == B_x or next_b == B_X then
            is_hex_literal = true
            state.pos = state.pos + 2
        end
    end

    local exp_lower, exp_upper = 101, 69 -- e, E
    if is_hex_literal then
        exp_lower, exp_upper = 112, 80
    end -- p, P

    while true do
        local b = byte(src, state.pos)
        if b == nil then
            break
        end
        if b == exp_lower or b == exp_upper then
            state.pos = state.pos + 1
            local sign = byte(src, state.pos)
            if sign == 43 or sign == B_DASH then
                state.pos = state.pos + 1
            end
        elseif b == B_DOT or (is_hex_literal and is_hex(b)) or (not is_hex_literal and is_digit(b)) then
            state.pos = state.pos + 1
        elseif not is_hex_literal and (b == 120 or b == 88) then
            state.pos = state.pos + 1
        else
            break
        end
    end

    -- LuaJIT integer suffixes.
    local tail = sub(src, state.pos, state.pos + 2):upper()
    if tail:sub(1, 3) == "ULL" then
        state.pos = state.pos + 3
    elseif tail:sub(1, 2) == "LL" then
        state.pos = state.pos + 2
    elseif tail:sub(1, 1) == "I" then
        state.pos = state.pos + 1
    end

    if is_name_start(byte(src, state.pos)) then
        fail(state, "malformed number")
    end

    return sub(src, start, state.pos - 1)
end

--- Tokenises `src`.
---@param src string
---@return typer.LexResult
---@return typer.LexError|nil
function M.lex(src)
    -- Strip a leading shebang; `bin/typer` and many scripts have one.
    if sub(src, 1, 1) == "#" then
        local stop = find(src, "\n", 1, true)
        src = stop and (string.rep(" ", stop - 1) .. sub(src, stop)) or ""
    end

    ---@type typer.LexState
    local state = {
        src = src,
        pos = 1,
        line = 1,
        line_start = 1,
        len = #src,
        tokens = {},
        comments = {},
    }

    local ok, err = pcall(function()
        local tokens, comments = state.tokens, state.comments
        local tn, cn = 0, 0

        while state.pos <= state.len do
            local b = byte(src, state.pos)

            if b == B_NEWLINE or b == B_RETURN then
                newline(state)
            elseif b == B_SPACE or b == B_TAB or b == B_VTAB or b == B_FORMFEED then
                state.pos = state.pos + 1
            elseif b == B_DASH and byte(src, state.pos + 1) == B_DASH then
                local start_line, start_col = state.line, column(state, state.pos)
                state.pos = state.pos + 2

                local level, body_start = long_bracket_level(state, state.pos)
                if level then
                    state.pos = body_start
                    local text = read_long_body(state, level, "long comment")
                    cn = cn + 1
                    comments[cn] = {
                        text = text,
                        doc = false,
                        long = true,
                        l = start_line,
                        c = start_col,
                        el = state.line,
                        ec = column(state, state.pos),
                    }
                else
                    -- A doc comment is exactly three dashes: `---`, not `----`.
                    local third = byte(src, state.pos)
                    local fourth = byte(src, state.pos + 1)
                    local is_doc = third == B_DASH and fourth ~= B_DASH

                    local stop = find(src, "[\n\r]", state.pos)
                    local text_start = is_doc and state.pos + 1 or state.pos
                    local text_end = (stop or state.len + 1) - 1
                    cn = cn + 1
                    comments[cn] = {
                        text = sub(src, text_start, text_end),
                        doc = is_doc,
                        long = false,
                        l = start_line,
                        c = start_col,
                        el = start_line,
                        ec = column(state, text_end + 1),
                    }
                    state.pos = text_end + 1
                end
            elseif is_name_start(b) then
                local start = state.pos
                local start_col = column(state, start)
                repeat
                    state.pos = state.pos + 1
                until not is_name_part(byte(src, state.pos))
                local word = sub(src, start, state.pos - 1)
                tn = tn + 1
                tokens[tn] = {
                    t = KEYWORDS[word] and "keyword" or "name",
                    v = word,
                    l = state.line,
                    c = start_col,
                    el = state.line,
                    ec = column(state, state.pos),
                }
            elseif is_digit(b) or (b == B_DOT and is_digit(byte(src, state.pos + 1))) then
                local start_col = column(state, state.pos)
                local start_line = state.line
                local text = read_number(state)
                tn = tn + 1
                tokens[tn] = {
                    t = "number",
                    v = text,
                    l = start_line,
                    c = start_col,
                    el = state.line,
                    ec = column(state, state.pos),
                }
            elseif b == B_QUOTE or b == B_DQUOTE then
                local start_col = column(state, state.pos)
                local start_line = state.line
                local value = read_quoted(state)
                tn = tn + 1
                tokens[tn] = {
                    t = "string",
                    v = value,
                    l = start_line,
                    c = start_col,
                    el = state.line,
                    ec = column(state, state.pos),
                }
            elseif b == B_LBRACKET and long_bracket_level(state, state.pos) then
                local start_col = column(state, state.pos)
                local start_line = state.line
                local level, body_start = long_bracket_level(state, state.pos)
                state.pos = body_start
                local value = read_long_body(state, level, "long string")
                tn = tn + 1
                tokens[tn] = {
                    t = "string",
                    v = value,
                    l = start_line,
                    c = start_col,
                    el = state.line,
                    ec = column(state, state.pos),
                }
            else
                local start_col = column(state, state.pos)
                local three = sub(src, state.pos, state.pos + 2)
                local two = sub(src, state.pos, state.pos + 1)
                local one = sub(src, state.pos, state.pos)

                ---@type string, integer
                local op, width
                if OPS3[three] then
                    op, width = three, 3
                elseif OPS2[two] then
                    op, width = two, 2
                elseif OPS1[one] then
                    op, width = one, 1
                else
                    fail(state, "unexpected symbol near '" .. one .. "'")
                end

                state.pos = state.pos + width
                tn = tn + 1
                tokens[tn] = {
                    t = "op",
                    v = op,
                    l = state.line,
                    c = start_col,
                    el = state.line,
                    ec = start_col + width,
                }
            end
        end

        tn = tn + 1
        tokens[tn] = {
            t = "eof",
            v = "<eof>",
            l = state.line,
            c = column(state, state.pos),
            el = state.line,
            ec = column(state, state.pos),
        }
    end)

    if not ok then
        if type(err) == "table" and err.typer_error then
            return { tokens = state.tokens, comments = state.comments }, err
        end
        error(err, 0)
    end

    return { tokens = state.tokens, comments = state.comments }, nil
end

return M
