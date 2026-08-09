--- Parser for LuaLS doc tags (`---@class`, `---@param`, ...).
---
--- Unknown tags are recorded but never rejected: LuaLS gains tags over time and
--- typer must not fail on a file that a newer language server accepts.
---@class typer.annot.tags
local M = {}

local types = require("typer.annot.types")

local match, find, sub = string.match, string.find, string.sub

--- Tags typer understands. Everything else lands in `kind = "other"`.
---@type table<string, boolean>
local KNOWN = {
    class = true,
    field = true,
    param = true,
    ["return"] = true,
    type = true,
    alias = true,
    enum = true,
    generic = true,
    overload = true,
    meta = true,
    vararg = true,
    cast = true,
    operator = true,
    module = true,
    private = true,
    protected = true,
    package = true,
    ["public"] = true,
    nodiscard = true,
    async = true,
    deprecated = true,
    see = true,
    diagnostic = true,
    source = true,
    version = true,
    as = true,
}

---@class typer.Tag
---@field kind string                 -- "class" | "param" | "return" | ...
---@field l integer                   -- absolute line of the comment
---@field c integer                   -- absolute column of the `---`
---@field text_col integer            -- absolute column of the character after `---`
---@field raw string                  -- tag body, after `@name`
---@field err typer.LexError|nil      -- type-expression parse error, if any
---@field name string|nil
---@field type typer.TypeNode|nil
---@field list typer.TypeNode[]|nil
---@field parents typer.TypeNode[]|nil
---@field generics string[]|nil
---@field names string[]|nil
---@field optional boolean|nil
---@field description string|nil
---@field name_col integer|nil
---@field name_ec integer|nil
---@field exact boolean|nil        -- `---@class (exact)`
---@field scope string|nil         -- `---@field package x`, and friends
---@field key_type typer.TypeNode|nil  -- computed-key form: `---@field [string] integer`
---@field computed boolean|nil     -- true alongside key_type
---@field module string|nil        -- the module named by `---@meta <name>`

--- Column of offset 1 of a doc comment's text. The lexer strips `---`, so the
--- text begins three columns after the comment's own column.
---@param comment typer.Comment
---@return integer
local function text_base_col(comment)
    return comment.c + 3
end

--- Parses one type at `offset`, recording any error on the tag.
---@param tag typer.Tag
---@param text string
---@param offset integer
---@param comment typer.Comment
---@return typer.TypeNode|nil
---@return integer
local function parse_type_at(tag, text, offset, comment)
    local node, next_offset, err = types.parse(text, offset, comment.l, text_base_col(comment))
    if err then
        tag.err = err
    end
    return node, next_offset
end

--- `@class [(exact)] Name[<T, U>] [: Parent[, Parent2]]`
---@param tag typer.Tag
---@param text string
---@param comment typer.Comment
local function parse_class(tag, text, comment)
    local offset = 1
    local _, exact_stop = find(text, "^%s*%(exact%)", offset)
    if exact_stop then
        tag.exact = true
        offset = exact_stop + 1
    end

    local _, space_stop = find(text, "^%s*", offset)
    offset = space_stop + 1

    local name_offset = offset
    local name = match(text, "^([%a_][%w_%.]*)", offset)
    if not name then
        tag.err = {
            typer_error = true,
            kind = "tag",
            msg = "class name expected",
            l = comment.l,
            c = text_base_col(comment) + offset - 1,
        }
        return
    end

    tag.name = name
    tag.name_col = text_base_col(comment) + name_offset - 1
    tag.name_ec = tag.name_col + #name
    offset = offset + #name

    -- Generic parameter list on the class itself: `---@class Stack<T>`
    if match(text, "^%s*<", offset) then
        local close = find(text, ">", offset, true)
        if close then
            tag.generics = {}
            for piece in sub(text, offset + 1, close - 1):gmatch("[^,]+") do
                tag.generics[#tag.generics + 1] = (piece:gsub("^%s*(.-)%s*$", "%1"))
            end
            offset = close + 1
        end
    end

    local _, colon_stop = find(text, "^%s*:%s*", offset)
    if colon_stop then
        offset = colon_stop + 1
        tag.parents = {}
        repeat
            local parent, next_offset = parse_type_at(tag, text, offset, comment)
            if not parent then
                break
            end
            tag.parents[#tag.parents + 1] = parent
            offset = next_offset
            local _, comma_stop = find(text, "^%s*,%s*", offset)
            offset = comma_stop and comma_stop + 1 or offset
        until not comma_stop
    end
end

--- `@field [scope] name[?] type [description]`, or `@field [keytype] type`.
---@param tag typer.Tag
---@param text string
---@param comment typer.Comment
local function parse_field(tag, text, comment)
    local offset = 1

    local scope, scope_stop = match(text, "^%s*(public)%s+()")
    if not scope then
        scope, scope_stop = match(text, "^%s*(private)%s+()")
    end
    if not scope then
        scope, scope_stop = match(text, "^%s*(protected)%s+()")
    end
    if not scope then
        scope, scope_stop = match(text, "^%s*(package)%s+()")
    end
    if scope then
        tag.scope = scope
        offset = scope_stop
    end

    local _, space_stop = find(text, "^%s*", offset)
    offset = space_stop + 1

    -- Computed-key form: `---@field [string] integer`
    if sub(text, offset, offset) == "[" then
        local key_type, next_offset = parse_type_at(tag, text, offset + 1, comment)
        tag.key_type = key_type
        local _, bracket_stop = find(text, "^%s*%]", next_offset)
        offset = bracket_stop and bracket_stop + 1 or next_offset
        tag.computed = true
        tag.type, offset = parse_type_at(tag, text, offset, comment)
        tag.description = (sub(text, offset):gsub("^%s+", ""))
        return
    end

    local name_offset = offset
    local name = match(text, "^([%a_][%w_]*)", offset)
    if not name then
        tag.err = {
            typer_error = true,
            kind = "tag",
            msg = "field name expected",
            l = comment.l,
            c = text_base_col(comment) + offset - 1,
        }
        return
    end

    tag.name = name
    tag.name_col = text_base_col(comment) + name_offset - 1
    tag.name_ec = tag.name_col + #name
    offset = offset + #name

    if sub(text, offset, offset) == "?" then
        tag.optional = true
        offset = offset + 1
    end

    tag.type, offset = parse_type_at(tag, text, offset, comment)
    tag.description = (sub(text, offset):gsub("^%s+", ""))
end

--- `@param name[?] type [description]`, where name may be `...`.
---@param tag typer.Tag
---@param text string
---@param comment typer.Comment
local function parse_param(tag, text, comment)
    local _, space_stop = find(text, "^%s*")
    local offset = space_stop + 1
    local name_offset = offset

    ---@type string|nil
    local name
    if sub(text, offset, offset + 2) == "..." then
        name = "..."
        offset = offset + 3
    else
        name = match(text, "^([%a_][%w_]*)", offset)
        if not name then
            tag.err = {
                typer_error = true,
                kind = "tag",
                msg = "parameter name expected",
                l = comment.l,
                c = text_base_col(comment) + offset - 1,
            }
            return
        end
        offset = offset + #name
    end

    tag.name = name
    tag.name_col = text_base_col(comment) + name_offset - 1
    tag.name_ec = tag.name_col + #name

    if sub(text, offset, offset) == "?" then
        tag.optional = true
        offset = offset + 1
    end

    tag.type, offset = parse_type_at(tag, text, offset, comment)
    tag.description = (sub(text, offset):gsub("^%s+", ""))
end

--- `@return type [name] [description]`. The name is optional and ambiguous with
--- the start of a description, so it is only taken when it is a bare identifier
--- (or `?`) directly after the type.
---@param tag typer.Tag
---@param text string
---@param comment typer.Comment
local function parse_return(tag, text, comment)
    local offset = 1
    tag.type, offset = parse_type_at(tag, text, offset, comment)

    local rest = sub(text, offset)
    local name = match(rest, "^%s+([%a_][%w_]*)%s*$")
        or match(rest, "^%s+([%a_][%w_]*)%s+#")
        or match(rest, "^%s+(%?)%s*$")
    if name then
        tag.name = name
        local consumed = find(rest, name, 1, true)
        offset = offset + consumed + #name - 1
    end

    tag.description = (sub(text, offset):gsub("^%s*#?%s*", ""))
end

--- `@type type[, type]` -- a list, because `---@type A, B` annotates `local a, b`.
---@param tag typer.Tag
---@param text string
---@param comment typer.Comment
local function parse_type_tag(tag, text, comment)
    local offset = 1
    tag.list = {}
    repeat
        local node, next_offset = parse_type_at(tag, text, offset, comment)
        if not node then
            break
        end
        tag.list[#tag.list + 1] = node
        offset = next_offset
        local _, comma_stop = find(text, "^%s*,%s*", offset)
        if comma_stop then
            offset = comma_stop + 1
        end
    until not comma_stop
    tag.type = tag.list[1]
end

--- `@generic T[: parent][, U]`
---@param tag typer.Tag
---@param text string
local function parse_generic(tag, text)
    tag.names = {}
    for piece in text:gmatch("[^,]+") do
        local name = match(piece, "^%s*([%a_][%w_]*)")
        if name then
            tag.names[#tag.names + 1] = name
        end
    end
end

--- `@alias Name type`, or `@alias Name` followed by `---| 'literal'` lines.
---@param tag typer.Tag
---@param text string
---@param comment typer.Comment
local function parse_alias(tag, text, comment)
    local _, space_stop = find(text, "^%s*")
    local offset = space_stop + 1
    local name_offset = offset

    local name = match(text, "^([%a_][%w_%.]*)", offset)
    if not name then
        tag.err = {
            typer_error = true,
            kind = "tag",
            msg = "alias name expected",
            l = comment.l,
            c = text_base_col(comment) + offset - 1,
        }
        return
    end

    tag.name = name
    tag.name_col = text_base_col(comment) + name_offset - 1
    tag.name_ec = tag.name_col + #name
    offset = offset + #name

    if match(text, "^%s*%S", offset) then
        tag.type = parse_type_at(tag, text, offset, comment)
    end
end

--- Parses a single doc comment into a tag, or nil when it carries no `@`.
---
--- `in_alias` must be true only when an `@alias`/`@enum` opened earlier in this
--- same doc block. Without that guard, any prose line beginning with `|` -- a
--- grammar snippet, an ASCII table, a union written out in a comment -- would
--- be read as an alias continuation and its text parsed as a type.
---@param comment typer.Comment
---@param in_alias? boolean
---@return typer.Tag|nil
local function parse_comment(comment, in_alias)
    if not comment.doc then
        return nil
    end

    local text = comment.text

    -- Alias/enum continuation line: `---| 'value'` or `---|+ 'value'`
    local continuation = in_alias and match(text, "^%s*|%+?>?%s*(.*)$") or nil
    if continuation then
        ---@type typer.Tag
        local tag = {
            kind = "alias-item",
            l = comment.l,
            c = comment.c,
            text_col = text_base_col(comment),
            raw = continuation,
        }
        local offset = find(text, "|", 1, true) + 1
        local _, space_stop = find(text, "^[%+>]*%s*", offset)
        tag.type = parse_type_at(tag, text, (space_stop or offset) + 1, comment)
        return tag
    end

    local name, body_offset = match(text, "^%s*@([%a_][%w_]*)()")
    if not name then
        return nil
    end

    local raw = sub(text, body_offset)

    ---@type typer.Tag
    local tag = {
        kind = KNOWN[name] and name or "other",
        tag_name = name,
        l = comment.l,
        c = comment.c,
        text_col = text_base_col(comment),
        raw = raw,
    }

    local ok, err = pcall(function()
        if name == "class" then
            parse_class(tag, raw, comment)
        elseif name == "field" then
            parse_field(tag, raw, comment)
        elseif name == "param" then
            parse_param(tag, raw, comment)
        elseif name == "return" then
            parse_return(tag, raw, comment)
        elseif name == "type" then
            parse_type_tag(tag, raw, comment)
        elseif name == "alias" then
            parse_alias(tag, raw, comment)
        elseif name == "enum" then
            local enum_name = match(raw, "^%s*%(key%)%s*([%a_][%w_%.]*)") or match(raw, "^%s*([%a_][%w_%.]*)")
            tag.name = enum_name
        elseif name == "generic" then
            parse_generic(tag, raw)
        elseif name == "overload" then
            tag.type = parse_type_at(tag, raw, 1, comment)
        elseif name == "vararg" then
            tag.name = "..."
            tag.type = parse_type_at(tag, raw, 1, comment)
        elseif name == "meta" then
            tag.module = match(raw, "^%s*(%S+)")
        end
    end)

    if not ok then
        if type(err) == "table" and err.typer_error then
            tag.err = err
        else
            error(err, 0)
        end
    end

    return tag
end

--- Parses a run of doc comments into a tag list.
---@param comments typer.Comment[]
---@return typer.Tag[]
function M.parse_block(comments)
    ---@type typer.Tag[]
    local tags = {}
    local in_alias = false

    for _, comment in ipairs(comments) do
        local tag = parse_comment(comment, in_alias)
        if tag then
            tags[#tags + 1] = tag
            -- Only an alias or enum opens a continuation run; any other tag closes it.
            if tag.kind == "alias" or tag.kind == "enum" then
                in_alias = true
            elseif tag.kind ~= "alias-item" then
                in_alias = false
            end
        end
    end

    return tags
end

return M
