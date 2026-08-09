--- Public interfaces, for privata. Mirrors tach.lua, which deadcode reads --
--- the two tools agree on the idea and differ only in file name and in how a
--- module is spelled (privata resolves names from `lua/`, deadcode from the
--- repository root).
---
--- Everything declared here is reachable only from outside `lua/`, so no amount
--- of explicit wiring inside it can produce a caller:
---
---   * `typer` is the library API -- `require("typer").parser` and friends exist
---     for consumers of the rock, not for typer itself.
---   * `typer.cli.main` is what `bin/typer` calls. That shim has no `.lua`
---     extension, so neither checker reads it.
---   * `typer.daemon.main` is reached through a `require` that only runs once
---     luasocket is known to be present -- daemon mode is optional, and loading
---     the module eagerly would break every install without that rock.
---
--- Anything not listed here is expected to have a caller in the source. If a
--- symbol shows up as unused, the answer is to delete it or to wire it up, not
--- to add it below.
return {
    interfaces = {
        { expose = { ".*" }, from = { "typer" } },
        { expose = { "main" }, from = { "typer\\.cli", "typer\\.daemon" } },
    },
}
