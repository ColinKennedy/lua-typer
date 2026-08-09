--- Command-line interface (spec §9).
---@class typer.cli
local M = {}

local compat = require("typer.compat")
local fs = require("typer.fs")
local check = require("typer.check")
local config_mod = require("typer.config")
local vimgrep = require("typer.report.vimgrep")
local json_report = require("typer.report.json")

---@type string
M.VERSION = "0.1.0"

local USAGE = [[
typer -- mypy --strict, for Lua

usage: typer [options] <path>...

  --json                      JSON output instead of vimgrep
  --config <file>             default: .typer.lua / .typer.json, searched upward
  --severity <code>=<level>   override a code's severity (error|warning|hint|off)
  --no-suppress               ignore `-- typer: ignore` comments
  --stdin-filename <path>     read source from stdin, report as <path>

  --lua-version <5.1|jit|5.2|5.3|5.4>   selects stdlib stubs and env var names
  --lua-path <path>           prepend to the search path (repeatable)
  --stub-path <path>          prepend to the stub path (repeatable)
  --no-inherit-path           don't inherit the interpreter's package.path
  --follow-requires <mode>    index (default) | check | skip
  --no-cache

  --version, --help

typer daemon start|stop|status [--socket <path>]
typer daemon check <path>...
]]

---@class typer.CliArgs
---@field paths string[]
---@field json boolean
---@field config string|nil
---@field severity table<string, string>
---@field no_suppress boolean
---@field stdin_filename string|nil
---@field lua_version string|nil
---@field lua_path string[]
---@field stub_path string[]
---@field inherit_path boolean
---@field follow_requires string|nil
---@field use_cache boolean
---@field daemon string|nil
---@field socket string|nil

--- Parses argv.
---@param argv string[]
---@return typer.CliArgs|nil
---@return string|nil error
function M.parse_args(argv)
  ---@type typer.CliArgs
  local args = {
    paths = {}, json = false, severity = {}, no_suppress = false,
    lua_path = {}, stub_path = {}, inherit_path = true, use_cache = true,
  }

  local index = 1
  while index <= #argv do
    local item = argv[index]

    if item == "--json" then
      args.json = true
    elseif item == "--no-suppress" then
      args.no_suppress = true
    elseif item == "--no-inherit-path" then
      args.inherit_path = false
    elseif item == "--no-cache" then
      args.use_cache = false
    elseif item == "--help" or item == "-h" then
      args.help = true
    elseif item == "--version" then
      args.version = true
    elseif item == "--config" then
      index = index + 1
      args.config = argv[index]
      if not args.config then return nil, "--config requires a path" end
    elseif item == "--stdin-filename" then
      index = index + 1
      args.stdin_filename = argv[index]
      if not args.stdin_filename then return nil, "--stdin-filename requires a path" end
    elseif item == "--lua-version" then
      index = index + 1
      args.lua_version = argv[index]
      if not args.lua_version then return nil, "--lua-version requires a value" end
    elseif item == "--follow-requires" then
      index = index + 1
      args.follow_requires = argv[index]
      local mode = args.follow_requires
      if mode ~= "index" and mode ~= "check" and mode ~= "skip" then
        return nil, "--follow-requires must be index, check or skip"
      end
    elseif item == "--lua-path" then
      index = index + 1
      if not argv[index] then return nil, "--lua-path requires a value" end
      args.lua_path[#args.lua_path + 1] = argv[index]
    elseif item == "--stub-path" then
      index = index + 1
      if not argv[index] then return nil, "--stub-path requires a value" end
      args.stub_path[#args.stub_path + 1] = argv[index]
    elseif item == "--socket" then
      index = index + 1
      args.socket = argv[index]
    elseif item == "--severity" then
      index = index + 1
      local pair = argv[index]
      if not pair then return nil, "--severity requires <code>=<level>" end
      local code, level = pair:match("^([%w%-]+)=(%a+)$")
      if not code then return nil, "--severity expects <code>=<level>" end
      args.severity[code] = level
    elseif item == "daemon" and #args.paths == 0 and not args.daemon then
      index = index + 1
      args.daemon = argv[index] or "status"
    elseif item:sub(1, 1) == "-" and #item > 1 then
      return nil, "unknown option: " .. item
    else
      args.paths[#args.paths + 1] = item
    end

    index = index + 1
  end

  return args, nil
end

--- Reads stdin into a temporary path so the normal pipeline can process it.
---@param filename string
---@return string|nil
local function stage_stdin(filename)
  local content = io.read("*a") or ""
  local dir = compat.dirname(filename)
  if dir ~= "" and dir ~= "." then fs.mkdir_p(dir) end
  if not compat.write_file(filename, content) then return nil end
  return filename
end

--- Entry point. Returns the process exit code.
---@param argv string[]
---@return integer
function M.main(argv)
  local args, parse_error = M.parse_args(argv)
  if not args then
    io.stderr:write("typer: " .. parse_error .. "\n")
    io.stderr:write(USAGE)
    return 2
  end

  if args.help then
    io.write(USAGE)
    return 0
  end

  if args.version then
    io.write("typer " .. M.VERSION .. "\n")
    return 0
  end

  if args.daemon then
    local ok, daemon = pcall(require, "typer.daemon")
    if not ok then
      io.stderr:write("typer: daemon mode needs luasocket (optional dependency)\n")
      return 2
    end
    return daemon.main(args)
  end

  if #args.paths == 0 and not args.stdin_filename then
    io.stderr:write(USAGE)
    return 2
  end

  local cwd = fs.cwd()
  local config, config_error = config_mod.load(args.config, cwd)
  if config_error then
    io.stderr:write("typer: " .. config_error .. "\n")
    return 2
  end

  for code, level in pairs(args.severity) do
    config.severity[code] = level
  end
  if args.lua_version then config.lua_version = args.lua_version end
  if args.follow_requires then config.follow_requires = args.follow_requires end
  if not args.inherit_path then config.inherit_path = false end

  ---@type string[]
  local paths = args.paths
  if args.stdin_filename then
    local staged = stage_stdin(args.stdin_filename)
    if not staged then
      io.stderr:write("typer: cannot write " .. args.stdin_filename .. "\n")
      return 2
    end
    paths = { staged }
  end

  local diagnostics, summary = check.run(paths, {
    config = config,
    stub_paths = args.stub_path,
    lua_path = args.lua_path,
    inherit_path = args.inherit_path,
    no_suppress = args.no_suppress,
    use_cache = args.use_cache,
  })

  local reporter = args.json and json_report or vimgrep
  io.write(reporter.render(diagnostics, summary))

  if summary.had_parse_error then return 2 end
  return #diagnostics > 0 and 1 or 0
end

return M
