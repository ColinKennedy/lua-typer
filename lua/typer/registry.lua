--- The ambient type index (spec §8.2).
---
--- LuaLS's type namespace is flat and global: a `---@class Foo` declared in any
--- indexed file makes `Foo` resolvable everywhere, with no `require` needed.
--- typer mirrors that exactly, which is what makes "class declared in one file,
--- used in another" work.
---@class typer.registry
local M = {}

local types = require("typer.annot.types")

---@class typer.TypeDecl
---@field name string
---@field kind "class"|"alias"|"enum"
---@field file string
---@field l integer
---@field c integer
---@field ec integer
---@field fields table<string, typer.Tag>
---@field parents typer.TypeNode[]
---@field generics table<string, boolean>
---@field checked boolean            -- declared in a file that is being reported on

--- Two declarations of the same name, reported at both sites.
---@class typer.DuplicateDecl
---@field first typer.TypeDecl
---@field second typer.TypeDecl

--- A global name known to exist somewhere in the index.
---@class typer.GlobalDecl
---@field name string
---@field file string
---@field l integer
---@field c integer
---@field annotated boolean|nil

--- How a file is being indexed.
---@class typer.IndexOptions
---@field checked boolean
---@field is_stub boolean

---@class typer.Registry
---@field decls table<string, typer.TypeDecl>
---@field duplicates typer.DuplicateDecl[]
---@field globals table<string, typer.GlobalDecl>
---@field modules table<string, string>   -- module name -> declaring file
---@field generic_hints table<string, boolean>|nil
---@field indexed table<string, boolean>  -- files already folded in

---@return typer.Registry
function M.new()
    return { decls = {}, duplicates = {}, globals = {}, modules = {}, indexed = {} }
end

---@param registry typer.Registry
---@param decl typer.TypeDecl
local function insert(registry, decl)
    local existing = registry.decls[decl.name]
    if existing then
        -- Stub files intentionally outrank real source, so a stub replacing a
        -- source declaration is not a conflict.
        if existing.is_stub ~= decl.is_stub then
            if decl.is_stub then
                registry.decls[decl.name] = decl
            end
            return
        end
        if existing.file == decl.file and existing.l == decl.l then
            return
        end
        registry.duplicates[#registry.duplicates + 1] = { first = existing, second = decl }
        return
    end
    registry.decls[decl.name] = decl
end

--- Extracts every ambient declaration from a tag run.
---@param registry typer.Registry
---@param tags typer.Tag[]
---@param file string
---@param opts typer.IndexOptions
local function index_tags(registry, tags, file, opts)
    ---@type typer.TypeDecl|nil
    local current_class = nil

    for _, tag in ipairs(tags) do
        if tag.kind == "class" and tag.name then
            current_class = {
                name = tag.name,
                kind = "class",
                file = file,
                l = tag.l,
                c = tag.name_col or tag.c,
                ec = tag.name_ec or tag.c,
                fields = {},
                parents = tag.parents or {},
                generics = {},
                checked = opts.checked,
                is_stub = opts.is_stub,
                tag = tag,
            }
            for _, generic in ipairs(tag.generics or {}) do
                current_class.generics[generic] = true
            end
            insert(registry, current_class)
            current_alias = nil
        elseif tag.kind == "alias" and tag.name then
            current_alias = {
                name = tag.name,
                kind = "alias",
                file = file,
                l = tag.l,
                c = tag.name_col or tag.c,
                ec = tag.name_ec or tag.c,
                fields = {},
                parents = {},
                generics = {},
                alias_type = tag.type,
                checked = opts.checked,
                is_stub = opts.is_stub,
                tag = tag,
            }
            insert(registry, current_alias)
            current_class = nil
        elseif tag.kind == "enum" and tag.name then
            insert(registry, {
                name = tag.name,
                kind = "enum",
                file = file,
                l = tag.l,
                c = tag.name_col or tag.c,
                ec = tag.name_ec or tag.c,
                fields = {},
                parents = {},
                generics = {},
                checked = opts.checked,
                is_stub = opts.is_stub,
                tag = tag,
            })
            current_class, current_alias = nil, nil
        elseif tag.kind == "field" and current_class and tag.name then
            current_class.fields[tag.name] = tag
        elseif tag.kind == "generic" then
            -- Generic parameters are in scope for the declaration that follows.
            for _, name in ipairs(tag.names or {}) do
                registry.generic_hints = registry.generic_hints or {}
                registry.generic_hints[name] = true
            end
        elseif tag.kind ~= "field" and tag.kind ~= "alias-item" then
            current_class = nil
        end
    end
end

--- Indexes one analysed file into the registry.
---@param registry typer.Registry
---@param model typer.FileModel
---@param opts typer.IndexOptions
function M.index_file(registry, model, opts)
    opts = opts or {}

    -- Idempotent per file. A checked file that also sits under a `source_root` is
    -- reached twice -- once by the eager workspace scan, once by the checked pass
    -- -- and indexing it twice registers every declaration twice, which shows up
    -- as each `duplicate-class` being reported two times.
    if registry.indexed[model.path] then
        return
    end
    registry.indexed[model.path] = true

    for _, tags in ipairs(model.decl_tags) do
        index_tags(registry, tags, model.path, opts)
    end

    for _, binding in ipairs(model.bindings) do
        if #binding.tags > 0 then
            index_tags(registry, binding.tags, model.path, opts)
        end
        -- Any global *assignment* makes the name exist, annotated or not: that is
        -- what `undefined-global` asks about. Whether the assignment site is
        -- properly declared is a separate question, answered by `global-decl` at
        -- that site -- and only in checked files.
        if binding.scope == "global" then
            registry.globals[binding.name] = {
                name = binding.name,
                file = model.path,
                l = binding.l,
                c = binding.c,
                annotated = (binding.type_tag or binding.class_tag) ~= nil,
            }
        end
    end

    for _, info in ipairs(model.functions) do
        if #info.tags > 0 then
            index_tags(registry, info.tags, model.path, opts)
        end
    end

    if model.declared_globals then
        for name, entry in pairs(model.declared_globals) do
            registry.globals[name] = entry
        end
    end
end

--- Registers a global name as declared (used by stdlib stubs).
---@param registry typer.Registry
---@param name string
---@param file string
function M.declare_global(registry, name, file)
    if not registry.globals[name] then
        registry.globals[name] = { name = name, file = file, l = 1, c = 1 }
    end
end

---@param registry typer.Registry
---@param name string
---@return typer.TypeDecl|nil
function M.resolve(registry, name)
    return registry.decls[name]
end

--- Walks a class's inheritance chain, yielding each declaration once.
---@param registry typer.Registry
---@param decl typer.TypeDecl
---@param visit fun(decl: typer.TypeDecl)
function M.walk_parents(registry, decl, visit)
    ---@type table<string, boolean>
    local seen = { [decl.name] = true }
    ---@type typer.TypeDecl[]
    local queue = { decl }

    while #queue > 0 do
        local current = table.remove(queue, 1)
        visit(current)

        for _, parent in ipairs(current.parents or {}) do
            -- Only named parents participate; a structural parent has no declaration.
            local root = parent
            while root and (root.k == "paren" or root.k == "optional" or root.k == "array") do
                root = root.of
            end
            if root and root.k == "name" and not seen[root.name] then
                seen[root.name] = true
                local parent_decl = registry.decls[root.name]
                if parent_decl then
                    queue[#queue + 1] = parent_decl
                end
            end
        end
    end
end

--- True when `field` is declared on `decl` or anywhere in its parent chain.
---@param registry typer.Registry
---@param decl typer.TypeDecl
---@param field string
---@return boolean
function M.has_field(registry, decl, field)
    local found = false
    M.walk_parents(registry, decl, function(current)
        if current.fields[field] then
            found = true
        end
    end)
    return found
end

return M
