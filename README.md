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

> **Anything that gets a name must be annotated. Anything that lands in a slot
> with a declared type inherits it.**

```lua
local f = function() end          -- new name -> needs ---@param / ---@return
vim.keymap.set("n", "x", function() end)  -- inline -> typed by the callee
local t = {}                      -- new name -> needs ---@type or ---@class
f({ a = 1 })                      -- inline -> typed by the callee

vim.notify = function(msg, level) -- overwrites a slot that is already typed
    original(msg, level)          -- -> inherits it, nothing to add
end
```

### Declaring versus overwriting

Inheriting a type is not about where an expression *sits* — it is about whether
the slot it lands in **already has a declared type**. Declaring `M.helper` for
the first time needs annotations, because nothing else knows what it is.
Overwriting `vim.notify`, or monkeypatching an annotated module function in a
test, does not: the signature is already stated somewhere typer has read, and
typer does not verify assignments, so a second copy of it here is duplication
that cannot be checked and drift that cannot be caught.

Five ways a slot arrives already typed:

```lua
---@type fun(name: string): nil
local callback
callback = function(name) end                 -- the local's ---@type

---@param seam? fun(n: string): nil
function M.setup(seam)
    seam = seam or function(n) end            -- the parameter's ---@param
end

---@param x string
---@return string
function M.echo(x) return x end
M.echo = function(x) return x .. "!" end      -- an earlier definition

helpers.get_root = function(buffer) end       -- a required module's export
vim.fn.jobstart = function(cmd, opts) end     -- a global-rooted name
```

What does *not* stand down is the return arity — the declaration says how many
values come back, and a body returning more contradicts it:

```lua
---@return fun(): [integer, string]?   -- one value: a tuple
function M.iterate(values)
    return function()
        return index, values[index]    -- two. return-arity-mismatch, correctly
    end
end
```

Nor does a half-written doc block: an inherited signature stands in for
annotations that are *absent*, so the moment one `---@param` appears the ordinary
rules take over and the block has to be complete.

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
| `namespace-decl` | a table whose every member is a function — the `local M = {}` module preamble (**off** by default) |
| `global-decl` | assignment to an undeclared global, whatever its value |
| `undefined-global` | *reading* a global that resolves to nothing |
| `missing-param` / `missing-vararg` | a parameter, or `...`, with no `---@param` |
| `missing-return` | fewer `---@return` than the function's widest return arity |
| `param-name-mismatch` / `param-arity-mismatch` / `return-arity-mismatch` | annotations disagree with the signature |
| `duplicate-param` | two `---@param` lines name the same parameter |
| `self-param` | `---@param self` on a `:` method |
| `missing-class` | a class-shaped table with no `---@class` |
| `missing-field` | a data field assigned on a class with no `---@field` |
| `missing-inherit` | runtime inheritance not declared as `---@class T : Base` |
| `vague-table` / `vague-function` | bare `table` / `function` |
| `disallowed-any` / `disallowed-unknown` | `any` / `unknown` anywhere |
| `unresolved-type` | a type name declared nowhere in the index |
| `unresolved-module` / `untyped-module` | `require` that resolves to nothing, or to a C module |
| `duplicate-class` | the same class name declared in two files |

A **class-shaped** table is one that defines `:` methods, assigns a *table* to
`__index`, is used as a metatable, or has fields assigned on `self`.

`__index` counts only when a table is on the right. A table there is
inheritance — instances fall back to a base — but a **function** is a
computed-lookup metamethod that makes the table a proxy over values generated on
demand. A proxy has no fields to declare and is not a class:

```lua
---@type string[]
local generated = {}

setmetatable(generated, {
    __index = function(_, key) return tostring(key) end,
})
```

An existing `---@type` also satisfies `missing-class` outright: the rule exists
to force the literal-or-class question, and you have answered it. What you wrote
is still checked for vagueness, so `---@type table` does not get through.

Methods are exempt from `---@field`: a `function T:foo()` with its own
`---@param`/`---@return` already describes itself, and a duplicate `---@field`
would only drift.

### Discarded parameters

Parameters named `self`, `_`, or `_a` / `_b` / … are exempt from
`missing-param`, matching lua-language-server: both of the diagnostics that
would otherwise demand an annotation there — `incomplete-signature-doc` and
`missing-doc-param` — hard-skip exactly those names.

```lua
---@param callback fun(count: integer): nil
Editor.count_async = function(_, callback)   -- `_` is a discarded `self`
    callback(20)
end
```

Annotating one is still supported and still checked: `---@param _ string` types
the call site like any other parameter. `---@param _ any` is accepted too — on a
value the body throws away there is no real type to state, and no pass-through
generic to reach for. Only the bare form is excused; `---@param _ table<string,
any>` still has to say what it holds.

`---@param` binds by **name**, not by position, so two `---@param _` lines both
land on the *first* `_` and the second parameter silently stays undocumented.
typer reports that as `duplicate-param` (LuaLS: `duplicate-doc-param`); the fix
is distinct names, which is what `_a` / `_b` are for.

For the stricter reading — every parameter annotated, placeholders included —
turn on the opt-in code:

```lua
severity = { ["missing-param-placeholder"] = "error" }
```

### The module preamble

`local M = {}` with nothing but `function M.f() end` below it is a **namespace**,
and the literal-or-class question has no consumer for it: there is no data whose
shape a reader needs, and every member is a function that annotates itself. What
an annotation adds is a *nameable* type, which is worth something only if someone
writes the name — and mostly nobody does. In typer's own source, 19 of 26 module
class names appear in no type position anywhere.

So it reports as `namespace-decl`, separately from `table-decl`, and ships
**off**. Tables that really are opaque still report:

```lua
local M = {}                 -- namespace-decl (off): every member is a function
function M.run() end

local state = {}             -- table-decl (error): holds data of unknown shape
state.count = 0
```

Want your modules named anyway? One line — typer's own `.typer.lua` has it:

```lua
severity = { ["namespace-decl"] = "error" }
```

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

`.luarc.json` entries have `$VAR`, `${VAR}` and `~` expanded, resolve relative
to the `.luarc.json` itself, and are scanned **eagerly** — they are the user
declaring "these are my type sources", and nothing in a project necessarily
`require`s them.

### Host-injected globals

Some globals are created by the embedding program and assigned by no Lua file at
all — Neovim's `vim` is the canonical case. In a `---@meta` file, a field
assignment declares the global:

```lua
---@meta
vim.NIL = ...        -- declares `vim`
```

Meta files only: in ordinary code the same shape would let a typo declare
itself.

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

`overrides` and `fail_on` below are **not** baselines. They name paths and
severities, never individual defects, so nothing goes stale and nothing is
hidden: every diagnostic is still printed, every run, in full. They separate
*what is reported* from *what fails the build* — a baseline stops reporting.

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

  -- Hold library code to a higher standard than tests. Later blocks win, so a
  -- narrower one carves an exception out of a broader one above it.
  overrides = {
    { paths = { "spec/**" }, severity = { ["*"] = "hint" } },
    { paths = { "spec/critical_spec.lua" }, severity = { ["missing-param"] = "error" } },
  },

  fail_on = "error",               -- report everything; fail CI only on errors

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
  --fail-on <level>           exit 1 only at or above this severity
                              (error | warning | hint; default hint, i.e. anything)
  --no-suppress               ignore `-- typer: ignore` comments
  --stdin-filename <path>     read source from stdin, report as <path>

  --lua-version <5.1|jit|5.2|5.3|5.4>
  --lua-path <path>           prepend to the search path (repeatable)
  --stub-path <path>          prepend to the stub path (repeatable)
  --no-inherit-path           don't inherit the interpreter's package.path
  --follow-requires <mode>    index | check | skip
  --no-cache

typer daemon start|stop|status|check
```

Exit codes: `0` clean, `1` diagnostics at or above `--fail-on`, `2` tool error.
`--fail-on` never suppresses output — everything found is always printed.

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
