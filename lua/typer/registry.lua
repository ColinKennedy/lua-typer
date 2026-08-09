--- The ambient type index (spec §8.2).
---
--- LuaLS's type namespace is flat and global: a `---@class Foo` declared in any
--- indexed file makes `Foo` resolvable everywhere, with no `require` needed.
--- typer mirrors that exactly, which is what makes "class declared in one file,
--- used in another" work.
---@class typer.registry
local M = {}

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
---@field is_stub boolean|nil        -- came from a `---@meta` stub, which outranks source
---@field alias_type typer.TypeNode|nil   -- the aliased type, for kind == "alias"
---@field tag typer.Tag|nil          -- the tag that declared it

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
        elseif tag.kind == "alias" and tag.name then
            insert(registry, {
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
            })
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
            current_class = nil
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

--- Everything a file contributes to the index, reduced to plain data: tag runs
--- in source order plus the globals it declares. This is the unit the on-disk
--- cache stores, so a warm run can fold a file in without parsing it.
---@class typer.IndexSlice
---@field tag_runs typer.Tag[][]
---@field globals typer.GlobalDecl[]
---@field is_meta boolean

--- Reduces an analysed file to its index slice.
---@param model typer.FileModel
---@return typer.IndexSlice
function M.slice_of(model)
    ---@type typer.Tag[][]
    local tag_runs = {}
    ---@type typer.GlobalDecl[]
    local globals = {}

    for _, tags in ipairs(model.decl_tags) do
        tag_runs[#tag_runs + 1] = tags
    end

    for _, binding in ipairs(model.bindings) do
        if #binding.tags > 0 then
            tag_runs[#tag_runs + 1] = binding.tags
        end
        -- Any global *assignment* makes the name exist, annotated or not: that is
        -- what `undefined-global` asks about. Whether the assignment site is
        -- properly declared is a separate question, answered by `global-decl` at
        -- that site -- and only in checked files.
        if binding.scope == "global" then
            globals[#globals + 1] = {
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
            tag_runs[#tag_runs + 1] = info.tags
        end
    end

    if model.declared_globals then
        for _, entry in pairs(model.declared_globals) do
            globals[#globals + 1] = entry
        end
    end

    return { tag_runs = tag_runs, globals = globals, is_meta = model.is_meta }
end

--- Folds a slice into the registry. A slice read back from the cache and one
--- taken from a freshly parsed file go through this same path, so a warm run
--- and a cold one build an identical index.
---@param registry typer.Registry
---@param file string
---@param slice typer.IndexSlice
---@param opts typer.IndexOptions
function M.index_slice(registry, file, slice, opts)
    opts = opts or {}

    -- Idempotent per file. A checked file that also sits under a `source_root` is
    -- reached twice -- once by the eager workspace scan, once by the checked pass
    -- -- and indexing it twice registers every declaration twice, which shows up
    -- as each `duplicate-class` being reported two times.
    if registry.indexed[file] then
        return
    end
    registry.indexed[file] = true

    for _, tags in ipairs(slice.tag_runs) do
        index_tags(registry, tags, file, opts)
    end

    for _, entry in ipairs(slice.globals) do
        registry.globals[entry.name] = entry
    end
end

--- Indexes one analysed file into the registry.
---@param registry typer.Registry
---@param model typer.FileModel
---@param opts typer.IndexOptions
function M.index_file(registry, model, opts)
    M.index_slice(registry, model.path, M.slice_of(model), opts)
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
local function walk_parents(registry, decl, visit)
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
    walk_parents(registry, decl, function(current)
        if current.fields[field] then
            found = true
        end
    end)
    return found
end

return M
