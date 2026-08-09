--- `F` rules: parameter, vararg and return annotations (spec §3.2).
---@class typer.rules.functions
local M = {}

local diagnostic = require("typer.diagnostic")
local docblock = require("typer.docblock")

--- True when the enclosing `---@return` already types this position as a
--- function, so a returned literal need not annotate itself again.
---@param info typer.FuncInfo
---@return boolean
local function typed_by_context(info)
    return info.exempt
end

---@param model typer.FileModel
---@param ctx typer.RuleContext
function M.run(model, ctx)
    local config = ctx.config

    for _, info in ipairs(model.functions) do
        if not typed_by_context(info) then
            local node = info.node
            local param_tags = docblock.find_all(info.tags, "param")
            local return_tags = docblock.find_all(info.tags, "return")
            local overloads = docblock.find_all(info.tags, "overload")

            -- Index annotations by name so a mismatched order is reported as a name
            -- mismatch rather than a cascade of missing params.
            ---@type table<string, typer.Tag>
            local by_name = {}
            for _, tag in ipairs(param_tags) do
                if tag.name then
                    by_name[tag.name] = tag
                end
            end

            ---@type typer.Param[]
            local real_params = {}
            for _, param in ipairs(node.params) do
                -- `self` on a `:` method comes from the class, never from `---@param`.
                if not param.implicit then
                    real_params[#real_params + 1] = param
                end
            end

            -- `---@param self` is wrong on a colon method. Drop it from the
            -- positional list too: the shift it causes is a consequence of this one
            -- defect, not a second one to report.
            if node.is_method and by_name["self"] then
                local tag = by_name["self"]
                ctx.emit(
                    diagnostic.new(
                        model.path,
                        { l = tag.l, c = tag.name_col or tag.c, ec = tag.name_ec },
                        "self-param",
                        "'self' is implicit on a ':' method; remove this ---@param",
                        nil
                    )
                )

                ---@type typer.Tag[]
                local without_self = {}
                for _, candidate in ipairs(param_tags) do
                    if candidate.name ~= "self" then
                        without_self[#without_self + 1] = candidate
                    end
                end
                param_tags = without_self
            end

            for index, param in ipairs(real_params) do
                local tag = by_name[param.name]

                if not tag then
                    if param.vararg then
                        ctx.emit(
                            diagnostic.new(
                                model.path,
                                param,
                                "missing-vararg",
                                "function declares '...' but has no ---@param ... annotation",
                                "---@param ... <type>"
                            )
                        )
                    else
                        ctx.emit(
                            diagnostic.new(
                                model.path,
                                param,
                                "missing-param",
                                ("parameter '%s' has no ---@param annotation"):format(param.name),
                                ("---@param %s <type>"):format(param.name)
                            )
                        )
                    end
                else
                    -- Positional check: annotation N should name parameter N.
                    local positional = param_tags[index]
                    if
                        positional
                        and positional.name
                        and positional.name ~= param.name
                        and not by_name[positional.name .. "\0"]
                    then
                        local matches_some = false
                        for _, other in ipairs(real_params) do
                            if other.name == positional.name then
                                matches_some = true
                            end
                        end
                        if not matches_some then
                            ctx.emit(
                                diagnostic.new(
                                    model.path,
                                    {
                                        l = positional.l,
                                        c = positional.name_col or positional.c,
                                        ec = positional.name_ec,
                                    },
                                    "param-name-mismatch",
                                    ("---@param '%s' does not match parameter '%s'"):format(
                                        positional.name,
                                        param.name
                                    ),
                                    ("---@param %s <type>"):format(param.name)
                                )
                            )
                        end
                    end

                    if config.optional_param ~= "off" and param.defaulted and not tag.optional then
                        ctx.emit(
                            diagnostic.new(
                                model.path,
                                { l = tag.l, c = tag.name_col or tag.c, ec = tag.name_ec },
                                "optional-param",
                                ("parameter '%s' is defaulted in the body but not marked optional"):format(param.name),
                                ("---@param %s? <type>"):format(param.name)
                            )
                        )
                    end
                end
            end

            -- Extra `---@param` lines naming nothing in the signature.
            if #param_tags > #real_params and #overloads == 0 then
                ---@type table<string, boolean>
                local real_names = {}
                for _, param in ipairs(real_params) do
                    real_names[param.name] = true
                end
                for _, tag in ipairs(param_tags) do
                    if tag.name and tag.name ~= "self" and not real_names[tag.name] then
                        ctx.emit(
                            diagnostic.new(
                                model.path,
                                { l = tag.l, c = tag.name_col or tag.c, ec = tag.name_ec },
                                "param-arity-mismatch",
                                ("---@param '%s' does not correspond to any parameter"):format(tag.name),
                                nil
                            )
                        )
                    end
                end
            end

            -- Returns: one `---@return` per returned value, at the widest arity.
            if info.has_value_return then
                if #return_tags < info.return_arity then
                    local missing = info.return_arity - #return_tags
                    ctx.emit(
                        diagnostic.new(
                            model.path,
                            info,
                            "missing-return",
                            ("function returns %d value%s but declares %d ---@return; %d missing"):format(
                                info.return_arity,
                                info.return_arity == 1 and "" or "s",
                                #return_tags,
                                missing
                            ),
                            "---@return <type>"
                        )
                    )
                elseif #return_tags > info.return_arity and #overloads == 0 and not info.indeterminate_arity then
                    local extra = return_tags[info.return_arity + 1]
                    ctx.emit(
                        diagnostic.new(
                            model.path,
                            { l = extra.l, c = extra.c },
                            "return-arity-mismatch",
                            ("%d ---@return annotations but the function returns at most %d value%s"):format(
                                #return_tags,
                                info.return_arity,
                                info.return_arity == 1 and "" or "s"
                            ),
                            nil
                        )
                    )
                end

                if
                    config.optional_return ~= "off"
                    and info.has_nil_return
                    and return_tags[1]
                    and return_tags[1].type
                then
                    local first = return_tags[1].type
                    local optional = first.k == "optional"
                        or (
                            first.k == "union"
                            and (function()
                                for _, part in ipairs(first.parts) do
                                    if part.k == "name" and part.name == "nil" then
                                        return true
                                    end
                                end
                                return false
                            end)()
                        )
                    if not optional then
                        ctx.emit(
                            diagnostic.new(
                                model.path,
                                { l = return_tags[1].l, c = return_tags[1].c },
                                "optional-return",
                                "a return path yields nil but the first ---@return is not optional",
                                "---@return <type>?"
                            )
                        )
                    end
                end
            end
        end
    end
end

return M
