--- Single-pass AST walk producing the per-file model the rules consume.
---
--- Everything the rules need is gathered here so a file is walked exactly once:
--- lexical scopes (to tell locals from globals), bindings and their initialisers,
--- function definitions with their parameters and return arities, class-shape
--- signals, discovered fields, `require` sites, and global reads.
---@class typer.analyze
local M = {}

local docblock = require("typer.docblock")

--- What an already-declared function slot says about itself.
---
--- Deliberately thin. typer does not type-check (spec §2), so this carries only
--- what the rules can act on: that the slot *is* declared -- which is what makes
--- a function assigned into it an override rather than a declaration -- and its
--- return arity, the one part a re-assignment can still contradict.
---@class typer.FuncDecl
---@field returns integer            -- declared ---@return count
---@field indeterminate boolean|nil  -- an ---@overload widens it; arity unknown

--- The declaration a function expression inherits instead of writing its own.
---
--- `decl` is filled in when the declaring site is in this same file. `key` is
--- for the sites that are not -- a required module's export, a global-rooted
--- name like `vim.notify` -- and is resolved against the project-wide index once
--- every file has been read. See `rules/functions.lua`.
---@class typer.Inherited
---@field decl typer.FuncDecl|nil
---@field key string|nil
---@field origin string             -- where the declaration lives, for the message

--- A field or method discovered on a class, with the position to report at.
---@class typer.FieldEntry
---@field name string
---@field l integer
---@field c integer
---@field ec integer
---@field is_function boolean
---@field annotated boolean|nil       -- carries its own `---@type`
---@field in_constructor boolean|nil
---@field decl typer.FuncDecl|nil     -- the signature it was declared with

---@class typer.Binding
---@field name string
---@field l integer
---@field c integer
---@field ec integer
---@field scope "local"|"global"
---@field kind "table"|"function"|"require"|"bare"|"scalar"|"other"
---@field decl typer.Node|nil          -- the declaring statement
---@field init typer.Node|nil          -- initialiser expression
---@field tags typer.Tag[]             -- doc tags on the declaration
---@field class_tag typer.Tag|nil
---@field type_tag typer.Tag|nil
---@field signals table<string, typer.Node>   -- class-shape signals
---@field fields table<string, typer.FieldEntry>    -- discovered data fields
---@field methods table<string, typer.FieldEntry>   -- discovered methods
---@field class_owner typer.Binding|nil       -- the class `self` stands for
---@field enum_tag typer.Tag|nil
---@field index integer|nil                   -- position in a multi-name local
---@field explicit_nil boolean|nil
---@field inherits typer.Node|nil             -- detected base expression
---@field param_tag typer.Tag|nil             -- the `---@param` that typed it
---@field module string|nil                   -- for `require` bindings
---@field late_table boolean|nil              -- assigned a table after declaration
---@field reassigned boolean|nil              -- a global written more than once

---@class typer.FuncInfo
---@field node typer.Node
---@field tags typer.Tag[]
---@field display string               -- human-readable name for messages
---@field l integer
---@field c integer
---@field ec integer
---@field is_method boolean
---@field return_arity integer
---@field has_value_return boolean
---@field has_nil_return boolean
---@field owner typer.Binding|nil      -- class the method belongs to
---@field exempt boolean               -- inline expression, typed by context
---@field indeterminate_arity boolean|nil  -- returns a call, so arity is unknown
---@field inherited typer.Inherited|nil -- the slot it overrides already has a type

--- The line range of one statement, so `-- typer: ignore` can cover a whole
--- multi-line statement rather than just its first line.
---@class typer.StatementSpan
---@field l integer
---@field el integer

--- A read of a name that resolved to no local binding.
---@class typer.GlobalRead
---@field name string
---@field l integer
---@field c integer
---@field ec integer

--- One `require("...")` call site, with a literal module name.
---@class typer.RequireSite
---@field module string
---@field l integer
---@field c integer
---@field ec integer

---@class typer.FileModel
---@field path string
---@field chunk typer.Chunk
---@field docs typer.DocIndex
---@field is_meta boolean
---@field bindings typer.Binding[]
---@field globals table<string, typer.Binding>
---@field global_reads typer.GlobalRead[]
---@field functions typer.FuncInfo[]
---@field requires typer.RequireSite[]
---@field decl_tags typer.Tag[][]      -- doc blocks declaring ambient types
---@field statements typer.StatementSpan[]
---@field role string|nil
---@field source string|nil
---@field module_export typer.Binding|nil   -- the table this module returns
---@field qualified table<string, typer.FuncDecl>  -- global-rooted `a.b.c` signatures
---@field declared_globals table<string, typer.GlobalDecl>|nil

---@class typer.Walker
---@field model typer.FileModel
---@field scopes table<string, typer.Binding>[]
---@field fn_stack typer.FuncInfo[]
---@field pending_name string|nil     -- name the current expression is bound to
---@field pending_target typer.Node|nil    -- assignment target being written to
---@field pending_inherited typer.Inherited|nil  -- signature the slot already has

---@param walker typer.Walker
local function push_scope(walker)
    walker.scopes[#walker.scopes + 1] = {}
end

---@param walker typer.Walker
local function pop_scope(walker)
    walker.scopes[#walker.scopes] = nil
end

---@param walker typer.Walker
---@param name string
---@param binding typer.Binding
local function declare(walker, name, binding)
    walker.scopes[#walker.scopes][name] = binding
end

---@param walker typer.Walker
---@param name string
---@return typer.Binding|nil
local function lookup(walker, name)
    for i = #walker.scopes, 1, -1 do
        local found = walker.scopes[i][name]
        if found then
            return found
        end
    end
    return nil
end

--- Resolves an expression to the binding it names, when it names one.
---@param walker typer.Walker
---@param node typer.Node|nil
---@return typer.Binding|nil
local function resolve(walker, node)
    if not node then
        return nil
    end
    if node.k == "Name" then
        return lookup(walker, node.name) or walker.model.globals[node.name]
    end
    return nil
end

---@param node typer.Node|nil
---@return string
local function describe(node)
    if not node then
        return "?"
    end
    if node.k == "Name" then
        return node.name
    end
    if node.k == "Index" and not node.computed then
        return describe(node.obj) .. "." .. node.name
    end
    if node.k == "Index" then
        return describe(node.obj) .. "[...]"
    end
    return "?"
end

---@param node typer.Node|nil
---@return "table"|"function"|"require"|"scalar"|"other"
local function classify(node)
    if not node then
        return "other"
    end
    local kind = node.k
    if kind == "Table" then
        return "table"
    end
    if kind == "Function" then
        return "function"
    end
    if kind == "String" or kind == "Number" or kind == "True" or kind == "False" then
        return "scalar"
    end
    if kind == "Call" and node.callee and node.callee.k == "Name" and node.callee.name == "require" then
        return "require"
    end
    return "other"
end

--- The literal module name of a `require(...)` call, when it is a literal.
---@param node typer.Node|nil
---@return string|nil
local function require_module(node)
    if not node or node.k ~= "Call" then
        return nil
    end
    if not node.callee or node.callee.k ~= "Name" or node.callee.name ~= "require" then
        return nil
    end
    local first = node.args and node.args[1]
    if first and first.k == "String" then
        -- `v` is string|number across the literal kinds; a String node settles it.
        local value = first.v
        if type(value) == "string" then
            return value
        end
    end
    return nil
end

---@param binding typer.Binding
---@param tags typer.Tag[]
local function attach_tags(binding, tags)
    binding.tags = tags
    for _, tag in ipairs(tags) do
        if tag.kind == "class" then
            binding.class_tag = tag
        end
        if tag.kind == "enum" then
            binding.enum_tag = tag
        end
        if tag.kind == "type" and not binding.type_tag then
            binding.type_tag = tag
        end
    end
end

--- True when an `__index` value means inheritance rather than computed lookup.
---
--- `__index` says "look here on a miss", and the two things it can be answer
--- very different questions. A *table* is inheritance: instances fall back to a
--- base, which is the OOP pattern `missing-class` and `missing-inherit` exist to
--- catch. A *function* is a computed-lookup metamethod: it makes the table a
--- proxy over values generated on demand, which has no fields to declare and is
--- not a class. `setmetatable(output, { __index = function() ... end })` is a
--- lazy list, and `---@type string[]` describes it completely.
---@param value typer.Node|nil
---@return boolean
local function is_inheritance_index(value)
    return value ~= nil and value.k ~= "Function"
end

---@param binding typer.Binding
---@param signal string
---@param node typer.Node
local function add_signal(binding, signal, node)
    if not binding.signals[signal] then
        binding.signals[signal] = node
    end
end

--- The root `Name` of a dotted target: `a.b.c` -> `a`.
---@param node typer.Node|nil
---@return typer.Node|nil
local function root_name(node)
    while node and node.k == "Index" do
        node = node.obj
    end
    if node and node.k == "Name" then
        return node
    end
    return nil
end

--- The `fun(...)` at the root of a type expression, when there is one.
---@param node typer.TypeNode|nil
---@return typer.TypeNode|nil
local function fun_type(node)
    while node and (node.k == "optional" or node.k == "paren") do
        node = node.of
    end
    if node and node.k == "fun" then
        return node
    end
    return nil
end

--- The signature a doc block declares for the function below it, or nil when it
--- declares none.
---
--- The bar is that the block says *something* about the function -- a `---@type
--- fun(...)`, or at least one `---@param` / `---@return` / `---@overload`. That
--- is what makes the slot "already typed", and so what makes a later assignment
--- into it an override rather than a fresh declaration.
---@param tags typer.Tag[]
---@return typer.FuncDecl|nil
local function declared_signature(tags)
    local returns, described, overloaded = 0, false, false

    for _, tag in ipairs(tags) do
        if tag.kind == "type" then
            local fn = fun_type(tag.type)
            if fn then
                return { returns = #fn.returns }
            end
        elseif tag.kind == "return" then
            returns = returns + 1
            described = true
        elseif tag.kind == "param" or tag.kind == "vararg" then
            described = true
        elseif tag.kind == "overload" then
            -- An overload set has as many arities as it has lines; the count
            -- below stops meaning anything.
            overloaded = true
            described = true
        end
    end

    if not described then
        return nil
    end
    return { returns = returns, indeterminate = overloaded or nil }
end

--- True when a dotted path came out of `describe` intact, with no computed
--- index standing in for a key we cannot name.
---@param dotted string
---@return boolean
local function is_plain_path(dotted)
    return not dotted:find("[", 1, true) and not dotted:find("?", 1, true)
end

--- The declaration a function expression assigned to `target` would override.
---
--- Spec §1 says anything inline inherits its type from context. Being
--- syntactically inline is not what makes that true -- the slot already having a
--- declared type is. `vim.notify = function(message, level, ...)` re-binds a name
--- whose signature is stated in full in the runtime meta, and a `---@param`
--- written here is duplication typer cannot check and drift it cannot catch.
---
--- Four ways a slot arrives already typed, cheapest question first: a local or
--- parameter carrying a function type, a field defined earlier in this file, a
--- field of a module this file `require`s, and a global-rooted dotted name
--- declared anywhere in the index. The last two cannot be answered until every
--- file has been read, so they come back as a key for the rules to resolve.
---@param walker typer.Walker
---@param target typer.Node
---@return typer.Inherited|nil
local function inherited_slot(walker, target)
    if target.k == "Name" then
        local binding = lookup(walker, target.name) or walker.model.globals[target.name]
        local tag = binding and (binding.type_tag or binding.param_tag) or nil
        if not tag then
            return nil
        end
        local fn = fun_type(tag.type)
        if not fn then
            return nil
        end
        return {
            decl = { returns = #fn.returns },
            origin = ("'%s', typed at line %d"):format(target.name, tag.l),
        }
    end

    if target.k ~= "Index" or target.computed then
        return nil
    end

    local owner = resolve(walker, target.obj)
    if owner then
        -- Defined earlier in this same file, so the answer is already in hand.
        local entry = owner.methods[target.name]
        if entry and entry.decl then
            return {
                decl = entry.decl,
                origin = ("'%s.%s', declared at line %d"):format(owner.name, target.name, entry.l),
            }
        end
        -- A field of a module this file requires. Which file that is depends on
        -- the search path, so the lookup waits.
        if owner.module then
            return {
                key = "require:" .. owner.module .. ":" .. target.name,
                origin = ("'%s' in module '%s'"):format(target.name, owner.module),
            }
        end
        return nil
    end

    -- Rooted at a global: `vim.notify`, `vim.fn.jobstart`. The name is the same
    -- everywhere, so it is looked up in the project-wide index by that name.
    local root = root_name(target)
    local dotted = describe(target)
    if root and not lookup(walker, root.name) and is_plain_path(dotted) then
        return { key = "global:" .. dotted, origin = ("'%s'"):format(dotted) }
    end

    return nil
end

--- True when the expression drops a function literal straight into the slot
--- being assigned -- as itself, or through `x = x or function() end`, which is
--- how Lua spells a default. A fallback lands in the same slot as the value it
--- stands in for, so it is typed by the same annotation.
---@param node typer.Node|nil
---@return boolean
local function fills_slot_with_function(node)
    if not node then
        return false
    end
    if node.k == "Function" then
        return true
    end
    return node.k == "BinOp" and node.op == "or" and fills_slot_with_function(node.right)
end

--- Records a global-rooted function definition under its dotted name, so a file
--- that later re-binds it can find the signature it is overriding.
---
--- Only global roots are indexed. A module-local `M.f` would collide with every
--- other file's `M.f`, and those go through the module's own export table
--- instead.
---@param walker typer.Walker
---@param target typer.Node
---@param decl typer.FuncDecl|nil
local function record_qualified(walker, target, decl)
    if not decl or target.k ~= "Index" or target.computed then
        return
    end

    local root = root_name(target)
    if not root or lookup(walker, root.name) then
        return
    end

    local dotted = describe(target)
    if is_plain_path(dotted) and not walker.model.qualified[dotted] then
        walker.model.qualified[dotted] = decl
    end
end

--- In a `---@meta` file, `X.field = ...` asserts that the global `X` exists.
---
--- This is how definition files declare host-injected globals: Neovim's runtime
--- never assigns `vim` itself -- the C host does -- and its meta files only ever
--- write `vim.NIL = ...`. Restricted to meta files on purpose: in ordinary code
--- the same shape would let a typo (`vmi.x = 1`) declare itself.
---@param walker typer.Walker
---@param target typer.Node
local function declare_meta_global(walker, target)
    local model = walker.model
    if not model.is_meta then
        return
    end

    local root = root_name(target)
    if not root then
        return
    end
    if lookup(walker, root.name) or model.globals[root.name] then
        return
    end

    ---@type typer.Binding
    local binding = {
        name = root.name,
        l = root.l,
        c = root.c,
        ec = root.ec,
        scope = "global",
        kind = "table",
        signals = {},
        fields = {},
        methods = {},
        tags = {},
        host_declared = true,
    }
    model.globals[root.name] = binding
    -- Must also land in `bindings`: that is the list the registry walks when it
    -- collects global names, and `globals` alone never reaches the type index.
    model.bindings[#model.bindings + 1] = binding
end

---@type fun(walker: typer.Walker, block: typer.Node[])
local walk_block
---@type fun(walker: typer.Walker, node: typer.Node|nil, position: string|nil, tags: typer.Tag[]|nil)
local walk_expr
---@type fun(walker: typer.Walker, node: typer.Node)
local walk_stat

--- Records a `Function` node. `owner` is the class binding for methods.
---@param walker typer.Walker
---@param node typer.Node
---@param tags typer.Tag[]
---@param display string
---@param anchor typer.Anchor
---@param owner typer.Binding|nil
---@param exempt boolean
---@return typer.FuncInfo
local function enter_function(walker, node, tags, display, anchor, owner, exempt)
    ---@type typer.FuncInfo
    local info = {
        node = node,
        tags = tags or {},
        display = display,
        l = anchor.l,
        c = anchor.c,
        ec = anchor.ec or anchor.c,
        is_method = node.is_method or false,
        return_arity = 0,
        has_value_return = false,
        has_nil_return = false,
        owner = owner,
        exempt = exempt or false,
        -- Claimed, not read: a nested function inside this body must not pick up
        -- the slot this one was assigned into.
        inherited = walker.pending_inherited,
    }
    walker.pending_inherited = nil
    walker.model.functions[#walker.model.functions + 1] = info

    walker.fn_stack[#walker.fn_stack + 1] = info
    push_scope(walker)

    -- A parameter typed `---@param cb fun(...)` is a slot like any other: the
    -- `cb = cb or function() end` default assigned into it inherits that type.
    ---@type table<string, typer.Tag>
    local param_tags = {}
    for _, tag in ipairs(tags or {}) do
        if tag.kind == "param" and tag.name then
            param_tags[tag.name] = tag
        end
    end

    for _, param in ipairs(node.params) do
        declare(walker, param.name, {
            name = param.name,
            l = param.l,
            c = param.c,
            ec = param.ec,
            scope = "local",
            kind = "other",
            signals = {},
            fields = {},
            methods = {},
            tags = {},
            param_tag = param_tags[param.name],
            is_self = param.name == "self" and node.is_method or nil,
            class_owner = param.name == "self" and owner or nil,
        })
    end

    walk_block(walker, node.body)

    pop_scope(walker)
    walker.fn_stack[#walker.fn_stack] = nil

    return info
end

--- Walks an expression. `position` tells whether a function/table literal here
--- is named (needs its own annotation) or inline (typed by its context).
---@param walker typer.Walker
---@param node typer.Node|nil
---@param position "named"|"inline"|nil
---@param tags typer.Tag[]|nil   -- doc block of the statement doing the naming
walk_expr = function(walker, node, position, tags)
    if not node then
        return
    end
    local kind = node.k

    if kind == "Name" then
        local binding = lookup(walker, node.name)
        if not binding then
            local model = walker.model
            if not model.globals[node.name] then
                model.global_reads[#model.global_reads + 1] = {
                    name = node.name,
                    l = node.l,
                    c = node.c,
                    ec = node.ec,
                }
            end
        end
    elseif kind == "Index" then
        walk_expr(walker, node.obj)
        if node.computed then
            walk_expr(walker, node.key)
        end
    elseif kind == "Call" then
        -- An immediately-invoked function expression is inline by definition:
        -- `(function() ... end)()` is an expression, not a named function.
        walk_expr(walker, node.callee, "inline")

        local module = require_module(node)
        if module then
            walker.model.requires[#walker.model.requires + 1] = {
                module = module,
                l = node.l,
                c = node.c,
                ec = node.ec,
            }
        end

        -- `setmetatable(x, M)` marks M as class-shaped; `setmetatable(M, {__index=B})`
        -- marks M as inheriting from B.
        if
            node.callee
            and node.callee.k == "Name"
            and node.callee.name == "setmetatable"
            and node.args
            and #node.args >= 2
        then
            local first, second = node.args[1], node.args[2]

            local meta_binding = resolve(walker, second)
            if meta_binding then
                add_signal(meta_binding, "metatable", node)
            end

            local target = resolve(walker, first)
            if target then
                if second.k == "Table" then
                    for _, field in ipairs(second.fields) do
                        if field.kind == "named" and field.name == "__index" then
                            local base = resolve(walker, field.value)
                            if base ~= target and is_inheritance_index(field.value) then
                                target.inherits = field.value
                                add_signal(target, "index", node)
                            end
                        end
                    end
                elseif meta_binding and meta_binding ~= target then
                    target.inherits = second
                    add_signal(target, "index", node)
                end
            end
        end

        for _, arg in ipairs(node.args or {}) do
            walk_expr(walker, arg, "inline")
        end
    elseif kind == "MethodCall" then
        walk_expr(walker, node.obj)
        for _, arg in ipairs(node.args or {}) do
            walk_expr(walker, arg, "inline")
        end
    elseif kind == "Function" then
        if position == "inline" then
            -- Typed by the callee's `---@param` / the field's `---@field`.
            enter_function(walker, node, {}, "<anonymous>", node, nil, true)
        else
            -- Named by the statement that binds it, so it inherits that doc block.
            enter_function(walker, node, tags or {}, walker.pending_name or "<anonymous>", node, nil, false)
        end
    elseif kind == "Table" then
        for _, field in ipairs(node.fields) do
            if field.kind == "computed" then
                walk_expr(walker, field.key)
            end
            walk_expr(walker, field.value, "inline")
        end
    elseif kind == "BinOp" then
        walk_expr(walker, node.left)
        walk_expr(walker, node.right)
    elseif kind == "UnOp" then
        walk_expr(walker, node.operand)
    elseif kind == "Paren" then
        walk_expr(walker, node.expr, position, tags)
    end
end

--- Records `T.field = value` / `self.field = value` against the owning binding.
---
--- `tags` is the doc block of the assigning statement: a field annotated with
--- `---@type` at its assignment is already declared, and demanding a matching
--- `---@field` on the class as well would be two annotations for one fact.
---@param walker typer.Walker
---@param target typer.Node
---@param value typer.Node|nil
---@param tags typer.Tag[]|nil
local function record_field_assignment(walker, target, value, tags)
    if target.k ~= "Index" or target.computed then
        return
    end

    local owner = resolve(walker, target.obj)

    -- `self` is a binding in its own right -- the implicit parameter of a `:`
    -- method, or the `local self = setmetatable({}, T)` of a constructor -- so
    -- resolving it succeeds and we must then redirect to the class it stands for.
    -- Without this, every constructor-assigned field goes unnoticed.
    if owner and owner.class_owner then
        add_signal(owner.class_owner, "self-assign", target)
        owner = owner.class_owner
    end

    if not owner then
        return
    end

    local annotated = false
    for _, tag in ipairs(tags or {}) do
        if tag.kind == "type" then
            annotated = true
            break
        end
    end

    local field_name = target.name
    ---@type typer.FieldEntry
    local entry = {
        name = field_name,
        l = target.key_l or target.l,
        c = target.key_c or target.c,
        ec = target.key_ec or target.ec,
        is_function = value ~= nil and value.k == "Function",
        annotated = annotated,
        decl = value ~= nil and value.k == "Function" and declared_signature(tags or {}) or nil,
    }

    if field_name == "__index" then
        if is_inheritance_index(value) then
            local base = resolve(walker, value)
            if base ~= owner then
                owner.inherits = value
            end
            add_signal(owner, "index", target)
        end
        return
    end

    if entry.is_function then
        record_qualified(walker, target, entry.decl)
        owner.methods[field_name] = entry
    else
        owner.fields[field_name] = entry
    end
end

---@param walker typer.Walker
---@param node typer.Node
walk_stat = function(walker, node)
    local model = walker.model
    local kind = node.k

    -- Statement spans let `-- typer: ignore` cover a whole multi-line statement.
    model.statements[#model.statements + 1] = { l = node.l, el = node.el }

    if kind == "Local" then
        local tags = docblock.tags_for(model.docs, node)

        -- Initialisers are evaluated before the names come into scope. The doc
        -- block must be threaded in here: a `local f = function() end` is a named
        -- function and its annotations live on the statement, not on the literal.
        for index, expr in ipairs(node.exprs or {}) do
            walker.pending_name = node.names[index] and node.names[index].name or nil
            walk_expr(walker, expr, "named", tags)
        end
        walker.pending_name = nil

        for index, name_info in ipairs(node.names) do
            local init = node.exprs and node.exprs[index] or nil
            -- `local a, b = f()` -- only the first name takes the call as initialiser.
            local has_own_init = node.exprs ~= nil and node.exprs[index] ~= nil
            local init_kind = has_own_init and classify(init) or "bare"

            if node.exprs and not has_own_init and #node.exprs > 0 then
                init_kind = "other" -- filled from a multi-value expression
            end
            if has_own_init and init and init.k == "Nil" then
                init_kind = "bare"
            end

            ---@type typer.Binding
            local binding = {
                name = name_info.name,
                l = name_info.l,
                c = name_info.c,
                ec = name_info.ec,
                scope = "local",
                kind = init_kind,
                decl = node,
                init = init,
                index = index,
                count = #node.names,
                explicit_nil = has_own_init and init and init.k == "Nil" or false,
                signals = {},
                fields = {},
                methods = {},
                tags = {},
                module = init_kind == "require" and require_module(init) or nil,
            }
            attach_tags(binding, tags)
            model.bindings[#model.bindings + 1] = binding
            declare(walker, name_info.name, binding)

            -- `local self = setmetatable({}, T)` -- the canonical constructor. Later
            -- `self.field = ...` assignments belong to T, not to this local.
            if
                init
                and init.k == "Call"
                and init.callee
                and init.callee.k == "Name"
                and init.callee.name == "setmetatable"
                and init.args
                and init.args[2]
            then
                binding.class_owner = resolve(walker, init.args[2])
            end

            if init and init.k == "Table" then
                for _, field in ipairs(init.fields) do
                    if field.kind == "named" then
                        binding.fields[field.name] = {
                            name = field.name,
                            l = field.l,
                            c = field.c,
                            ec = field.ec,
                            is_function = field.value and field.value.k == "Function",
                            in_constructor = true,
                        }
                        if field.value and field.value.k == "Function" then
                            binding.methods[field.name] = binding.fields[field.name]
                            binding.fields[field.name] = nil
                        end
                    end
                end
            end
        end
    elseif kind == "LocalFunction" then
        local tags = docblock.tags_for(model.docs, node)
        ---@type typer.Binding
        local binding = {
            name = node.name,
            l = node.name_l,
            c = node.name_c,
            ec = node.name_ec,
            scope = "local",
            kind = "function",
            decl = node,
            init = node.fn,
            signals = {},
            fields = {},
            methods = {},
            tags = {},
        }
        attach_tags(binding, tags)
        model.bindings[#model.bindings + 1] = binding
        -- Declared before the body so the function can recurse.
        declare(walker, node.name, binding)
        enter_function(walker, node.fn, tags, node.name, node, nil, false)
    elseif kind == "FunctionStat" then
        local tags = docblock.tags_for(model.docs, node)
        local target = node.target
        local display = describe(target)

        ---@type typer.Binding|nil
        local owner = nil
        if target.k == "Index" and not target.computed then
            declare_meta_global(walker, target)
            local decl = declared_signature(tags)
            record_qualified(walker, target, decl)
            owner = resolve(walker, target.obj)
            if owner then
                if node.is_method then
                    add_signal(owner, "colon-method", node)
                end
                owner.methods[target.name] = {
                    name = target.name,
                    l = target.key_l or target.l,
                    c = target.key_c or target.c,
                    ec = target.key_ec or target.ec,
                    is_function = true,
                    decl = decl,
                }
            end
            walk_expr(walker, target.obj)
        elseif target.k == "Name" then
            local existing = lookup(walker, target.name)
            if not existing and not model.globals[target.name] then
                ---@type typer.Binding
                local binding = {
                    name = target.name,
                    l = target.l,
                    c = target.c,
                    ec = target.ec,
                    scope = "global",
                    kind = "function",
                    decl = node,
                    init = node.fn,
                    signals = {},
                    fields = {},
                    methods = {},
                    tags = {},
                }
                attach_tags(binding, tags)
                model.globals[target.name] = binding
                model.bindings[#model.bindings + 1] = binding
            end
        end

        enter_function(walker, node.fn, tags, display, node, owner, false)
    elseif kind == "Assign" then
        local tags = docblock.tags_for(model.docs, node)

        for index, expr in ipairs(node.exprs) do
            local target = node.targets[index]
            walker.pending_name = target and describe(target) or nil
            -- Only when a function literal actually lands in the slot: anything
            -- else would leak it into an unrelated nested closure.
            if target and fills_slot_with_function(expr) then
                walker.pending_inherited = inherited_slot(walker, target)
            end
            walk_expr(walker, expr, "named", tags)
            walker.pending_inherited = nil
        end
        walker.pending_name = nil

        for index, target in ipairs(node.targets) do
            local value = node.exprs[index]

            if target.k == "Name" then
                local existing = lookup(walker, target.name)
                if existing then
                    -- Assignment to an existing local; may reveal a table shape late.
                    if value and value.k == "Table" and existing.kind == "bare" then
                        existing.late_table = true
                    end
                else
                    local global = model.globals[target.name]
                    if global then
                        if value then
                            global.reassigned = true
                        end
                    else
                        ---@type typer.Binding
                        local binding = {
                            name = target.name,
                            l = target.l,
                            c = target.c,
                            ec = target.ec,
                            scope = "global",
                            kind = classify(value),
                            decl = node,
                            init = value,
                            signals = {},
                            fields = {},
                            methods = {},
                            tags = {},
                            module = classify(value) == "require" and require_module(value) or nil,
                        }
                        attach_tags(binding, tags)
                        model.globals[target.name] = binding
                        model.bindings[#model.bindings + 1] = binding

                        if value and value.k == "Table" then
                            for _, field in ipairs(value.fields) do
                                if field.kind == "named" then
                                    ---@type typer.FieldEntry
                                    local entry = {
                                        name = field.name,
                                        l = field.l,
                                        c = field.c,
                                        ec = field.ec,
                                        is_function = field.value and field.value.k == "Function",
                                        in_constructor = true,
                                    }
                                    if entry.is_function then
                                        binding.methods[field.name] = entry
                                    else
                                        binding.fields[field.name] = entry
                                    end
                                end
                            end
                        end
                    end
                end
            else
                declare_meta_global(walker, target)
                walk_expr(walker, target.obj)
                if target.computed then
                    walk_expr(walker, target.key)
                end
                record_field_assignment(walker, target, value, tags)
            end
        end
    elseif kind == "Return" then
        local current = walker.fn_stack[#walker.fn_stack]
        local exprs = node.exprs

        if exprs and #exprs > 0 then
            if current then
                current.has_value_return = true
                if #exprs > current.return_arity then
                    current.return_arity = #exprs
                end

                -- A call or `...` in the LAST position expands to an unknown number of
                -- values, so the arity becomes a lower bound, not an exact count.
                -- `return f()` is far too common to get this wrong.
                local last = exprs[#exprs]
                if last.k == "Call" or last.k == "MethodCall" or last.k == "Vararg" then
                    current.indeterminate_arity = true
                end

                for _, expr in ipairs(exprs) do
                    if expr.k == "Nil" then
                        current.has_nil_return = true
                    end
                end
            elseif not model.module_export then
                -- `return M` at the top of the file: the table this module hands
                -- out. Its functions are the module's public signatures, which is
                -- what another file's `mod.f = function() end` overrides.
                model.module_export = resolve(walker, exprs[1])
            end
        end

        local return_tags = docblock.tags_for(model.docs, node)
        local own = declared_signature(return_tags) ~= nil
        local declared_returns = current and docblock.find_all(current.tags, "return") or {}

        for index, expr in ipairs(exprs or {}) do
            -- A returned function literal is named by its return position and takes
            -- the doc block sitting above the `return`.
            if expr.k == "Function" then
                -- When there is no such block, the name it was given is the
                -- enclosing `---@return`. `---@return fun(): string` declares this
                -- closure as surely as a `---@type` would, so it does not declare
                -- itself a second time -- but the arity it now claims is a claim
                -- that can be wrong, and that is left to check.
                if not own then
                    local fn = declared_returns[index] and fun_type(declared_returns[index].type) or nil
                    if fn then
                        walker.pending_inherited = {
                            decl = { returns = #fn.returns },
                            origin = ("the enclosing ---@return at line %d"):format(declared_returns[index].l),
                        }
                    end
                end
                walk_expr(walker, expr, "named", return_tags)
                walker.pending_inherited = nil
            else
                walk_expr(walker, expr, "inline", return_tags)
            end
        end
    elseif kind == "CallStat" then
        walk_expr(walker, node.expr)
    elseif kind == "If" then
        for _, clause in ipairs(node.clauses) do
            walk_expr(walker, clause.cond)
            push_scope(walker)
            walk_block(walker, clause.body)
            pop_scope(walker)
        end
        if node.else_body then
            push_scope(walker)
            walk_block(walker, node.else_body)
            pop_scope(walker)
        end
    elseif kind == "While" then
        walk_expr(walker, node.cond)
        push_scope(walker)
        walk_block(walker, node.body)
        pop_scope(walker)
    elseif kind == "Repeat" then
        push_scope(walker)
        walk_block(walker, node.body)
        walk_expr(walker, node.cond) -- the condition sees the body's locals
        pop_scope(walker)
    elseif kind == "Do" then
        push_scope(walker)
        walk_block(walker, node.body)
        pop_scope(walker)
    elseif kind == "ForNum" then
        walk_expr(walker, node.from)
        walk_expr(walker, node.to)
        walk_expr(walker, node.step)
        push_scope(walker)
        declare(walker, node.var.name, {
            name = node.var.name,
            l = node.var.l,
            c = node.var.c,
            ec = node.var.ec,
            scope = "local",
            kind = "scalar",
            signals = {},
            fields = {},
            methods = {},
            tags = {},
            loop_var = true,
        })
        walk_block(walker, node.body)
        pop_scope(walker)
    elseif kind == "ForIn" then
        for _, expr in ipairs(node.exprs) do
            walk_expr(walker, expr)
        end
        push_scope(walker)
        for _, name_info in ipairs(node.names) do
            declare(walker, name_info.name, {
                name = name_info.name,
                l = name_info.l,
                c = name_info.c,
                ec = name_info.ec,
                scope = "local",
                kind = "other",
                signals = {},
                fields = {},
                methods = {},
                tags = {},
                loop_var = true,
            })
        end
        walk_block(walker, node.body)
        pop_scope(walker)
    end
end

---@param walker typer.Walker
---@param block typer.Node[]
walk_block = function(walker, block)
    for _, statement in ipairs(block) do
        walk_stat(walker, statement)
    end
end

--- Tags that put a name into the ambient type index (spec §8.2).
---@type table<string, boolean>
local AMBIENT_TAGS = { class = true, alias = true, enum = true }

--- True when a doc block declares a type name, and so must be indexed whatever
--- statement it was bound to.
---@param tags typer.Tag[]
---@return boolean
local function declares_ambient_type(tags)
    for _, tag in ipairs(tags) do
        if AMBIENT_TAGS[tag.kind] and tag.name then
            return true
        end
    end
    return false
end

--- Signals that make a table class-shaped, in the order that reads best in a
--- message.
---@type string[]
local CLASS_SIGNALS = { "colon-method", "index", "metatable", "self-assign" }

---@type table<string, string>
local CLASS_SIGNAL_REASON = {
    ["colon-method"] = "defines ':' methods",
    ["index"] = "assigns __index",
    ["metatable"] = "is used as a metatable",
    ["self-assign"] = "assigns fields on 'self'",
}

--- True when every member of a table is a function, and there is at least one.
---
--- This is the module preamble -- `local M = {}` / `local _P = {}` with
--- `function M.f() end` below it -- and §1's question, literal or class, has no
--- answer to give about it. A namespace has no data whose shape a reader needs;
--- every member is a function that annotates itself. What an annotation would
--- add is a *nameable* type, which is worth having only if someone writes the
--- name, and in practice nobody does: in typer's own source, 19 of 26 module
--- class names appear in no type position anywhere.
---
--- So this is split out of `table-decl` as `namespace-decl` rather than folded
--- into it, and ships `off`. A project that does want its modules named turns it
--- back on in one line -- typer's own `.typer.lua` does -- and the tables that
--- really are opaque still report under `table-decl`.
---@param binding typer.Binding
---@return boolean
function M.is_namespace(binding)
    if next(binding.fields) ~= nil then
        return false
    end
    return next(binding.methods) ~= nil
end

--- The reason a binding looks like a class, or nil when it does not. Shared with
--- the class rules so `table-decl` can stand down when the more specific
--- `missing-class` applies.
---@param binding typer.Binding
---@return string|nil
function M.class_shape_reason(binding)
    for _, signal in ipairs(CLASS_SIGNALS) do
        if binding.signals[signal] then
            return CLASS_SIGNAL_REASON[signal]
        end
    end
    return nil
end

--- Analyses a parsed chunk.
---@param path string
---@param chunk typer.Chunk
---@return typer.FileModel
function M.run(path, chunk)
    local docs = docblock.build(chunk)

    ---@type typer.FileModel
    local model = {
        path = path,
        chunk = chunk,
        docs = docs,
        is_meta = docs.is_meta,
        bindings = {},
        globals = {},
        global_reads = {},
        functions = {},
        requires = {},
        decl_tags = {},
        statements = {},
        qualified = {},
    }

    ---@type typer.Walker
    local walker = { model = model, scopes = {}, fn_stack = {} }
    push_scope(walker)
    walk_block(walker, chunk.body)
    pop_scope(walker)

    -- Doc blocks not claimed by any statement still declare ambient types: a file
    -- may consist of nothing but `---@class` comments (spec §8.2).
    --
    -- A *claimed* block normally reaches the index through the binding or the
    -- function it annotates -- but a statement that produces neither drops it on
    -- the floor, and `M.Field = {}` is exactly that statement. The name in a
    -- `---@class` / `---@alias` / `---@enum` is self-contained: nothing about it
    -- depends on whether a local, a field assignment, or no code at all sits
    -- below. So the block is indexed from itself whatever it was bound to, and
    -- folding the same run in twice is a no-op (registry.insert is idempotent).
    for _, block in ipairs(docs.blocks) do
        if #block.tags > 0 and (not block.consumed or declares_ambient_type(block.tags)) then
            model.decl_tags[#model.decl_tags + 1] = block.tags
        end
    end

    return model
end

return M
