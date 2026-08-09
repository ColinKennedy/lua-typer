--- Parser for LuaLS type expressions.
---
--- This is a *second* grammar, deliberately kept apart from the Lua grammar:
---
---   type       := union
---   union      := suffixed ('|' suffixed)*
---   suffixed   := primary ('[]' | '?')*
---   primary    := name generic_args?          -- Foo, table<K,V>, Node
---               | 'fun' '(' params ')' rets?  -- fun(a: string): boolean
---               | '{' fields '}'              -- { a: string, [integer]: Foo }
---               | '[' type (',' type)* ']'    -- [integer, string]  (tuple)
---               | literal                     -- "read" | 42 | true
---               | '(' type ')'
---
--- The scanner is folded in rather than split into its own module: the grammar
--- is small, single-line, and needs raw offsets for column reporting, which a
--- separate token stream would only obscure.
---@class typer.annot.types
local M = {}

local sub, find, match = string.sub, string.find, string.match

--- Types that are always complete: no further expansion is possible or useful.
---@type table<string, boolean>
M.TERMINAL = {
  ["nil"] = true, ["boolean"] = true, ["number"] = true, ["integer"] = true,
  ["string"] = true, ["thread"] = true, ["userdata"] = true,
  ["lightuserdata"] = true, ["self"] = true, ["true"] = true, ["false"] = true,
}

--- Types the completeness rules reject outright (spec §3.4).
---@type table<string, string>
M.VAGUE = {
  ["table"] = "vague-table",
  ["function"] = "vague-function",
  ["any"] = "disallowed-any",
  ["unknown"] = "disallowed-unknown",
}

--- Generic containers that are complete once their arguments are.
---@type table<string, integer>
M.BUILTIN_GENERIC = { ["table"] = 2 }

---@class typer.TypeNode
---@field k "name"|"array"|"optional"|"union"|"fun"|"shape"|"literal"|"paren"|"tuple"
---@field l integer    -- absolute source line
---@field c integer    -- absolute source column
---@field ec integer   -- absolute end column, exclusive

--- One parameter of a `fun(...)` type.
---@class typer.FunParam
---@field name string|nil
---@field type typer.TypeNode
---@field optional boolean|nil
---@field vararg boolean|nil
---@field off integer

--- One field of a `{ ... }` shape type.
---@class typer.ShapeField
---@field name string|nil
---@field computed boolean|nil
---@field key_type typer.TypeNode|nil
---@field type typer.TypeNode
---@field optional boolean|nil
---@field off integer

---@class typer.TypeScanner
---@field text string
---@field pos integer
---@field line integer
---@field base_col integer   -- absolute column of text offset 1
---@field err typer.LexError|nil

---@param scanner typer.TypeScanner
---@param offset integer
---@return integer
local function abs_col(scanner, offset)
  return scanner.base_col + offset - 1
end

---@param scanner typer.TypeScanner
---@param msg string
local function fail(scanner, msg)
  error({
    typer_error = true,
    kind = "type",
    msg = msg,
    l = scanner.line,
    c = abs_col(scanner, scanner.pos),
  }, 0)
end

---@param scanner typer.TypeScanner
local function skip_space(scanner)
  local _, stop = find(scanner.text, "^[ \t]+", scanner.pos)
  if stop then scanner.pos = stop + 1 end
end

---@param scanner typer.TypeScanner
---@param literal string
---@return boolean
local function try_consume(scanner, literal)
  skip_space(scanner)
  if sub(scanner.text, scanner.pos, scanner.pos + #literal - 1) == literal then
    scanner.pos = scanner.pos + #literal
    return true
  end
  return false
end

---@param scanner typer.TypeScanner
---@param literal string
local function consume(scanner, literal)
  if not try_consume(scanner, literal) then
    fail(scanner, "'" .. literal .. "' expected in type expression")
  end
end

--- Type names may be dotted (`http.Response`) and may carry a backtick generic
--- form (`` `T` ``) that LuaLS uses for captured generics.
---@param scanner typer.TypeScanner
---@return string|nil
local function try_name(scanner)
  skip_space(scanner)
  local text = scanner.text

  local backtick = match(text, "^`([%w_%.]+)`", scanner.pos)
  if backtick then
    scanner.pos = scanner.pos + #backtick + 2
    return backtick
  end

  local name = match(text, "^([%a_][%w_]*)", scanner.pos)
  if not name then return nil end
  scanner.pos = scanner.pos + #name

  -- Dotted continuation, but never consume `..` or a trailing dot.
  while match(text, "^%.[%a_]", scanner.pos) do
    local piece = match(text, "^%.([%a_][%w_]*)", scanner.pos)
    scanner.pos = scanner.pos + #piece + 1
    name = name .. "." .. piece
  end

  return name
end

---@type fun(scanner: typer.TypeScanner): typer.TypeNode
local parse_type

--- `fun(a: string, ...: any): boolean, string`
---@param scanner typer.TypeScanner
---@param start_offset integer
---@return typer.TypeNode
local function parse_fun(scanner, start_offset)
  consume(scanner, "(")

  ---@type typer.FunParam[]
  local params = {}
  skip_space(scanner)
  if not try_consume(scanner, ")") then
    repeat
      skip_space(scanner)
      local param_offset = scanner.pos
      local is_vararg = try_consume(scanner, "...")
      local name = is_vararg and "..." or try_name(scanner)

      if not name then
        -- Unnamed parameter: `fun(string): boolean`. LuaLS tolerates it; typer
        -- records the type with no name so the caller can still inspect it.
        local param_type = parse_type(scanner)
        params[#params + 1] = { name = nil, type = param_type, off = param_offset }
      else
        local optional = try_consume(scanner, "?")
        if try_consume(scanner, ":") then
          local param_type = parse_type(scanner)
          params[#params + 1] = {
            name = name, type = param_type, optional = optional,
            vararg = is_vararg, off = param_offset,
          }
        else
          -- The "name" was actually an unnamed type: `fun(string)`.
          params[#params + 1] = {
            name = nil,
            type = { k = "name", name = name, args = nil,
                     l = scanner.line, c = abs_col(scanner, param_offset),
                     ec = abs_col(scanner, scanner.pos) },
            off = param_offset,
          }
        end
      end
      skip_space(scanner)
    until not try_consume(scanner, ",")
    consume(scanner, ")")
  end

  ---@type typer.TypeNode[]
  local returns = {}
  skip_space(scanner)
  if try_consume(scanner, ":") then
    repeat
      returns[#returns + 1] = parse_type(scanner)
      skip_space(scanner)
    until not try_consume(scanner, ",")
  end

  return {
    k = "fun", params = params, returns = returns,
    l = scanner.line, c = abs_col(scanner, start_offset), ec = abs_col(scanner, scanner.pos),
  }
end

--- `{ a: string, b?: integer, [string]: Foo }`
---@param scanner typer.TypeScanner
---@param start_offset integer
---@return typer.TypeNode
local function parse_shape(scanner, start_offset)
  ---@type typer.ShapeField[]
  local fields = {}

  skip_space(scanner)
  if not try_consume(scanner, "}") then
    repeat
      skip_space(scanner)
      local field_offset = scanner.pos

      if try_consume(scanner, "[") then
        local key_type = parse_type(scanner)
        consume(scanner, "]")
        consume(scanner, ":")
        local value_type = parse_type(scanner)
        fields[#fields + 1] = {
          computed = true, key_type = key_type, type = value_type, off = field_offset,
        }
      else
        local name = try_name(scanner)
        if not name then fail(scanner, "field name expected in table shape") end
        local optional = try_consume(scanner, "?")
        consume(scanner, ":")
        local value_type = parse_type(scanner)
        fields[#fields + 1] = {
          name = name, optional = optional, type = value_type, off = field_offset,
        }
      end
      skip_space(scanner)
    until not (try_consume(scanner, ",") or try_consume(scanner, ";"))
    consume(scanner, "}")
  end

  return {
    k = "shape", fields = fields,
    l = scanner.line, c = abs_col(scanner, start_offset), ec = abs_col(scanner, scanner.pos),
  }
end

---@param scanner typer.TypeScanner
---@return typer.TypeNode
local function parse_primary(scanner)
  skip_space(scanner)
  local start_offset = scanner.pos
  local text = scanner.text

  -- Quoted string literal type: "read" | 'write'
  local quote = sub(text, scanner.pos, scanner.pos)
  if quote == '"' or quote == "'" then
    local pattern = "^" .. quote .. "([^" .. quote .. "]*)" .. quote
    local value = match(text, pattern, scanner.pos)
    if not value then fail(scanner, "unterminated string literal in type") end
    scanner.pos = scanner.pos + #value + 2
    return {
      k = "literal", value = value, literal_type = "string",
      l = scanner.line, c = abs_col(scanner, start_offset), ec = abs_col(scanner, scanner.pos),
    }
  end

  -- Numeric literal type
  local number = match(text, "^%-?%d+%.?%d*", scanner.pos)
  if number then
    scanner.pos = scanner.pos + #number
    return {
      k = "literal", value = number, literal_type = "number",
      l = scanner.line, c = abs_col(scanner, start_offset), ec = abs_col(scanner, scanner.pos),
    }
  end

  if try_consume(scanner, "(") then
    local inner = parse_type(scanner)
    consume(scanner, ")")
    return {
      k = "paren", of = inner,
      l = scanner.line, c = abs_col(scanner, start_offset), ec = abs_col(scanner, scanner.pos),
    }
  end

  if try_consume(scanner, "{") then
    return parse_shape(scanner, start_offset)
  end

  -- Tuple: `[integer, string]`. Unambiguous here -- in *primary* position a `[`
  -- can only open a tuple, whereas after a type it is the `[]` array suffix.
  if try_consume(scanner, "[") then
    ---@type typer.TypeNode[]
    local items = {}
    skip_space(scanner)
    if not try_consume(scanner, "]") then
      repeat
        items[#items + 1] = parse_type(scanner)
        skip_space(scanner)
      until not try_consume(scanner, ",")
      consume(scanner, "]")
    end
    return {
      k = "tuple", items = items,
      l = scanner.line, c = abs_col(scanner, start_offset), ec = abs_col(scanner, scanner.pos),
    }
  end

  -- `...` appears as a bare type in legacy `---@vararg`-style positions.
  if try_consume(scanner, "...") then
    return {
      k = "name", name = "...", args = nil,
      l = scanner.line, c = abs_col(scanner, start_offset), ec = abs_col(scanner, scanner.pos),
    }
  end

  local name = try_name(scanner)
  if not name then
    fail(scanner, "type expected")
  end

  if name == "fun" and match(text, "^%s*%(", scanner.pos) then
    return parse_fun(scanner, start_offset)
  end

  ---@type typer.TypeNode[]|nil
  local args = nil
  if match(text, "^%s*<", scanner.pos) then
    try_consume(scanner, "<")
    args = {}
    repeat
      args[#args + 1] = parse_type(scanner)
      skip_space(scanner)
    until not try_consume(scanner, ",")
    consume(scanner, ">")
  end

  return {
    k = "name", name = name, args = args,
    l = scanner.line, c = abs_col(scanner, start_offset), ec = abs_col(scanner, scanner.pos),
    name_ec = abs_col(scanner, start_offset + #name),
  }
end

---@param scanner typer.TypeScanner
---@return typer.TypeNode
local function parse_suffixed(scanner)
  local node = parse_primary(scanner)

  while true do
    -- `[]` only; `[` followed by anything else belongs to an outer construct.
    if match(scanner.text, "^%s*%[%s*%]", scanner.pos) then
      try_consume(scanner, "[")
      try_consume(scanner, "]")
      node = {
        k = "array", of = node,
        l = node.l, c = node.c, ec = abs_col(scanner, scanner.pos),
      }
    elseif match(scanner.text, "^%s*%?", scanner.pos) then
      try_consume(scanner, "?")
      node = {
        k = "optional", of = node,
        l = node.l, c = node.c, ec = abs_col(scanner, scanner.pos),
      }
    else
      break
    end
  end

  return node
end

---@param scanner typer.TypeScanner
---@return typer.TypeNode
parse_type = function(scanner)
  local first = parse_suffixed(scanner)

  if not match(scanner.text, "^%s*|", scanner.pos) then
    return first
  end

  ---@type typer.TypeNode[]
  local parts = { first }
  while match(scanner.text, "^%s*|", scanner.pos) do
    try_consume(scanner, "|")
    parts[#parts + 1] = parse_suffixed(scanner)
  end

  return {
    k = "union", parts = parts,
    l = first.l, c = first.c, ec = abs_col(scanner, scanner.pos),
  }
end

--- Parses one type expression from `text` starting at `offset`.
---@param text string
---@param offset integer            -- 1-based offset into `text`
---@param line integer              -- absolute line of `text`
---@param base_col integer          -- absolute column of `text` offset 1
---@return typer.TypeNode|nil node
---@return integer next_offset      -- offset just past the parsed type
---@return typer.LexError|nil err
function M.parse(text, offset, line, base_col)
  ---@type typer.TypeScanner
  local scanner = { text = text, pos = offset or 1, line = line, base_col = base_col }

  local ok, result = pcall(parse_type, scanner)
  if not ok then
    if type(result) == "table" and result.typer_error then
      return nil, scanner.pos, result
    end
    error(result, 0)
  end

  return result, scanner.pos, nil
end

--- Renders a type node back to source form, for diagnostic messages.
---@param node typer.TypeNode|nil
---@return string
function M.render(node)
  if not node then return "<?>" end
  local kind = node.k

  if kind == "name" then
    if node.args then
      ---@type string[]
      local rendered = {}
      for i, arg in ipairs(node.args) do rendered[i] = M.render(arg) end
      return node.name .. "<" .. table.concat(rendered, ", ") .. ">"
    end
    return node.name
  elseif kind == "array" then
    return M.render(node.of) .. "[]"
  elseif kind == "optional" then
    return M.render(node.of) .. "?"
  elseif kind == "paren" then
    return "(" .. M.render(node.of) .. ")"
  elseif kind == "union" then
    ---@type string[]
    local rendered = {}
    for i, part in ipairs(node.parts) do rendered[i] = M.render(part) end
    return table.concat(rendered, "|")
  elseif kind == "literal" then
    if node.literal_type == "string" then return '"' .. node.value .. '"' end
    return tostring(node.value)
  elseif kind == "fun" then
    ---@type string[]
    local params = {}
    for i, param in ipairs(node.params) do
      params[i] = (param.name and (param.name .. (param.optional and "?" or "") .. ": ") or "")
        .. M.render(param.type)
    end
    local out = "fun(" .. table.concat(params, ", ") .. ")"
    if node.returns and #node.returns > 0 then
      ---@type string[]
      local rets = {}
      for i, ret in ipairs(node.returns) do rets[i] = M.render(ret) end
      out = out .. ": " .. table.concat(rets, ", ")
    end
    return out
  elseif kind == "tuple" then
    ---@type string[]
    local items = {}
    for i, item in ipairs(node.items) do items[i] = M.render(item) end
    return "[" .. table.concat(items, ", ") .. "]"
  elseif kind == "shape" then
    ---@type string[]
    local fields = {}
    for i, field in ipairs(node.fields) do
      if field.computed then
        fields[i] = "[" .. M.render(field.key_type) .. "]: " .. M.render(field.type)
      else
        fields[i] = field.name .. (field.optional and "?" or "") .. ": " .. M.render(field.type)
      end
    end
    return "{ " .. table.concat(fields, ", ") .. " }"
  end

  return "<?>"
end

--- Visits every node in a type tree, outermost first.
---@param node typer.TypeNode|nil
---@param visit fun(node: typer.TypeNode)
function M.walk(node, visit)
  if not node then return end
  visit(node)

  local kind = node.k
  if kind == "name" then
    if node.args then
      for _, arg in ipairs(node.args) do M.walk(arg, visit) end
    end
  elseif kind == "array" or kind == "optional" or kind == "paren" then
    M.walk(node.of, visit)
  elseif kind == "union" then
    for _, part in ipairs(node.parts) do M.walk(part, visit) end
  elseif kind == "fun" then
    for _, param in ipairs(node.params) do M.walk(param.type, visit) end
    for _, ret in ipairs(node.returns) do M.walk(ret, visit) end
  elseif kind == "tuple" then
    for _, item in ipairs(node.items) do M.walk(item, visit) end
  elseif kind == "shape" then
    for _, field in ipairs(node.fields) do
      if field.key_type then M.walk(field.key_type, visit) end
      M.walk(field.type, visit)
    end
  end
end

return M
