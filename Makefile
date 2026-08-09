.PHONY: check-stylua corpus deadcode lint llscheck luacheck privata rockspec self-check stylua test

CONFIGURATION = .luarc.json
ARGUMENTS ?=
LUA ?= lua
ROCKSPEC ?= typer-scm-1.rockspec

# `lua/` is the only shipping source. `stubs/` is LuaLS data that typer reads as
# text and `tests/fixtures/` is deliberately broken code, so neither is linted.
LINT_TARGETS ?= bin/typer lua tests/run.lua tests/corpus.lua

# privata resolves module names from the root it is given, so it gets the source
# root rather than the file list above.
SOURCE ?= lua

lint: stylua luacheck privata deadcode llscheck

check-stylua:
	stylua $(LINT_TARGETS) --color always --check

stylua:
	stylua $(LINT_TARGETS)

luacheck:
	luacheck $(ARGUMENTS) $(LINT_TARGETS)

privata:
	privata $(SOURCE) $(ARGUMENTS)

deadcode:
	deadcode $(LINT_TARGETS) $(ARGUMENTS)

llscheck:
	llscheck --configpath $(CONFIGURATION) $(ARGUMENTS) .

test:
	$(LUA) tests/run.lua $(ARGUMENTS)

# The parser has to survive every Lua file in the repository, stubs and
# intentionally odd fixtures included.
corpus:
	$(LUA) tests/corpus.lua lua stubs tests

rockspec:
	luarocks lint $(ROCKSPEC)

# typer must pass its own strictest check: exit 0 means zero diagnostics. This
# is the regression guard on every annotation in the codebase.
#
# NOTE: The leading `./` matters. bin/typer finds the bundled library by
# matching `/bin/` in arg[0], so a bare `bin/typer` cannot resolve itself.
self-check:
	$(LUA) ./bin/typer $(ARGUMENTS) $(SOURCE)
