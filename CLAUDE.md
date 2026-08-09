# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## spacetime.nvim - Neovim Plugin for SpacetimeDB

spacetime.nvim integrates the SpacetimeDB CLI with Neovim. The repository is
currently **scaffolding** — build, test, lint, docs and CI are wired up; the
plugin's own functionality is not written yet.

## Development Setup

The project uses Nix for the development environment. `direnv` activates it
automatically; otherwise enter it explicitly:

```bash
nix develop
```

This provides:

- neovim (testing)
- lua-language-server (type checking)
- luacheck (static analysis)
- stylua (code formatting)
- spacetime (the SpacetimeDB CLI)

Both `neovim` and `spacetimedb` are pinned ahead of nixpkgs by `overlays/`.
`spacetimedb` installs upstream's release binaries (a download, not a build);
`neovim` overrides the nixpkgs derivation and does compile, so a cold shell
entry is slow. CI caches the store.

## Common Development Commands

```bash
# Run all checks and tests (the default target)
make

# Run tests only
make test

# Run a specific test file
make test_file FILE=tests/test_main.lua

# Static analysis: luacheck + lua-language-server
make typecheck

# Format code / check formatting (CI runs the check)
make format
make check-format
```

Always run `make` before declaring work done.

## Layout

```
lua/spacetime.lua          Top-level module: setup() and config
lua/spacetime/health.lua   :checkhealth spacetime
lua/spacetime/logger.lua   Level-filtered vim.notify wrapper
plugin/spacetime.lua       Load-time wiring (guard; commands go here)
scripts/minimal_init.lua   Headless init used by the test runner
tests/                     mini.test suites; helpers/ holds shared scaffolding
doc/spacetime.txt          Vimdoc; doc/tags is generated and tracked
overlays/                  Nix pins for neovim and spacetimedb
```

## Documentation

`README.md` and `doc/spacetime.txt` are both user-facing and must agree with
each other and with the code. After editing `doc/`, regenerate the tags file
(it is tracked in git):

```bash
make helptags
```

## Testing with MiniTest

Tests use [mini.test](https://github.com/echasnovski/mini.test), cloned into
`deps/` by the Makefile. See `tests/CLAUDE.md` for the patterns and gotchas.

```lua
local T = MiniTest.new_set()
local expect = MiniTest.expect

T["describes what it checks"] = function()
  expect.equality(actual, expected)
end

return T
```

For anything needing a real Neovim, use the shared child helper rather than
hand-rolling the boilerplate:

```lua
local child, new_set = require("tests.helpers.child")()
local T = new_set()
```

## Code Style

- Formatting is owned by stylua — do not hand-format, run `make format`.
- Max line length: 120 characters.
- LuaJIT standard library (no Lua 5.2 compat; use the global `unpack`).
- Annotate public functions with LuaCATS; `make typecheck` enforces them.
- All new code must pass luacheck and lua-language-server.

## Version Control

This is a Jujutsu (jj) repository with git colocation. Use `jj` commands; never
`git commit`/`checkout`/`rebase`/`stash`.

## CI

`.github/workflows/ci.yml` runs `make` and `make check-format` inside
`nix develop` on push to main and on PRs. `.github/workflows/release.yml` cuts a
GitHub release from a pushed `v*` tag.

The repo is private for now, so CI results are not the gate — run the verify
pipeline locally before calling anything done.

## Roadmap

`ROADMAP.md` is the plan of record: the decisions taken (and why the rejected
alternatives were rejected), facts probed against a live server, and an ordered
task list. Each task is tracked as a GitHub issue whose body is self-contained.
Read the roadmap section a task names before implementing it — the reasoning
behind a constraint is usually there rather than in the issue.

<!-- agent-conventions: maintained by work-issues / work-todos -->
## Project conventions (cached)

- Verify: `nix develop -c make`; `nix develop -c make check-format`
- Format: `nix develop -c make format`
- Publish: none
- Auto-close: `Closes #N`
- Blocked label: `blocked`
<!-- /agent-conventions -->

`nix develop -c` is the robust form: it works whether or not `direnv` has
already loaded the environment. Under an active `direnv`, bare `make` is
equivalent. Neither `luacheck`, `stylua` nor `lua-language-server` is on the
PATH without it, so a bare `make` outside the shell fails as *missing tools*,
not as a real failure.
