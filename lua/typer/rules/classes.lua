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
            -- A `---@type` naming an existing class is an acceptable alternative to
            -- declaring the class inline.
            local typed_as_class = false
            if binding.type_tag and binding.type_tag.type then
                local root = binding.type_tag.type
                while root and (root.k == "optional" or root.k == "paren" or root.k == "array") do
                    root = root.of
                end
                if root and root.k == "name" and registry_mod.resolve(registry, root.name) then
                    typed_as_class = true
                end
            end

            if not typed_as_class then
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
