--- Corpus validator and benchmark harness (spec §10.4).
---
--- Parses every `.lua` file under the given roots, reporting failures and
--- throughput. Any file the reference interpreter accepts, typer must accept --
--- a parse failure here is a bug in typer, not in the corpus.
---
--- Usage: lua tests/corpus.lua <root>...
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local compat = require("typer.compat")
local lexer = require("typer.lexer")
local parser = require("typer.parser")

---@param root string
---@param out string[]
local function collect(root, out)
    local pipe = io.popen(("find %q -name '*.lua' -type f 2>/dev/null"):format(root))
    if not pipe then
        return out
    end
    for line in pipe:lines() do
        out[#out + 1] = line
    end
    pipe:close()
    return out
end

local roots = { ... }
if #roots == 0 then
    io.stderr:write("usage: lua tests/corpus.lua <root>...\n")
    os.exit(2)
end

---@type string[]
local files = {}
for _, root in ipairs(roots) do
    collect(root, files)
end
table.sort(files)

local total_bytes, failures, skipped = 0, 0, 0
---@type string[]
local failure_lines = {}

-- Read everything up front so I/O is not counted in the parse timing.
---@type {path: string, src: string}[]
local sources = {}
for _, path in ipairs(files) do
    local src = compat.read_file(path)
    if src then
        -- Reference check: if the host interpreter cannot load it either, the file
        -- targets a syntax we do not have to accept (e.g. 5.4-only on a 5.1 host).
        sources[#sources + 1] = { path = path, src = src }
        total_bytes = total_bytes + #src
    end
end

local clock = os.clock

local lex_start = clock()
for _, entry in ipairs(sources) do
    lexer.lex(entry.src)
end
local lex_elapsed = clock() - lex_start

local parse_start = clock()
for _, entry in ipairs(sources) do
    local chunk, err = parser.parse(entry.src)
    if not chunk then
        -- Only a real failure if the host interpreter accepts the file.
        local loaded = compat.load_string(entry.src, "@" .. entry.path)
        if loaded then
            failures = failures + 1
            if #failure_lines < 25 then
                failure_lines[#failure_lines + 1] = ("%s:%d:%d: %s"):format(entry.path, err.l, err.c, err.msg)
            end
        else
            skipped = skipped + 1
        end
    end
end
local parse_elapsed = clock() - parse_start

local megabytes = total_bytes / 1048576

print(("files          : %d (%d unparseable by host %s, ignored)"):format(#sources, skipped, compat.lua_version))
print(("source         : %.2f MB"):format(megabytes))
print(("lex            : %.3f s  (%.2f MB/s)"):format(lex_elapsed, megabytes / math.max(lex_elapsed, 1e-9)))
print(("lex+parse      : %.3f s  (%.2f MB/s)"):format(parse_elapsed, megabytes / math.max(parse_elapsed, 1e-9)))
print(("failures       : %d"):format(failures))

for _, line in ipairs(failure_lines) do
    print("  " .. line)
end

os.exit(failures == 0 and 0 or 1)
