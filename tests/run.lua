--- Fixture-driven test runner.
---
--- Two fixture shapes (spec §11):
---   tests/fixtures/<phase>/<name>/input.lua + expected.txt   -- single file
---   tests/fixtures/<phase>/<name>/ with .typer.lua + expected.txt
---     and a `TARGETS` file naming the paths to check          -- multi-file
---
--- `expected.txt` holds vimgrep output with the fixture directory stripped from
--- the paths, so fixtures are relocatable.
---
--- Usage: lua tests/run.lua [name-filter]
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local compat = require("typer.compat")
local fs = require("typer.fs")
local check = require("typer.check")
local config_mod = require("typer.config")
local vimgrep = require("typer.report.vimgrep")

local FIXTURE_ROOT = "tests/fixtures"

local filter = ...

---@type string[]
local failures = {}
local passed, ran = 0, 0

---@param dir string
---@return string[]
local function subdirs(dir)
  ---@type string[]
  local out = {}
  local pipe = io.popen(("find %q -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort"):format(dir))
  if not pipe then return out end
  for line in pipe:lines() do out[#out + 1] = line end
  pipe:close()
  return out
end

---@param text string
---@return string[]
local function split_lines(text)
  ---@type string[]
  local out = {}
  for line in (text or ""):gmatch("([^\n]*)\n?") do
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

--- Runs one fixture directory and returns the actual vimgrep output.
---@param dir string
---@return string
local function run_fixture(dir)
  local config_path = compat.join(dir, ".typer.lua")
  local has_config = compat.file_exists(config_path)

  ---@type string[]
  local targets = {}
  local targets_file = compat.read_file(compat.join(dir, "TARGETS"))
  if targets_file then
    for line in targets_file:gmatch("[^\n]+") do
      local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
      if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
        targets[#targets + 1] = compat.join(dir, trimmed)
      end
    end
  else
    targets = { compat.join(dir, "input.lua") }
  end

  local config
  if has_config then
    config = config_mod.load(config_path, dir)
  else
    config = config_mod.defaults()
    config.root = dir
    config.source_roots = { "." }
    -- Keep single-file fixtures hermetic: no ambient project, no host package.path.
    config.inherit_path = false
    config.exclude_patterns = {}
    config.ignore_missing_patterns = {}
  end

  local diagnostics, summary = check.run(targets, {
    config = config,
    inherit_path = config.inherit_path,
    use_cache = false,
  })

  local rendered = vimgrep.render(diagnostics, summary)
  -- Strip the fixture path so expectations are relocatable.
  return (rendered:gsub(dir:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1") .. "/", ""))
end

---@param name string
---@param dir string
local function run_case(name, dir)
  ran = ran + 1

  local expected_path = compat.join(dir, "expected.txt")
  local expected = compat.read_file(expected_path) or ""

  local ok, actual = pcall(run_fixture, dir)
  if not ok then
    failures[#failures + 1] = ("%s: ERROR %s"):format(name, tostring(actual))
    return
  end

  if actual == expected then
    passed = passed + 1
    return
  end

  -- Report a line-level diff; whole-blob dumps are unreadable.
  local expected_lines, actual_lines = split_lines(expected), split_lines(actual)
  ---@type string[]
  local report = { name .. ":" }
  local count = math.max(#expected_lines, #actual_lines)
  for index = 1, count do
    local want, got = expected_lines[index], actual_lines[index]
    if want ~= got then
      if want then report[#report + 1] = "    - " .. want end
      if got then report[#report + 1] = "    + " .. got end
    end
  end
  failures[#failures + 1] = table.concat(report, "\n")
end

for _, phase_dir in ipairs(subdirs(FIXTURE_ROOT)) do
  for _, case_dir in ipairs(subdirs(phase_dir)) do
    local name = case_dir:gsub("^" .. FIXTURE_ROOT .. "/", "")
    if not filter or name:find(filter, 1, true) then
      run_case(name, case_dir)
    end
  end
end

print(("typer tests: %d/%d passed"):format(passed, ran))
if #failures > 0 then
  print("")
  for _, failure in ipairs(failures) do print(failure) end
  os.exit(1)
end

if ran == 0 then
  print("no fixtures matched")
  os.exit(1)
end

os.exit(0)
