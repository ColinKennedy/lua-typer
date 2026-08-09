--- `C` rules: class-shape detection, field discovery, inheritance (spec §3.3).
---@class typer.rules.classes
local M = {}

local diagnostic = require("typer.diagnostic")
local registry_mod = require("typer.registry")
local analyze = require("typer.analyze")

local class_shape_reason = analyze.class_shape_reason

---@param model typer.FileModel
---@param ctx typer.RuleContext
function M.run(model, ctx)
    local registry = ctx.registry

    for _, binding in ipairs(model.bindings) do
        local reason = class_shape_reason(binding)

        if reason and not binding.class_tag then
            -- Any `---@type` already answers the question this rule exists to
            -- force. `missing-class` asks "literal shape or class?", and an author
            -- who wrote `---@type string[]` has said: a shape, and here it is.
            -- `table-decl` accepts `---@type` for exactly that reason, and a
            -- class-shaped table is no different -- a lazy-list proxy really is a
            -- `string[]`. What they wrote is still held to §3.4, so `---@type
            -- table` does not get through here either.
            local declared = binding.type_tag ~= nil or binding.enum_tag ~= nil

            if not declared then
                ctx.emit(
                    diagnostic.new(
                        model.path,
                        binding,
                        "missing-class",
                        ("table '%s' %s but has no ---@class annotation"):format(binding.name, reason),
                        ("---@class %s"):format(binding.name)
                    )
                )
            end
        end

        if binding.class_tag and binding.class_tag.name then
            local decl = registry_mod.resolve(registry, binding.class_tag.name)

            -- Every discovered data field must be declared. Methods are exempt: a
            -- `function T:foo()` with its own ---@param/---@return already describes
            -- itself, and a duplicate ---@field would only drift.
            for field_name, entry in pairs(binding.fields) do
                local declared = entry.annotated or (decl and registry_mod.has_field(registry, decl, field_name))
                if not declared then
                    ctx.emit(
                        diagnostic.new(
                            model.path,
                            entry,
                            "missing-field",
                            ("field '%s' is assigned on class '%s' but has no ---@field"):format(
                                field_name,
                                binding.class_tag.name
                            ),
                            ("---@field %s <type>"):format(field_name)
                        )
                    )
                end
            end

            if ctx.config.require_method_fields then
                for method_name, entry in pairs(binding.methods) do
                    local declared = decl and registry_mod.has_field(registry, decl, method_name)
                    if not declared then
                        ctx.emit(
                            diagnostic.new(
                                model.path,
                                entry,
                                "missing-field",
                                ("method '%s' has no ---@field on class '%s'"):format(
                                    method_name,
                                    binding.class_tag.name
                                ),
                                ("---@field %s fun()"):format(method_name)
                            )
                        )
                    end
                end
            end

            -- Detected inheritance must be declared as `---@class T : Base`.
            if binding.inherits then
                local base_name = binding.inherits.k == "Name" and binding.inherits.name or nil
                local declared_parents = binding.class_tag.parents or {}

                if base_name and #declared_parents == 0 then
                    ctx.emit(
                        diagnostic.new(
                            model.path,
                            {
                                l = binding.class_tag.l,
                                c = binding.class_tag.name_col or binding.class_tag.c,
                                ec = binding.class_tag.name_ec,
                            },
                            "missing-inherit",
                            ("class '%s' inherits from '%s' at runtime but does not declare it"):format(
                                binding.class_tag.name,
                                base_name
                            ),
                            ("---@class %s : %s"):format(binding.class_tag.name, base_name)
                        )
                    )
                end
            end
        end
    end
end

return M
