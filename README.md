# spacetime.nvim

A Neovim plugin for [SpacetimeDB](https://spacetimedb.com).

> **Status: early.** The browsing interface is under construction. The full
> command set is defined, but several commands are placeholders that say so when
> you run them — see [Commands](#commands). What works today is connection
> resolution (`:SpacetimeStatus`) and the browser itself (`:Spacetime`,
> `:SpacetimeRows` and `:SpacetimeSchema`): the layout, a sidebar listing your
> databases and the tables and views inside them, `<CR>` on a table to see its
> rows — sorted, paged, yanked or floated in full — and the schema of a table
> alongside the module's reducers. The log view is the next piece.

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
| `:Spacetime`               | Open the browser: layout plus your database list |
| `:SpacetimeToggle`         | Open the browser, or close it if it is open      |
| `:SpacetimeConnect [nick]` | Switch server by `cli.toml` nickname — *placeholder* |
| `:SpacetimeDatabases`      | Open the browser and refetch the database list   |
| `:SpacetimeTables [db]`    | List a database's tables — *placeholder*         |
| `:SpacetimeRows {tbl}`     | Open the browser on the rows of `[db.]tbl`       |
| `:SpacetimeSchema {tbl}`   | Show the schema of `[db.]tbl`, and the reducers  |
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

The single front door. It opens the browser layout in the current tabpage — a
full-height sidebar of the configured `side` and `width`, and a content window
beside it — then fetches the databases belonging to your identity and renders
them in the sidebar. Focus is left on the sidebar; the content window shows a
placeholder until you select something.

Running it again re-focuses the existing layout rather than splitting a second
one, and a sidebar you have resized by hand keeps your width. The database list
is cached for the session, so a second `:Spacetime` renders it without another
request; `r` in the sidebar refetches.

If the enclosing repository's `spacetime.json` (or `spacetime.local.json`) names
a `database`, that database is expanded for you — run `:Spacetime` inside a
module repo and it lands where you meant.

`<CR>` on a database fetches its schema and lists its tables, then its views,
then SpacetimeDB's own `st_*` tables. That schema is cached per database for the
session, so expanding it again is instant and puts nothing on the wire; `r`
drops it and fetches again. A database that is paused answers nothing, so it is
marked `⏸` and asked exactly once — press `r` on it once it has woken up.

`<CR>` on a table or a view runs `SELECT * FROM "table" LIMIT 100` and renders
the answer in the content window as a grid: a badge line, a header row, then one
line per row, columns aligned by display width so `£` and `🎟` still line up.
Primary-key headers, `NULL`s, identities, timestamps and truncated cells are
highlighted. The badge says how many rows are on screen, how far into the table
they start, and how long the server said the query took (`100 rows · offset 100
· 1.4ms`). The rows are cached per table for the session, and `r` in the sidebar
drops that database's rows along with its schema.

`s` in the grid sorts by the column the cursor is in, and pressing it again
reverses that column. The sort is on the values the server sent, not on the text
they are rendered as — `9` sorts before `10`, and a timestamp column sorts by
the instant rather than by the string — and `NULL`s go last whichever way round
the column is. Nothing is refetched and no row is rewritten; only the order the
rows are painted in changes, and the cursor stays on the row it was on.

`]p` and `[p` turn the page, 100 rows at a time, by moving the SQL `OFFSET` and
asking again. `[p` on the first page does nothing rather than asking for a
negative offset, and `]p` stops at a page the server returned short, because
there is nothing after it. Holding `]p` down is safe: every page of a table is
requested under the same key, so the pages you skipped past are cancelled and
only the one you land on is painted. A page arrives in the order the server sent
it, so a sort applies to the page you are looking at.

Cells wider than 40 columns are cut with a `…`, but that is only the grid: `K`
opens a float showing every column of the row under the cursor in full, `y`
yanks the whole value of the cell under the cursor — never the truncated text —
and `Y` yanks the whole row as JSON, built from the values the server sent
rather than from their rendering. Both yanks go to the unnamed register `"`,
honouring a register prefix (`"+y`) and your `clipboard` setting exactly as any
other yank would.

Switching tables quickly is safe: opening a second table cancels the first
table's request, and a response that arrives after you have moved on is dropped
rather than painted over the table you are now looking at.

Anything that goes wrong is written into the buffer as text: an unreachable
server, a rejected token, a configuration that will not resolve, a SQL error
from the server (which arrives as plain text and is shown verbatim). You will
not get a stack trace, and the plugin never raises out of a command.

#### Sidebar keymaps

These are buffer-local to the sidebar.

| Key            | Does                                       |
| -------------- | ------------------------------------------ |
| `<CR>` or `o`  | Expand or open the node under the cursor   |
| `r`            | Refresh: drop the cache and fetch again    |
| `q`            | Close the layout and cancel any request in flight |
| `y`            | Yank the node's name                       |
| `gi`           | Yank the database's identity               |
| `?`            | Print this key map                         |

`y` and `gi` honour a register prefix, so `"+gi` puts the identity on the system
clipboard.

#### Content-window keymaps

These are buffer-local to the content window *while it is showing a grid*. The
content window is shared — the schema view paints into the same buffer — so
these keys go away when another view takes it over, and come back with the next
table you open.

| Key   | Does                                                    |
| ----- | ------------------------------------------------------- |
| `s`   | Sort by the column under the cursor; again to reverse it |
| `]p`  | Next page (100 rows, over the SQL `OFFSET`)              |
| `[p`  | Previous page; nothing on the first one                  |
| `y`   | Yank the cell under the cursor, untruncated              |
| `Y`   | Yank the whole row as JSON                               |
| `K`   | Float the whole row, every column untruncated            |

### `:SpacetimeRows`

`:SpacetimeRows spacegym.member` opens the browser and puts that table's rows in
the content window, without going through the sidebar to find it. The database
may be left off — `:SpacetimeRows member` — in which case it is the one your
project's `spacetime.json` names; with neither, the command says so and does
nothing. Either spelling of the table works, source (`ledgerEntry`) or SQL
(`ledger_entry`).

Everything under `:Spacetime` above then applies: the same grid, the same
keymaps, the same cache.

### `:SpacetimeSchema`

`:SpacetimeSchema spacegym.ledgerEntry` describes one table in the content
window: its columns with their resolved types, then its indexes, its
constraints, and the whole module's reducers. The database may be left off and
either spelling of the table works, exactly as for `:SpacetimeRows`. Views are
described too — a view has neither indexes nor constraints, and says so.

```
ledgerEntry (ledger_entry)
table · Private · 5 columns · schema v10

Columns
  entry_id        U64                 PK autoinc
  transaction_id  { __uuid__: U128 }
  security_id     String
  amount          I64
  account         Array<String>

Indexes
  ledgerEntry_entryId_idx_btree  BTree(entry_id)  accessor entryId

Constraints
  ledger_entry_entry_id_key  Unique(entry_id)

Reducers (spacegym)
  ClientCallable  book(instanceId: U64) -> ok {} / err String
  Private         onConnect (on_connect)() -> ok {} / err String
```

Where a name was written one way in the module and is spelled another way in
SQL, both are shown — `ledgerEntry (ledger_entry)`, `onConnect (on_connect)`.
The SQL endpoint accepts either, so neither spelling is a trap.

A reducer is marked `ClientCallable` or `Private` as the server reports it, and
a `Private` one is greyed out rather than hidden: it is part of the module, it
is simply not yours to call. Servers older than SpacetimeDB 2.0.4 answer with a
schema that has no visibility field at all, and there the marker is **omitted
entirely** rather than guessed at — an unknown visibility means "assume
callable", because labelling every reducer `Private` would be a claim about
your module rather than a report of what the server said.

Nothing in this view is truncated, and it binds no keys of its own. The schema
is the same one the sidebar caches, so describing a table in a database you have
already expanded costs no request; `r` in the sidebar drops it.

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
