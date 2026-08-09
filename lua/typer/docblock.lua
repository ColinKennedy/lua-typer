--- Binds runs of `---` comments to the statements they annotate.
---
--- A doc block is a maximal run of consecutive doc-comment lines with no blank
--- line and no code between them, immediately above a statement. A doc comment
--- sharing a line with code is a *trailing* block belonging to that line.
---@class typer.docblock
local M = {}

local tags_parser = require("typer.annot.tags")

---@class typer.DocBlock
---@field comments typer.Comment[]
---@field tags typer.Tag[]
---@field l integer            -- first comment line
---@field el integer           -- last comment line
---@field trailing boolean     -- shares a line with code
---@field consumed boolean     -- claimed by a statement

---@class typer.DocIndex
---@field blocks typer.DocBlock[]
---@field by_end table<integer, typer.DocBlock>     -- last line -> leading block
---@field trailing_by_line table<integer, typer.DocBlock>
---@field code_lines table<integer, boolean>
---@field is_meta boolean
---@field meta_module string|nil

--- Indexes a parsed chunk's comments.
---@param chunk typer.Chunk
---@return typer.DocIndex
function M.build(chunk)
    ---@type table<integer, boolean>
    local code_lines = {}
    for _, token in ipairs(chunk.tokens) do
        if token.t ~= "eof" then
            for line = token.l, token.el do
                code_lines[line] = true
            end
        end
    end

    ---@type typer.DocBlock[]
    local blocks = {}
    ---@type table<integer, typer.DocBlock>
    local by_end, trailing_by_line = {}, {}
    local is_meta = false
    ---@type string|nil
    local meta_module = nil

    ---@type typer.DocBlock|nil
    local current = nil

    for _, comment in ipairs(chunk.comments) do
        if comment.doc and not comment.long then
            if code_lines[comment.l] then
                -- Trailing annotation: `local x = {} ---@type table<string, integer>`
                ---@type typer.DocBlock
                local block = {
                    comments = { comment },
                    tags = {},
                    l = comment.l,
                    el = comment.l,
                    trailing = true,
                    consumed = false,
                }
                block.tags = tags_parser.parse_block(block.comments)
                blocks[#blocks + 1] = block
                trailing_by_line[comment.l] = block
                current = nil
            else
                if current and current.el == comment.l - 1 then
                    current.comments[#current.comments + 1] = comment
                    current.el = comment.l
                else
                    current = {
                        comments = { comment },
                        tags = {},
                        l = comment.l,
                        el = comment.l,
                        trailing = false,
                        consumed = false,
                    }
                    blocks[#blocks + 1] = current
                end
            end
        elseif not comment.doc then
            -- A plain `--` comment breaks a doc run only if it sits between lines.
            if current and current.el == comment.l - 1 and not code_lines[comment.l] then
                current = nil
            end
        end
    end

    for _, block in ipairs(blocks) do
        if not block.trailing then
            block.tags = tags_parser.parse_block(block.comments)
            by_end[block.el] = block
        end
        for _, tag in ipairs(block.tags) do
            if tag.kind == "meta" then
                is_meta = true
                meta_module = tag.module
            end
        end
    end

    return {
        blocks = blocks,
        by_end = by_end,
        trailing_by_line = trailing_by_line,
        code_lines = code_lines,
        is_meta = is_meta,
        meta_module = meta_module,
    }
end

--- Merges a leading block and a trailing block on the same statement.
---@param index typer.DocIndex
---@param node typer.Node
---@return typer.Tag[]
function M.tags_for(index, node)
    ---@type typer.Tag[]
    local out = {}

    local leading = index.by_end[node.l - 1]
    if leading then
        leading.consumed = true
        for _, tag in ipairs(leading.tags) do
            out[#out + 1] = tag
        end
    end

    local trailing = index.trailing_by_line[node.el or node.l]
    if trailing then
        trailing.consumed = true
        for _, tag in ipairs(trailing.tags) do
            out[#out + 1] = tag
        end
    end

    return out
end

--- Parameter names that stand for a value the body deliberately discards, and
--- so are never *required* to carry a `---@param`.
---
--- This is the line LuaLS itself draws: both diagnostics that would otherwise
--- demand an annotation -- `incomplete-signature-doc` and `missing-doc-param`
--- -- hard-skip arguments named `self` or `_`. `_a`, `_b`, ... are included
--- because a signature with two placeholders has no other spelling: two
--- `---@param _` lines both bind to the *first* `_`, which LuaLS reports as
--- `duplicate-doc-param`, so distinct names are the only way to document them
--- all.
---
--- Annotating one anyway stays supported and stays checked -- `---@param _
--- string` types the call site exactly like any other parameter. Only the
--- *demand* moves, to `missing-param-placeholder`, which is `off` by default.
---@param name string
---@return boolean
function M.is_placeholder(name)
    return name == "self" or name:sub(1, 1) == "_"
end

--- Collects every tag of a given kind, in source order.
---@param tags typer.Tag[]
---@param kind string
---@return typer.Tag[]
function M.find_all(tags, kind)
    ---@type typer.Tag[]
    local out = {}
    for _, tag in ipairs(tags) do
        if tag.kind == kind then
            out[#out + 1] = tag
        end
    end
    return out
end

return M
