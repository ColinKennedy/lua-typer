--- Recursive-descent parser for the Lua grammar. Produces an AST where every
--- node carries `l`, `c`, `el`, `ec` so diagnostics can point at the exact token.
---@class typer.parser
local M = {}

local lexer = require("typer.lexer")

--- Binary operator priorities, mirroring lparser.c. Right-associative operators
--- have a right priority lower than their left priority.
---@type table<string, {[1]: integer, [2]: integer}>
local BINARY_PRIORITY = {
  ["or"] = { 1, 1 },
  ["and"] = { 2, 2 },
  ["<"] = { 3, 3 }, [">"] = { 3, 3 }, ["<="] = { 3, 3 },
  [">="] = { 3, 3 }, ["~="] = { 3, 3 }, ["=="] = { 3, 3 },
  ["|"] = { 4, 4 },
  ["~"] = { 5, 5 },
  ["&"] = { 6, 6 },
  ["<<"] = { 7, 7 }, [">>"] = { 7, 7 },
  [".."] = { 9, 8 },
  ["+"] = { 10, 10 }, ["-"] = { 10, 10 },
  ["*"] = { 11, 11 }, ["/"] = { 11, 11 }, ["//"] = { 11, 11 }, ["%"] = { 11, 11 },
  ["^"] = { 14, 13 },
}

local UNARY_PRIORITY = 12

---@type table<string, boolean>
local UNARY_OPS = { ["not"] = true, ["-"] = true, ["#"] = true, ["~"] = true }

--- Keywords that close a block. Membership must always be tested together with
--- `token.t == "keyword"`: `return "end"` is a perfectly ordinary string whose
--- value collides with every entry here.
---@type table<string, boolean>
local BLOCK_ENDERS = {
  ["end"] = true, ["else"] = true, ["elseif"] = true, ["until"] = true,
}

--- One entry of a function's parameter list.
---@class typer.Param
---@field name string          -- the identifier, or "..." for a vararg
---@field l integer
---@field c integer
---@field ec integer
---@field vararg boolean|nil   -- true for `...`
---@field implicit boolean|nil -- true for the `self` of a `:` method
---@field defaulted boolean|nil

--- One entry of a table constructor.
---@class typer.TableField
---@field kind "computed"|"named"|"positional"
---@field key typer.Node|nil     -- `[expr] =` form
---@field name string|nil        -- `name =` form
---@field value typer.Node
---@field l integer|nil
---@field c integer|nil
---@field ec integer|nil

--- One name in a `local` declaration, or a loop variable.
---@class typer.LocalName
---@field name string
---@field attrib string|nil      -- 5.4 `<const>` / `<close>`
---@field l integer
---@field c integer
---@field ec integer

--- One `if`/`elseif` arm.
---@class typer.IfClause
---@field cond typer.Node
---@field body typer.Node[]

---@class typer.Node
---@field k string            -- node kind
---@field l integer
---@field c integer
---@field el integer
---@field ec integer

---@class typer.ParseState
---@field tokens typer.Token[]
---@field pos integer

---@param state typer.ParseState
---@return typer.Token
local function peek(state)
  return state.tokens[state.pos]
end

---@param state typer.ParseState
---@param offset integer
---@return typer.Token
local function peek_at(state, offset)
  return state.tokens[state.pos + offset] or state.tokens[#state.tokens]
end

---@param state typer.ParseState
---@return typer.Token
local function advance(state)
  local token = state.tokens[state.pos]
  if token.t ~= "eof" then state.pos = state.pos + 1 end
  return token
end

---@param state typer.ParseState
---@param msg string
---@param token? typer.Token
local function fail(state, msg, token)
  token = token or peek(state)
  error({
    typer_error = true,
    kind = "parse",
    msg = msg,
    l = token.l,
    c = token.c,
  }, 0)
end

--- True when the current token is the given operator or keyword.
---@param state typer.ParseState
---@param value string
---@return boolean
local function check(state, value)
  local token = state.tokens[state.pos]
  return (token.t == "op" or token.t == "keyword") and token.v == value
end

---@param state typer.ParseState
---@param value string
---@return typer.Token|nil
local function accept(state, value)
  if check(state, value) then return advance(state) end
  return nil
end

---@param state typer.ParseState
---@param value string
---@return typer.Token
local function expect(state, value)
  if not check(state, value) then
    fail(state, "'" .. value .. "' expected near '" .. tostring(peek(state).v) .. "'")
  end
  return advance(state)
end

---@param state typer.ParseState
---@return typer.Token
local function expect_name(state)
  local token = peek(state)
  if token.t ~= "name" then
    fail(state, "<name> expected near '" .. tostring(token.v) .. "'")
  end
  return advance(state)
end

--- Stamps positional fields onto a node from a start token and an end token.
---@generic T: table
---@param node T
---@param start_token typer.Token
---@param end_token typer.Token
---@return T
local function span(node, start_token, end_token)
  node.l = start_token.l
  node.c = start_token.c
  node.el = end_token.el
  node.ec = end_token.ec
  return node
end

---@param state typer.ParseState
---@return typer.Token
local function last_token(state)
  return state.tokens[math.max(1, state.pos - 1)]
end

--- True at EOF or at a keyword that closes the enclosing block.
---@param state typer.ParseState
---@return boolean
local function at_block_end(state)
  local token = state.tokens[state.pos]
  return token.t == "eof" or (token.t == "keyword" and BLOCK_ENDERS[token.v] == true)
end

---@type (fun(state: typer.ParseState): typer.Node[]), (fun(state: typer.ParseState): typer.Node), (fun(state: typer.ParseState): typer.Node)
local parse_block, parse_expression, parse_statement

--- `function` body: parameter list plus block. `start_token` is the `function`
--- keyword (or the name token for `local function`), used for the node span.
---@param state typer.ParseState
---@param start_token typer.Token
---@param is_method boolean
---@return typer.Node
local function parse_function_body(state, start_token, is_method)
  expect(state, "(")

  ---@type typer.Param[]
  local params = {}
  local is_vararg = false

  if is_method then
    -- `self` is implicit and carries no source position of its own.
    params[1] = { name = "self", implicit = true, l = start_token.l, c = start_token.c, ec = start_token.ec }
  end

  if not check(state, ")") then
    repeat
      if check(state, "...") then
        local token = advance(state)
        is_vararg = true
        params[#params + 1] = { name = "...", vararg = true, l = token.l, c = token.c, ec = token.ec }
        break
      end
      local token = expect_name(state)
      params[#params + 1] = { name = token.v, l = token.l, c = token.c, ec = token.ec }
    until not accept(state, ",")
  end

  expect(state, ")")
  local body = parse_block(state)
  local end_token = expect(state, "end")

  return span({
    k = "Function",
    params = params,
    is_vararg = is_vararg,
    is_method = is_method,
    body = body,
  }, start_token, end_token)
end

---@param state typer.ParseState
---@return typer.Node
local function parse_table(state)
  local start_token = expect(state, "{")
  ---@type typer.TableField[]
  local fields = {}

  while not check(state, "}") do
    if check(state, "[") then
      advance(state)
      local key = parse_expression(state)
      expect(state, "]")
      expect(state, "=")
      local value = parse_expression(state)
      fields[#fields + 1] = { kind = "computed", key = key, value = value }
    elseif peek(state).t == "name" and peek_at(state, 1).t == "op" and peek_at(state, 1).v == "=" then
      local name_token = advance(state)
      advance(state) -- '='
      local value = parse_expression(state)
      fields[#fields + 1] = {
        kind = "named", name = name_token.v, value = value,
        l = name_token.l, c = name_token.c, ec = name_token.ec,
      }
    else
      local value = parse_expression(state)
      fields[#fields + 1] = { kind = "positional", value = value }
    end

    if not (accept(state, ",") or accept(state, ";")) then break end
  end

  local end_token = expect(state, "}")
  return span({ k = "Table", fields = fields }, start_token, end_token)
end

--- Call arguments: `(...)`, a table constructor, or a literal string.
---@param state typer.ParseState
---@return typer.Node[]|nil
local function parse_call_args(state)
  local token = peek(state)

  if check(state, "(") then
    advance(state)
    ---@type typer.Node[]
    local args = {}
    if not check(state, ")") then
      repeat
        args[#args + 1] = parse_expression(state)
      until not accept(state, ",")
    end
    expect(state, ")")
    return args
  elseif check(state, "{") then
    return { parse_table(state) }
  elseif token.t == "string" then
    advance(state)
    return { span({ k = "String", v = token.v }, token, token) }
  end

  return nil
end

--- Primary expression plus any chain of `.x`, `[x]`, `(...)`, `:m(...)`.
---@param state typer.ParseState
---@return typer.Node
local function parse_suffixed(state)
  local start_token = peek(state)
  ---@type typer.Node
  local node

  if check(state, "(") then
    advance(state)
    local inner = parse_expression(state)
    local close = expect(state, ")")
    node = span({ k = "Paren", expr = inner }, start_token, close)
  elseif start_token.t == "name" then
    advance(state)
    node = span({ k = "Name", name = start_token.v }, start_token, start_token)
  else
    fail(state, "unexpected symbol near '" .. tostring(start_token.v) .. "'")
  end

  while true do
    if check(state, ".") then
      advance(state)
      local name_token = expect_name(state)
      node = span({
        k = "Index", obj = node, name = name_token.v, computed = false,
        key_l = name_token.l, key_c = name_token.c, key_ec = name_token.ec,
      }, start_token, name_token)
    elseif check(state, "[") then
      advance(state)
      local key = parse_expression(state)
      local close = expect(state, "]")
      node = span({ k = "Index", obj = node, key = key, computed = true }, start_token, close)
    elseif check(state, ":") then
      advance(state)
      local name_token = expect_name(state)
      local args = parse_call_args(state)
      if not args then fail(state, "function arguments expected") end
      node = span({
        k = "MethodCall", obj = node, method = name_token.v, args = args,
        method_l = name_token.l, method_c = name_token.c, method_ec = name_token.ec,
      }, start_token, last_token(state))
    elseif check(state, "(") or check(state, "{") or peek(state).t == "string" then
      local args = parse_call_args(state)
      node = span({ k = "Call", callee = node, args = args }, start_token, last_token(state))
    else
      break
    end
  end

  return node
end

---@param state typer.ParseState
---@return typer.Node
local function parse_simple(state)
  local token = peek(state)

  if token.t == "number" then
    advance(state)
    return span({ k = "Number", v = token.v }, token, token)
  elseif token.t == "string" then
    advance(state)
    return span({ k = "String", v = token.v }, token, token)
  elseif check(state, "nil") then
    advance(state)
    return span({ k = "Nil" }, token, token)
  elseif check(state, "true") then
    advance(state)
    return span({ k = "True" }, token, token)
  elseif check(state, "false") then
    advance(state)
    return span({ k = "False" }, token, token)
  elseif check(state, "...") then
    advance(state)
    return span({ k = "Vararg" }, token, token)
  elseif check(state, "{") then
    return parse_table(state)
  elseif check(state, "function") then
    advance(state)
    return parse_function_body(state, token, false)
  end

  return parse_suffixed(state)
end

--- Precedence-climbing expression parser.
---@param state typer.ParseState
---@param limit? integer
---@return typer.Node
local function parse_subexpression(state, limit)
  limit = limit or 0
  ---@type typer.Node
  local left

  local token = peek(state)
  if (token.t == "op" or token.t == "keyword") and UNARY_OPS[token.v] then
    advance(state)
    local operand = parse_subexpression(state, UNARY_PRIORITY)
    left = span({ k = "UnOp", op = token.v, operand = operand }, token, last_token(state))
  else
    left = parse_simple(state)
  end

  while true do
    local op_token = peek(state)
    if op_token.t ~= "op" and op_token.t ~= "keyword" then break end
    local priority = BINARY_PRIORITY[op_token.v]
    if not priority or priority[1] <= limit then break end

    advance(state)
    local right = parse_subexpression(state, priority[2])
    left = {
      k = "BinOp", op = op_token.v, left = left, right = right,
      l = left.l, c = left.c, el = right.el, ec = right.ec,
    }
  end

  return left
end

---@param state typer.ParseState
---@return typer.Node
parse_expression = function(state)
  return parse_subexpression(state, 0)
end

---@param state typer.ParseState
---@return typer.Node[]
local function parse_expression_list(state)
  ---@type typer.Node[]
  local list = {}
  repeat
    list[#list + 1] = parse_expression(state)
  until not accept(state, ",")
  return list
end

---@param state typer.ParseState
---@param start_token typer.Token
---@return typer.Node
local function parse_local(state, start_token)
  if check(state, "function") then
    advance(state)
    local name_token = expect_name(state)
    local fn = parse_function_body(state, start_token, false)
    return span({
      k = "LocalFunction",
      name = name_token.v,
      name_l = name_token.l, name_c = name_token.c, name_ec = name_token.ec,
      fn = fn,
    }, start_token, fn)
  end

  ---@type typer.LocalName[]
  local names = {}
  repeat
    local name_token = expect_name(state)
    ---@type string|nil
    local attrib = nil
    if accept(state, "<") then -- 5.4 `<const>` / `<close>`
      attrib = expect_name(state).v
      expect(state, ">")
    end
    names[#names + 1] = {
      name = name_token.v, attrib = attrib,
      l = name_token.l, c = name_token.c, ec = name_token.ec,
    }
  until not accept(state, ",")

  ---@type typer.Node[]|nil
  local exprs = nil
  if accept(state, "=") then
    exprs = parse_expression_list(state)
  end

  return span({ k = "Local", names = names, exprs = exprs }, start_token, last_token(state))
end

--- `function a.b.c:d() end` -- returns the target expression and method flag.
---@param state typer.ParseState
---@return typer.Node target
---@return boolean is_method
local function parse_function_name(state)
  local name_token = expect_name(state)
  ---@type typer.Node
  local target = span({ k = "Name", name = name_token.v }, name_token, name_token)
  local is_method = false

  while check(state, ".") do
    advance(state)
    local field = expect_name(state)
    target = span({
      k = "Index", obj = target, name = field.v, computed = false,
      key_l = field.l, key_c = field.c, key_ec = field.ec,
    }, name_token, field)
  end

  if check(state, ":") then
    advance(state)
    local field = expect_name(state)
    target = span({
      k = "Index", obj = target, name = field.v, computed = false,
      key_l = field.l, key_c = field.c, key_ec = field.ec,
    }, name_token, field)
    is_method = true
  end

  return target, is_method
end

---@param state typer.ParseState
---@return typer.Node
parse_statement = function(state)
  local start_token = peek(state)

  if check(state, ";") then
    advance(state)
    return span({ k = "Empty" }, start_token, start_token)

  elseif check(state, "local") then
    advance(state)
    return parse_local(state, start_token)

  elseif check(state, "function") then
    advance(state)
    local target, is_method = parse_function_name(state)
    local fn = parse_function_body(state, start_token, is_method)
    return span({ k = "FunctionStat", target = target, is_method = is_method, fn = fn }, start_token, fn)

  elseif check(state, "return") then
    advance(state)
    ---@type typer.Node[]|nil
    local exprs = nil
    if not at_block_end(state) and not check(state, ";") then
      exprs = parse_expression_list(state)
    end
    accept(state, ";")
    return span({ k = "Return", exprs = exprs }, start_token, last_token(state))

  elseif check(state, "if") then
    advance(state)
    ---@type typer.IfClause[]
    local clauses = {}
    local condition = parse_expression(state)
    expect(state, "then")
    clauses[1] = { cond = condition, body = parse_block(state) }

    while check(state, "elseif") do
      advance(state)
      local elseif_cond = parse_expression(state)
      expect(state, "then")
      clauses[#clauses + 1] = { cond = elseif_cond, body = parse_block(state) }
    end

    ---@type typer.Node[]|nil
    local else_body = nil
    if accept(state, "else") then else_body = parse_block(state) end
    local end_token = expect(state, "end")
    return span({ k = "If", clauses = clauses, else_body = else_body }, start_token, end_token)

  elseif check(state, "while") then
    advance(state)
    local condition = parse_expression(state)
    expect(state, "do")
    local body = parse_block(state)
    local end_token = expect(state, "end")
    return span({ k = "While", cond = condition, body = body }, start_token, end_token)

  elseif check(state, "do") then
    advance(state)
    local body = parse_block(state)
    local end_token = expect(state, "end")
    return span({ k = "Do", body = body }, start_token, end_token)

  elseif check(state, "for") then
    advance(state)
    local first = expect_name(state)

    if check(state, "=") then
      advance(state)
      local from = parse_expression(state)
      expect(state, ",")
      local to = parse_expression(state)
      ---@type typer.Node|nil
      local step = nil
      if accept(state, ",") then step = parse_expression(state) end
      expect(state, "do")
      local body = parse_block(state)
      local end_token = expect(state, "end")
      return span({
        k = "ForNum",
        var = { name = first.v, l = first.l, c = first.c, ec = first.ec },
        from = from, to = to, step = step, body = body,
      }, start_token, end_token)
    end

    ---@type typer.LocalName[]
    local names = { { name = first.v, l = first.l, c = first.c, ec = first.ec } }
    while accept(state, ",") do
      local extra = expect_name(state)
      names[#names + 1] = { name = extra.v, l = extra.l, c = extra.c, ec = extra.ec }
    end
    expect(state, "in")
    local exprs = parse_expression_list(state)
    expect(state, "do")
    local body = parse_block(state)
    local end_token = expect(state, "end")
    return span({ k = "ForIn", names = names, exprs = exprs, body = body }, start_token, end_token)

  elseif check(state, "repeat") then
    advance(state)
    local body = parse_block(state)
    expect(state, "until")
    local condition = parse_expression(state)
    return span({ k = "Repeat", body = body, cond = condition }, start_token, last_token(state))

  elseif check(state, "break") then
    advance(state)
    return span({ k = "Break" }, start_token, start_token)

  elseif check(state, "goto") then
    advance(state)
    local label = expect_name(state)
    return span({ k = "Goto", label = label.v }, start_token, label)

  elseif check(state, "::") then
    advance(state)
    local label = expect_name(state)
    expect(state, "::")
    return span({ k = "Label", name = label.v }, start_token, last_token(state))
  end

  -- Expression statement: either a call, or the left side of an assignment.
  local first = parse_suffixed(state)

  if check(state, "=") or check(state, ",") then
    ---@type typer.Node[]
    local targets = { first }
    while accept(state, ",") do
      targets[#targets + 1] = parse_suffixed(state)
    end
    expect(state, "=")
    local exprs = parse_expression_list(state)
    return span({ k = "Assign", targets = targets, exprs = exprs }, start_token, last_token(state))
  end

  if first.k ~= "Call" and first.k ~= "MethodCall" then
    fail(state, "syntax error near '" .. tostring(peek(state).v) .. "'", start_token)
  end

  return span({ k = "CallStat", expr = first }, start_token, last_token(state))
end

---@param state typer.ParseState
---@return typer.Node[]
parse_block = function(state)
  ---@type typer.Node[]
  local body = {}

  while true do
    if at_block_end(state) then break end

    local statement = parse_statement(state)
    body[#body + 1] = statement

    -- `return` must be the last statement in its block.
    if statement.k == "Return" then break end
  end

  return body
end

---@class typer.Chunk
---@field k "Chunk"
---@field body typer.Node[]
---@field comments typer.Comment[]
---@field tokens typer.Token[]

--- Parses Lua source into a chunk.
---@param src string
---@return typer.Chunk|nil
---@return typer.LexError|nil
function M.parse(src)
  local lexed, lex_error = lexer.lex(src)
  if lex_error then return nil, lex_error end

  ---@type typer.ParseState
  local state = { tokens = lexed.tokens, pos = 1 }

  local ok, result = pcall(function()
    local body = parse_block(state)
    if peek(state).t ~= "eof" then
      fail(state, "'<eof>' expected near '" .. tostring(peek(state).v) .. "'")
    end
    return body
  end)

  if not ok then
    if type(result) == "table" and result.typer_error then
      return nil, result
    end
    error(result, 0)
  end

  return {
    k = "Chunk",
    body = result,
    comments = lexed.comments,
    tokens = lexed.tokens,
  }, nil
end

return M
