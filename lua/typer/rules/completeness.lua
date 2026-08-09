--- `T` rules: type completeness and name resolution (spec §3.4).
---
--- These apply to *every* type expression in the file, wherever it appears, and
--- recurse into unions, generic arguments, `fun(...)` signatures and shapes.
---
--- Termination: a named type is complete at its use site the moment it resolves
--- to a declaration. typer does not walk into that declaration's fields from
--- here -- an incomplete class is reported once, at its own definition. That is
--- what makes `---@field children Node[]` legal and recursive types work.
---@class typer.rules.completeness
local M = {}

local diagnostic = require("typer.diagnostic")
local types = require("typer.annot.types")
local registry_mod = require("typer.registry")

--- Tags whose payload is a type expression that must be checked.
---@type table<string, boolean>
local TYPED_TAGS = {
  param = true, ["return"] = true, field = true, type = true,
  alias = true, overload = true, vararg = true, ["alias-item"] = true,
}

---@param code string
---@param rendered string
---@return string message
---@return string|nil suggestion
local function message_for(code, rendered)
  if code == "vague-table" then
    return "'table' is not specific enough",
      "use table<K, V>, T[], an inline shape { a: string }, or a ---@class"
  elseif code == "vague-function" then
    return "'function' is not specific enough",
      "use a fun(a: T): R signature"
  elseif code == "disallowed-any" then
    return "'any' is disallowed",
      "if this is a pass-through, use ---@generic T and type this as T"
  elseif code == "disallowed-unknown" then
    return "'unknown' is disallowed",
      "if this is a pass-through, use ---@generic T and type this as T"
  end
  return rendered, nil
end

--- Collects generic parameter names in scope for a doc block.
---@param tags typer.Tag[]
---@return table<string, boolean>
local function generics_in_scope(tags)
  ---@type table<string, boolean>
  local scope = {}
  for _, tag in ipairs(tags) do
    if tag.kind == "generic" then
      for _, name in ipairs(tag.names or {}) do scope[name] = true end
    elseif tag.kind == "class" then
      for _, name in ipairs(tag.generics or {}) do scope[name] = true end
    end
  end
  return scope
end

---@param model typer.FileModel
---@param ctx typer.RuleContext
---@param node typer.TypeNode
---@param scope table<string, boolean>
local function check_node(model, ctx, node, scope)
  if node.k ~= "name" then return end

  local name = node.name
  if name == "..." then return end

  local vague_code = types.VAGUE[name]
  if vague_code then
    -- `table<K, V>` is the fixed form of bare `table`, so it passes.
    if name == "table" and node.args and #node.args >= 1 then return end
    local message, suggestion = message_for(vague_code, name)
    ctx.emit(diagnostic.new(model.path, node, vague_code, message, suggestion))
    return
  end

  if types.TERMINAL[name] then return end
  if scope[name] then return end
  if ctx.registry.generic_hints and ctx.registry.generic_hints[name] then return end

  if not registry_mod.resolve(ctx.registry, name) then
    ctx.emit(diagnostic.new(model.path, node, "unresolved-type",
      ("type '%s' is not declared anywhere in the type index"):format(name),
      ("---@class %s"):format(name)))
  end
end

---@param model typer.FileModel
---@param ctx typer.RuleContext
function M.run(model, ctx)
  for _, block in ipairs(model.docs.blocks) do
    local scope = generics_in_scope(block.tags)

    for _, tag in ipairs(block.tags) do
      -- Annotation syntax errors surface here rather than aborting the file.
      if tag.err then
        ctx.emit(diagnostic.new(model.path,
          { l = tag.err.l, c = tag.err.c },
          "annotation-syntax",
          tag.err.msg, nil))
      end

      if TYPED_TAGS[tag.kind] then
        ---@type typer.TypeNode[]
        local checked = {}
        if tag.list then
          for _, node in ipairs(tag.list) do checked[#checked + 1] = node end
        elseif tag.type then
          checked[1] = tag.type
        end
        if tag.key_type then checked[#checked + 1] = tag.key_type end

        for _, root in ipairs(checked) do
          types.walk(root, function(node)
            check_node(model, ctx, node, scope)
          end)
        end
      end

      if tag.kind == "class" then
        for _, parent in ipairs(tag.parents or {}) do
          types.walk(parent, function(node)
            check_node(model, ctx, node, scope)
          end)
        end
      end
    end
  end
end

return M
