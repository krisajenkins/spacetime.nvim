# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## spacetime.nvim - Neovim Plugin for SpacetimeDB

spacetime.nvim is a SpacetimeDB browser inside Neovim: `:Spacetime` opens a
sidebar of the databases your identity owns beside a content window that browses
rows as a sortable, pageable grid, describes schemas, lists reducers, and tails
logs.

**It talks to SpacetimeDB's HTTP API directly, over `curl`.** The `spacetime`
CLI is not in the data path at all — it is how you log in (it writes the
`cli.toml` the plugin reads for the server list and token) and something
`:checkhealth` probes for. The plugin never shells out to it.

Runtime requirements: Neovim >= 0.11.0 and **`curl` on `PATH`**, which carries
every request. There are **no Lua dependencies** — no plenary, no parser, no
compiled component. Keep it that way.

`README.md` is the user-facing description and is accurate; prefer reading it to
re-deriving behaviour from the code.

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
- curl (the plugin's transport)
- spacetime (the SpacetimeDB CLI — for `spacetime login`, not for browsing)

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
lua/spacetime.lua              setup() and the options table
lua/spacetime/commands.lua     every :Spacetime* command: specs + one register loop
lua/spacetime/config.lua       which server, database and token a buffer means
lua/spacetime/health.lua       :checkhealth spacetime
lua/spacetime/logger.lua       level-filtered vim.notify wrapper; redacts the token
lua/spacetime/state.lua        in-flight requests, sequence guard, timers, cache
lua/spacetime/status.lua       :SpacetimeStatus — the resolved connection
lua/spacetime/lib/             pure logic; no vim.api (see the split rule below)
  blake3.lua                   single-chunk BLAKE3 on LuaJIT's bit library
  bsatn.lua                    hex-encoded BSATN -> the SATS shape value.lua renders
  client.lua                   one method per HTTP endpoint; cb(err, value) throughout
  clitoml.lua                  deliberately partial reader for the CLI's cli.toml
  http.lua                     the transport: request table -> curl -> response
  identity.lua                 account identity derived from the token's OIDC claims
  json.lua                     big-integer-preserving JSON decode
  logs.lua                     one NDJSON log line -> one entry; level ordering
  reducers.lua                 a module's reducers, normalised for display
  schema.lua                   schema v10 and v9 normalised into one model
  sort.lua                     display order over the rows, without refetching
  sql.lua                      the SQL response envelope and the SELECT builder
  value.lua                    a SATS value plus its AlgebraicType, rendered
lua/spacetime/ui/              buffers, windows, keymaps
  buffer.lua                   scratch buffers, the layout, and the one write
  content.lua                  which of the four views the content window holds
  detail.lua                   the schema fetch the two detail views share
  grid.lua                     row-grid layout: columns and cells -> lines + spans
  highlights.lua               default highlight groups (all `default` links)
  keys.lua                     buffer-local keymaps, and the unbinding
  logs.lua                     the log view, static and followed
  reducers.lua                 the reducers view
  rows.lua                     the row grid view
  schema.lua                   the schema detail view
  sections.lua                 title/badge/sections sink for the two detail views
  sidebar.lua                  the sidebar controller: model, fetch, paint, keys
  tree.lua                     the sidebar tree rendered as data
plugin/spacetime.lua           load-time wiring: highlight groups and commands
scripts/minimal_init.lua       headless init used by the test runner
scripts/record-demo.tape       the README demo as a VHS tape (`make demo`)
scripts/record-demo-setup.sh   its environment prep: demo cli.toml, init, terminfo
scripts/molokai.tape           the terminal palette, Source-d by the tape
tests/                         mini.test suites; helpers/ holds the shared harness
tests/fixtures/                real responses captured from a live server
doc/spacetime.txt              vimdoc; doc/tags is generated and tracked
overlays/                      Nix pins for neovim and spacetimedb
```

### The library/UI split (load-bearing)

Code under `lua/spacetime/lib/` **must not touch `vim.api`, `vim.fn`, `vim.ui`
or `vim.notify`.** It takes data and returns data; anything that needs an editor
belongs in `ui/`, and anything that needs the editor but is not a view
(`commands.lua`, `config.lua`, `state.lua`, `status.lua`) sits directly under
`lua/spacetime/`.

Two things depend on that rule. It is what lets almost the whole suite run
without a child Neovim, and it is the seam that keeps the sidecar escape hatch
open — see "Why Lua, and not a Rust or TypeScript sidecar" in `ROADMAP.md`. Do
not let a `vim.notify` creep into `lib/` for convenience; return an error and let
the caller report it.

`ui/grid.lua` and `ui/tree.lua` are data-in/data-out too, but `grid.lua` needs
`vim.fn.strdisplaywidth` to measure columns, so it lives under `ui/`. That is the
line: referential purity is not the test, `vim.*` is.

## Documentation

`README.md` and `doc/spacetime.txt` are both user-facing and must agree with
each other and with the code. After editing `doc/`, regenerate the tags file
(it is tracked in git):

```bash
make helptags
```

`demo.gif` at the top of `README.md` is recorded, not captured: `make demo`
replays `scripts/record-demo.tape` through VHS. It is **not** hermetic — it
browses the `medium-epic-events` database on a SpacetimeDB at
`127.0.0.1:3000`, and `scripts/record-demo-setup.sh` stops with a clear message
if either is missing rather than recording a screenful of error text. Everything
else it needs (a demo `cli.toml`, a cosmetic `init.lua`, isolated XDG dirs, and
the semicolon-truecolor terminfo VHS's terminal needs to render molokai
correctly) it builds in a temp dir, so no real config is read or written. The
tape's `j`-motion counts encode where `medium-epic-events` and `item_template`
sit in the sidebar — change the demo database and re-count them.

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

The suite is offline: no test makes a network request or reads a token.
`tests/fixtures/` holds real responses captured from a live server, read via
`tests/helpers/fixtures.lua`, and the transport seam every higher-level test
stubs is `spacetime.lib.http` — never `lib/client.lua`. `tests/CLAUDE.md` has the
details.

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

`ROADMAP.md` is the record of decisions: why each design choice was taken and
why the rejected alternatives were rejected, facts probed against a live server,
and the ordered task list v1 was built from. The build phases are done; what is
still live there is the reasoning — read the relevant section before changing a
constraint, because the argument for it is there rather than in the code — plus
"Deferred past v1", which is where the next work comes from.

<!-- agent-conventions: maintained by work-issues / work-todos -->
## Project conventions (cached)

- Verify: `make`; `make check-format`
- Format: `make format`
- Publish: none
- Auto-close: `Closes #N`
- Blocked label: `blocked`
<!-- /agent-conventions -->

`nix develop -c <cmd>` is the robust form: it works whether or not `direnv` has
already loaded the environment. Under an active `direnv`, bare `make` is
equivalent and preferred. Neither `luacheck`, `stylua` nor
`lua-language-server` is on the PATH without it, so a bare `make` outside the
shell fails as *missing tools*, not as a real failure.
