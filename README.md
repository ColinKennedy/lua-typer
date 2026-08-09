# typer

**`mypy --strict`, for Lua.**

A static analysis tool, written in Lua, that reports where [LuaLS][luals] type
annotations are missing or too vague. Report-only — it never edits your files.

typer is not a single-file linter. It builds a project-wide type index, resolves
`require` against `LUA_PATH` and friends, reads third-party and standard-library
definitions, and supports `---@meta` stub files for code it cannot read. A
missing definition is an error to fix, not something typer papers over.

```console
$ typer lua/
lua/app/client.lua:12:7: error: [table-decl] table 'opts' has no ---@type or ---@class; inference cannot tell a literal shape from a class
lua/app/client.lua:18:1: error: [missing-return] function returns 2 values but declares 0 ---@return; 2 missing
lua/app/client.lua:18:22: error: [missing-param] parameter 'url' has no ---@param annotation
lua/app/client.lua:31:11: error: [vague-table] 'table' is not specific enough
lua/app/stack.lua:3:7: error: [missing-class] table 'Stack' defines ':' methods but has no ---@class annotation
```

## Install

```console
luarocks install typer
```

Two optional dependencies, both detected at runtime:

| Rock | Without it | With it |
|---|---|---|
| `luafilesystem` | shells out to `find`; the on-disk cache is **disabled** | fast directory walks, cache enabled |
| `luasocket` | `typer daemon` unavailable | daemon mode works |

typer itself runs on Lua 5.1–5.4 and LuaJIT.

## The governing principle

> **Anything that gets a name must be annotated. Anything inline inherits its
> type from context.**

```lua
local f = function() end          -- named  -> needs ---@param / ---@return
vim.keymap.set("n", "x", function() end)  -- inline -> typed by the callee
local t = {}                      -- named  -> needs ---@type or ---@class
f({ a = 1 })                      -- inline -> typed by the callee
```

### Why inference is not enough

LuaLS infers `local t = { name = "x" }` as `{ name: string }`. typer still wants
an annotation, because inference cannot answer the question that matters: **is
this an ad-hoc literal or a class?** A table constructor looks identical either
way. Only you know, and the annotation is how you say it:

```lua
---@type table<string, integer>     -- a literal shape
---@class Foo                       -- a class
```

Scalars are exempt — `local x = 5` has no such ambiguity.

## Diagnostics

| Code | Fires when |
|---|---|
| `bare-decl` / `nil-decl` | `local foo` / `local foo = nil` with no `---@type` |
| `table-decl` | a table constructor bound to a name, unannotated |
| `global-decl` | assignment to an undeclared global, whatever its value |
| `undefined-global` | *reading* a global that resolves to nothing |
| `missing-param` / `missing-vararg` | a parameter, or `...`, with no `---@param` |
| `missing-return` | fewer `---@return` than the function's widest return arity |
| `param-name-mismatch` / `param-arity-mismatch` / `return-arity-mismatch` | annotations disagree with the signature |
| `self-param` | `---@param self` on a `:` method |
| `missing-class` | a class-shaped table with no `---@class` |
| `missing-field` | a data field assigned on a class with no `---@field` |
| `missing-inherit` | runtime inheritance not declared as `---@class T : Base` |
| `vague-table` / `vague-function` | bare `table` / `function` |
| `disallowed-any` / `disallowed-unknown` | `any` / `unknown` anywhere |
| `unresolved-type` | a type name declared nowhere in the index |
| `unresolved-module` / `untyped-module` | `require` that resolves to nothing, or to a C module |
| `duplicate-class` | the same class name declared in two files |

A **class-shaped** table is one that defines `:` methods, assigns `__index`, is
used as a metatable, or has fields assigned on `self`.

Methods are exempt from `---@field`: a `function T:foo()` with its own
`---@param`/`---@return` already describes itself, and a duplicate `---@field`
would only drift.

## Cross-file types

The type namespace is flat and ambient, exactly like LuaLS: a `---@class`
declared anywhere in the index is usable everywhere, with no `require` needed.
Declaring a class in one file and using it in another is fully supported, and a
file may consist of nothing but annotations:

```lua
-- types/http.lua
---@meta

---@class http.Response
---@field status integer
---@field headers table<string, string>
---@field body string
```

`---@meta` marks a file as definitions-only: indexed, never reported on.

### Termination

`---@field children Node[]` is complete the moment `Node` resolves to a
`---@class`. typer does not walk into `Node`'s fields from there — an incomplete
class is reported once, at its own definition. That is what makes recursive
types (`Node.children: Node[]`) work.

## File roles

Only files you pass on the command line are reported on. Everything else is read
for its declarations and stays silent — mypy's `follow_imports = silent`.

| Role | From | Indexed | Reported |
|---|---|---|---|
| checked | the command line | yes | **yes** |
| workspace | `source_roots` | yes | no |
| library | reached via `require` | yes | no |
| stub | `stub_paths`, bundled stdlib, any `---@meta` | yes | no |

## Search path

First hit wins:

1. `--stub-path` / `stub_paths`
2. bundled stdlib stubs for the target version
3. `source_roots`
4. `lua_path`
5. `$LUA_PATH`, `$LUA_PATH_5_4` … (`;;` expands to the interpreter default)
6. `package.path` of the running interpreter, unless `--no-inherit-path`
7. `workspace.library` from `.luarc.json` — how Neovim projects get `vim.*`

Stubs deliberately outrank real source: a hand-written `---@meta` file is the
escape hatch for a dependency you cannot annotate. `LUA_CPATH` is searched only
to *detect* C modules — typer cannot read annotations out of a `.so`.

## No baseline mode. Ever.

Deliberately rejected, not overlooked. A baseline file lets a project declare its
existing defects acceptable and stop looking at them, which defeats the point.
The only suppression is per-site and visible in the source:

```lua
-- typer: ignore
-- typer: ignore missing-param, vague-table
-- typer: ignore-file
```

Plain comments, not doc comments — a `---@typer-ignore` tag would show up as an
unknown tag to lua-language-server itself.

## Configuration

`.typer.lua` (or `.typer.json`), searched upward from the working directory:

```lua
return {
  source_roots = { "lua", "plugin" },
  stub_paths   = { "types" },
  lua_path     = { "deps/?.lua", "deps/?/init.lua" },
  lua_version  = "jit",

  follow_requires = "index",       -- index (default) | check | skip
  ignore_missing  = { "ffi", "socket.*" },

  exclude  = { "**/spec/**", "**/*_spec.lua" },
  severity = { ["optional-param"] = "hint" },

  require_scalar_types  = false,
  strict_globals        = true,
  require_method_fields = false,
  undefined_globals     = true,
}
```

## CLI

```
typer [options] <path>...

  --json                      JSON output instead of vimgrep
  --config <file>             default: .typer.lua / .typer.json, searched upward
  --severity <code>=<level>   error | warning | hint | off
  --no-suppress               ignore `-- typer: ignore` comments
  --stdin-filename <path>     read source from stdin, report as <path>

  --lua-version <5.1|jit|5.2|5.3|5.4>
  --lua-path <path>           prepend to the search path (repeatable)
  --stub-path <path>          prepend to the stub path (repeatable)
  --no-inherit-path           don't inherit the interpreter's package.path
  --follow-requires <mode>    index | check | skip
  --no-cache

typer daemon start|stop|status|check [--socket <path>]
```

Exit codes: `0` clean, `1` diagnostics reported, `2` tool error.

Output matches vim's default errorformat (`%f:%l:%c:%m`), so `:cexpr`,
nvim-lint and null-ls consume it with no custom parser.

## Performance

Measured on Neovim's `runtime/lua` — 201 files, 5.1 MB:

| Path | When | Measured |
|---|---|---|
| cold, no cache | CI on a fresh clone | 2.9 s (LuaJIT), 3.7 s (PUC 5.1) |
| daemon, warm | editor, on save | **84–155 ms** |

Parser throughput is ~15 MB/s lex and ~4 MB/s lex+parse on LuaJIT, validated
against a 44 MB / 5,574-file corpus with zero failures.

The cold path is CI's, and CI does not care. The editor path is the daemon's.
Installing `luafilesystem` improves the warm path further by replacing a
whole-tree re-read with one `stat` per file.

```console
typer daemon start &
typer daemon check lua/app/client.lua
```

## Development

```console
lua tests/run.lua                 # fixture suite
lua tests/run.lua classes         # filter by name
lua tests/corpus.lua <dir>...     # parser validation + throughput
typer lua/                        # typer checks itself -- must exit 0
```

typer passes its own strictest check with zero diagnostics, and CI enforces it
on every supported interpreter. That is the point of having no baseline mode:
the only way to a clean run is to write the annotations.

Fixtures live in `tests/fixtures/<phase>/<name>/` as `input.lua` +
`expected.txt`, or a directory with `.typer.lua` + `TARGETS` for multi-file
resolution cases.

## License

MIT.

[luals]: https://luals.github.io/wiki/annotations/
