--- The driver: resolves the file set, builds the type index, runs the rules.
---
--- File roles (spec §8.1) decide who gets *reported on*:
---   checked   -- passed on the command line: indexed AND reported
---   workspace -- under source_roots: indexed only
---   library   -- reached via require: indexed only
---   stub      -- `---@meta` definitions: indexed only
---
--- Third-party code is read for its declarations and never reported on, which
--- is mypy's `follow_imports = silent`.
---@class typer.check
local M = {}

local compat = require("typer.compat")
local fs = require("typer.fs")
local parser = require("typer.parser")
local analyze = require("typer.analyze")
local registry_mod = require("typer.registry")
local diagnostic = require("typer.diagnostic")
local suppress = require("typer.suppress")
local config_mod = require("typer.config")
local search_mod = require("typer.resolve.search")
local modpath = require("typer.resolve.modpath")
local cache_mod = require("typer.resolve.cache")

local RULES = {
  require("typer.rules.declarations"),
  require("typer.rules.functions"),
  require("typer.rules.classes"),
  require("typer.rules.completeness"),
  require("typer.rules.globals"),
}

---@class typer.Run
---@field config typer.Config
---@field search typer.SearchPath
---@field registry typer.Registry
---@field diagnostics typer.Diagnostic[]
---@field models table<string, typer.FileModel>
---@field checked string[]
---@field indexed_count integer
---@field cwd string
---@field cache typer.Cache
---@field model_cache table<string, typer.ModelCacheEntry>|nil
---@field reused integer|nil
---@field had_parse_error boolean|nil

--- One entry of the daemon's persistent model cache.
---@class typer.ModelCacheEntry
---@field model typer.FileModel
---@field signature string|nil
---@field source string

--- What every rule receives. `emit` is the only way a rule reports anything.
---@class typer.RuleContext
---@field config typer.Config
---@field registry typer.Registry
---@field emit fun(diag: typer.Diagnostic)

--- Totals for the reporters.
---@class typer.Summary
---@field files integer
---@field indexed integer
---@field errors integer
---@field warnings integer
---@field hints integer
---@field had_parse_error boolean

--- A rule module.
---@class typer.Rule
---@field run fun(model: typer.FileModel, ctx: typer.RuleContext)

--- Options accepted by `M.run`.
---@class typer.CheckOptions
---@field config typer.Config|nil
---@field stub_paths string[]|nil
---@field lua_path string[]|nil
---@field inherit_path boolean|nil
---@field no_suppress boolean|nil
---@field use_cache boolean|nil
---@field model_cache table<string, typer.ModelCacheEntry>|nil
---@field cwd string|nil

---@param run typer.Run
---@param diag typer.Diagnostic
local function emit(run, diag)
  run.diagnostics[#run.diagnostics + 1] = diag
end

--- Parses and analyses a file once, memoised by path.
---@param run typer.Run
---@param path string
---@param role string
---@return typer.FileModel|nil
---@return table|nil parse_error
local function load_model(run, path, role)
  local normalized = compat.absolute(path, run.cwd)
  local existing = run.models[normalized]
  if existing then return existing, nil end

  -- A persistent cache (the daemon's) keeps parsed models across checks. The
  -- file is re-validated every time, so an edited file always re-parses.
  local persistent = run.model_cache
  local entry = persistent and persistent[normalized] or nil
  local signature = entry and fs.signature(normalized) or nil

  if entry and signature and signature == entry.signature then
    -- lfs present: one stat, no read at all.
    run.models[normalized] = entry.model
    run.indexed_count = run.indexed_count + 1
    run.reused = (run.reused or 0) + 1
    return entry.model, nil
  end

  local source = compat.read_file(normalized)
  if not source then
    if persistent then persistent[normalized] = nil end
    return nil, nil
  end

  -- No lfs, so there is no cheap signature. Comparing the content we just read
  -- is exact -- and reading is roughly two orders of magnitude cheaper than
  -- parsing, which is the work the cache exists to avoid.
  if entry and not signature and entry.source == source then
    run.models[normalized] = entry.model
    run.indexed_count = run.indexed_count + 1
    run.reused = (run.reused or 0) + 1
    return entry.model, nil
  end

  local chunk, err = parser.parse(source)
  if not chunk then
    if persistent then persistent[normalized] = nil end
    return nil, err
  end

  local model = analyze.run(normalized, chunk)
  model.role = role
  model.source = source
  run.models[normalized] = model
  run.indexed_count = run.indexed_count + 1

  if persistent then
    persistent[normalized] = {
      model = model,
      signature = fs.signature(normalized),
      source = source,
    }
  end

  return model, nil
end

--- Indexes a model's declarations, then follows its `require`s.
---@param run typer.Run
---@param model typer.FileModel
---@param role string
---@param report_site table|nil        -- checked file that pulled this in
local function index_and_follow(run, model, role, report_site)
  registry_mod.index_file(run.registry, model, {
    checked = role == "checked",
    is_stub = role == "stub" or model.is_meta,
  })

  if run.config.follow_requires == "skip" then return end

  for _, entry in ipairs(model.requires) do
    local resolution = modpath.resolve(run.search, entry.module)

    if resolution.kind == "lua" then
      local normalized = compat.absolute(resolution.path, run.cwd)
      if not run.models[normalized] then
        local required, parse_error = load_model(run, normalized, resolution.role or "library")
        if required then
          index_and_follow(run, required, resolution.role or "library", nil)
        elseif parse_error and role == "checked" then
          -- A broken dependency must not stop us checking our own code.
          emit(run, diagnostic.new(model.path, entry, "untyped-module",
            ("module '%s' could not be parsed (%s:%d:%d: %s)"):format(
              entry.module, normalized, parse_error.l, parse_error.c, parse_error.msg),
            nil))
        end
      end

    elseif role == "checked" and not config_mod.ignores_module(run.config, entry.module) then
      if resolution.kind == "c" then
        emit(run, diagnostic.new(model.path, entry, "untyped-module",
          ("module '%s' is a C module; typer cannot read annotations from it")
            :format(entry.module),
          "write a ---@meta stub and put it on stub_paths"))
      else
        emit(run, diagnostic.new(model.path, entry, "unresolved-module",
          ("module '%s' was not found on the search path"):format(entry.module),
          "fix the path, or add it to ignore_missing"))
      end
    end
  end
end

--- Expands command-line paths into a list of `.lua` files.
---@param paths string[]
---@param config typer.Config
---@param cwd string
---@return string[]
local function expand_targets(paths, config, cwd)
  ---@type string[]
  local out = {}
  ---@type table<string, boolean>
  local seen = {}

  for _, path in ipairs(paths) do
    local normalized = compat.absolute(path, cwd)
    if fs.is_dir(normalized) then
      for _, file in ipairs(fs.list_lua(normalized)) do
        local absolute = compat.absolute(file, cwd)
        if not seen[absolute] and not config_mod.is_excluded(config, absolute) then
          seen[absolute] = true
          out[#out + 1] = absolute
        end
      end
    elseif not seen[normalized] then
      seen[normalized] = true
      if not config_mod.is_excluded(config, normalized) then
        out[#out + 1] = normalized
      end
    end
  end

  table.sort(out)
  return out
end

--- Eagerly indexes the workspace: ambient `---@class` declarations may live in
--- files that nothing requires, so lazy loading alone would miss them.
---@param run typer.Run
local function index_workspace(run)
  ---@type table<string, boolean>
  local seen = {}

  for _, entry in ipairs(run.search.entries) do
    if entry.role == "workspace" or entry.role == "stub" then
      local dir = entry.pattern:match("^(.*)/%?")
      if dir and not seen[dir] and fs.is_dir(dir) then
        seen[dir] = true
        for _, file in ipairs(fs.list_lua(dir)) do
          local absolute = compat.absolute(file, run.cwd)
          if not run.models[absolute] and not config_mod.is_excluded(run.config, absolute) then
            local model = load_model(run, absolute, entry.role)
            if model then
              registry_mod.index_file(run.registry, model, {
                checked = false,
                is_stub = entry.role == "stub" or model.is_meta,
              })
            end
          end
        end
      end
    end
  end
end

--- Runs a check.
---@param paths string[]
---@param options table
---@return typer.Diagnostic[]
---@return table summary
function M.run(paths, options)
  options = options or {}

  local config = options.config or config_mod.defaults()
  local search = search_mod.build(config, {
    stub_paths = options.stub_paths,
    lua_path = options.lua_path,
    inherit_path = options.inherit_path,
  })

  ---@type typer.Run
  local run = {
    config = config,
    search = search,
    registry = registry_mod.new(),
    diagnostics = {},
    models = {},
    checked = {},
    indexed_count = 0,
    cache = cache_mod.open(config, options.use_cache ~= false),
    model_cache = options.model_cache,
    cwd = options.cwd or fs.cwd(),
  }

  local targets = expand_targets(paths, config, run.cwd)

  ---@type table<string, boolean>
  local is_checked = {}
  for _, path in ipairs(targets) do is_checked[path] = true end

  -- 1. Ambient declarations from the workspace and stubs.
  index_workspace(run)

  -- 2. Checked files, plus everything they require.
  ---@type typer.FileModel[]
  local checked_models = {}
  for _, path in ipairs(targets) do
    local model, parse_error = load_model(run, path, "checked")
    if parse_error then
      emit(run, diagnostic.new(path, { l = parse_error.l, c = parse_error.c },
        "parse-error", parse_error.msg, nil))
      run.had_parse_error = true
    elseif model then
      model.role = "checked"
      checked_models[#checked_models + 1] = model
    end
  end

  for _, model in ipairs(checked_models) do
    index_and_follow(run, model, "checked", nil)
  end

  -- 3. Duplicate declarations across the whole index.
  for _, pair in ipairs(run.registry.duplicates) do
    for _, side in ipairs({ pair.first, pair.second }) do
      if is_checked[side.file] then
        emit(run, diagnostic.new(side.file, side, "duplicate-class",
          ("'%s' is declared in both %s:%d and %s:%d"):format(
            side.name,
            compat.relative(pair.first.file, run.cwd), pair.first.l,
            compat.relative(pair.second.file, run.cwd), pair.second.l),
          "rename one of them"))
      end
    end
  end

  -- 4. Rules, on checked files only.
  for _, model in ipairs(checked_models) do
    if not model.is_meta then
      local before = #run.diagnostics
      local context = {
        config = config,
        registry = run.registry,
        emit = function(diag) emit(run, diag) end,
      }
      for _, rule in ipairs(RULES) do
        rule.run(model, context)
      end

      -- Suppression applies only to this file's own diagnostics.
      local suppressions = suppress.collect(model.chunk, model)
      if not options.no_suppress then
        local kept = {}
        for index = 1, before do kept[#kept + 1] = run.diagnostics[index] end
        for index = before + 1, #run.diagnostics do
          local diag = run.diagnostics[index]
          if not suppress.is_suppressed(suppressions, diag) then
            kept[#kept + 1] = diag
          end
        end
        run.diagnostics = kept
      end
    end
  end

  -- 5. Severity overrides, dropping anything switched off.
  ---@type typer.Diagnostic[]
  local final = {}
  local errors, warnings, hints = 0, 0, 0

  for _, diag in ipairs(run.diagnostics) do
    local severity = config_mod.severity_of(config, diag.code)
    if severity ~= "off" then
      diag.severity = severity
      -- Paths are absolute internally, for identity; they are reported relative
      -- to the working directory, because that is what an editor wants to open.
      diag.file = compat.relative(diag.file, run.cwd)
      final[#final + 1] = diag
      if severity == "error" then errors = errors + 1
      elseif severity == "warning" then warnings = warnings + 1
      else hints = hints + 1 end
    end
  end

  table.sort(final, diagnostic.compare)
  cache_mod.save(run.cache)

  return final, {
    files = #targets,
    indexed = run.indexed_count,
    errors = errors,
    warnings = warnings,
    hints = hints,
    had_parse_error = run.had_parse_error or false,
  }
end

return M
