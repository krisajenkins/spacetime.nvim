# spacetime.nvim

A Neovim plugin for [SpacetimeDB](https://spacetimedb.com).

> **Status: early.** The browsing interface is under construction. The full
> command set is defined, but most commands are placeholders that say so when
> you run them — see [Commands](#commands). What works today is connection
> resolution (`:SpacetimeStatus`) and the window layout (`:Spacetime`).

## Requirements

- Neovim >= 0.11.0
- The `spacetime` CLI >= 2.0.0 on your `PATH`
- `curl` on your `PATH` — used for all HTTP requests to SpacetimeDB

Run `:checkhealth spacetime` to verify all three. It also mirrors the fields
`:SpacetimeStatus` prints, from the same code, so the two cannot disagree.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "krisajenkins/spacetime.nvim",
  config = function()
    require("spacetime").setup()
  end,
}
```

## Configuration

`setup()` takes an optional table. Every field is optional.

```lua
require("spacetime").setup({
  log_level = vim.log.levels.INFO,
  identity = nil,
  side = "left",
  width = 30,
})
```

- `log_level` — minimum severity for the plugin's own `vim.notify()` messages.
- `identity` — overrides the identity derived from your token's claims; a
  last-resort escape hatch.
- `side` — which side of the tabpage the sidebar opens on: `"left"` (the
  default) or `"right"`.
- `width` — how wide the sidebar is: a number of columns (`30` by default), or a
  percentage of the screen as a string, e.g. `"20%"`. A percentage is resolved
  against the terminal's current width each time the layout is opened, and never
  produces a sidebar narrower than 10 columns.

## Commands

| Command                    | Does                                            |
| -------------------------- | ----------------------------------------------- |
| `:Spacetime`               | Open (or re-focus) the sidebar/content layout    |
| `:SpacetimeToggle`         | Toggle the layout — *placeholder*                |
| `:SpacetimeConnect [nick]` | Switch server by `cli.toml` nickname — *placeholder* |
| `:SpacetimeDatabases`      | List your databases — *placeholder*              |
| `:SpacetimeTables [db]`    | List a database's tables — *placeholder*         |
| `:SpacetimeRows {tbl}`     | Browse rows of `[db.]tbl` — *placeholder*        |
| `:SpacetimeSchema {tbl}`   | Show the schema of `[db.]tbl` — *placeholder*    |
| `:SpacetimeLogs[!] [db]`   | Show logs; `!` follows them — *placeholder*      |
| `:SpacetimeLogsStop`       | Stop following logs — *placeholder*              |
| `:SpacetimeStatus`         | Print the resolved connection                    |

A *placeholder* command exists, completes its argument and tells you it is not
implemented yet. It never errors — the feature simply has not landed.

### Completion

`<Tab>` completes server nicknames from `cli.toml`, and database and table names
**from what the plugin has already fetched this session**. Completion never
makes a network request, so a name the plugin has not seen yet will not appear;
run the command once and it will complete thereafter.

- `:SpacetimeConnect` — nicknames from your `cli.toml`.
- `:SpacetimeTables`, `:SpacetimeLogs` — cached database names.
- `:SpacetimeRows`, `:SpacetimeSchema` — cached `db.table`, in both the source
  and the SQL spelling where they differ (`spacegym.ledgerEntry` and
  `spacegym.ledger_entry`).

### `:Spacetime`

Opens the browser layout in the current tabpage: a full-height sidebar of the
configured `side` and `width`, and a content window beside it. Running it again
re-focuses the existing layout rather than splitting a second one, and a sidebar
you have resized by hand keeps your width.

The sidebar's database tree is not built yet, so both windows are currently
empty.

### `:SpacetimeStatus`

Prints the connection the plugin has resolved for the current buffer:

```
server:       maincloud (https://maincloud.spacetimedb.com:443)
identity:     c2005efe02e92547ddd4bd106e84a281ead78a30fa26f42e619d70b20917c3dd
token:        present
cli.toml:     /home/you/.config/spacetime/cli.toml
project:      /path/to/repo/spacetime.json (database: spacegym)
```

- `server` — the nickname you asked for (or the hostname, if you named one by
  hand) and the resolved base URL, whose scheme carries TLS and whose port is
  always explicit.
- `identity` — your hex identity, derived from the token's `iss`/`sub` claims
  or taken from the `identity` option. A derivation failure prints its reason
  here instead of aborting the command.
- `token` — always exactly `present` or `absent`. **The token is never
  printed**, not even a prefix of it; the command is meant to be safe to paste
  into a bug report.
- `cli.toml` — where the SpacetimeDB CLI's config is, with `(not found)`
  appended if there is no file there. Not having one is fine.
- `project` — the `spacetime.json` / `spacetime.local.json` at the enclosing
  repository root and the database they name, or `none`.

If the configuration cannot be resolved at all — an unknown server nickname,
say — the error appears on the `server` line and the rest is still printed. A
broken configuration is exactly what you would run this to diagnose.

## Development

The project uses Nix for its toolchain. `direnv` picks the shell up
automatically; otherwise:

```bash
nix develop
```

That provides `neovim`, `lua-language-server`, `luacheck`, `stylua`, `curl` and
the `spacetime` CLI.

```bash
make                                  # typecheck + test (the default target)
make test                             # tests only
make test_file FILE=tests/test_main.lua   # one test file
make typecheck                        # luacheck + lua-language-server
make format                           # stylua
make check-format                     # stylua --check (what CI runs)
make helptags                         # regenerate doc/tags after editing doc/
```

Tests use [mini.test](https://github.com/echasnovski/mini.test); `make` clones
it into `deps/` on first run.

### Nix pins

`overlays/` pins Neovim and SpacetimeDB ahead of what nixpkgs 26.05 ships.
SpacetimeDB installs upstream's release binaries, so it is a download rather
than a build. Neovim is an `overrideAttrs` on nixpkgs and does compile, so a
cold `nix develop` takes a while — CI caches the resulting store (see
`.github/workflows/ci.yml`).

## Licence

MIT. See [LICENSE](LICENSE).
