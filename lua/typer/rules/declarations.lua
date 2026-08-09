--- `D` rules: bare declarations, table bindings, globals (spec §3.1).
---@class typer.rules.declarations
local M = {}

local diagnostic = require("typer.diagnostic")
local analyze = require("typer.analyze")

--- A binding is annotated when its doc block carries `---@type` (possibly a
--- list, for `local a, b`) or `---@class`.
---@param binding typer.Binding
---@return boolean
local function is_annotated(binding)
  -- `---@class` and `---@enum` each declare the table's type outright; asking
  -- for a `---@type` on top of them would be a second annotation for one fact.
  if binding.class_tag or binding.enum_tag then return true end
  local tag = binding.type_tag
  if not tag then return false end
  -- `---@type A, B` annotates `local a, b` positionally.
  if tag.list and #tag.list > 1 then
    return binding.index ~= nil and tag.list[binding.index] ~= nil
  end
  return true
end

---@param model typer.FileModel
---@param ctx typer.RuleContext
function M.run(model, ctx)
  local config = ctx.config

  for _, binding in ipairs(model.bindings) do
    if binding.scope == "global" then
      -- Globals cross files, so they need a declaration whatever their value.
      if not is_annotated(binding) and config.strict_globals ~= false then
        ctx.emit(diagnostic.new(model.path, binding, "global-decl",
          ("global '%s' has no declaration"):format(binding.name),
          ("---@type <type>  (or ---@class %s)"):format(binding.name)))
      end

    elseif binding.kind == "bare" then
      if not is_annotated(binding) then
        local code = binding.explicit_nil and "nil-decl" or "bare-decl"
        local detail = binding.explicit_nil
          and ("local '%s' is initialised to nil and has no ---@type"):format(binding.name)
          or ("local '%s' is declared without a value and has no ---@type"):format(binding.name)
        ctx.emit(diagnostic.new(model.path, binding, code, detail, "---@type <type>"))
      end

    elseif binding.kind == "table" then
      -- A class-shaped table gets `missing-class` instead: one defect, one
      -- diagnostic, and the specific message is the actionable one.
      if not is_annotated(binding) and not analyze.class_shape_reason(binding) then
        ctx.emit(diagnostic.new(model.path, binding, "table-decl",
          ("table '%s' has no ---@type or ---@class; inference cannot tell a "
            .. "literal shape from a class"):format(binding.name),
          ("---@type table<K, V>  (or ---@class %s)"):format(binding.name)))
      end

    elseif binding.kind == "scalar" then
      if config.require_scalar_types and not is_annotated(binding) then
        ctx.emit(diagnostic.new(model.path, binding, "bare-decl",
          ("local '%s' has no ---@type"):format(binding.name), "---@type <type>"))
      end
    end
  end
end

return M
