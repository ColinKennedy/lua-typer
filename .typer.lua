--- typer's own configuration -- and a worked example of a real one.
return {
  -- Only `lua/` holds shipping source. `stubs/` is data read as text, and
  -- `tests/fixtures/` deliberately contains broken code and duplicate classes.
  source_roots = { "lua" },

  exclude = {
    "**/tests/fixtures/**",
    "**/.typer_cache/**",
  },

  -- typer must run on 5.1 through 5.4, so it is checked against the oldest.
  lua_version = "5.1",

  -- Nothing here should depend on the host's installed rocks.
  inherit_path = false,

  severity = {
    -- Ships `off`, because for most projects naming the module table buys
    -- nothing (see `analyze.is_namespace`). typer names every one of its own,
    -- so it holds itself to the rule it does not impose.
    ["namespace-decl"] = "error",
  },
}
