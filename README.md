# spacetime.nvim

A Neovim plugin for [SpacetimeDB](https://spacetimedb.com).

> **Status: scaffolding.** The build, test, lint and CI infrastructure is in
> place; the plugin itself does nothing yet.

## Requirements

- Neovim >= 0.11.0
- The `spacetime` CLI >= 2.0.0 on your `PATH`
- `curl` on your `PATH` — used for all HTTP requests to SpacetimeDB

Run `:checkhealth spacetime` to verify all three.

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
})
```

- `log_level` — minimum severity for the plugin's own `vim.notify()` messages.
- `identity` — overrides the identity derived from your token's claims; a
  last-resort escape hatch.

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
