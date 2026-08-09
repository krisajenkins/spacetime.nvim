# Testing Notes for spacetime.nvim

Testing-specific guidance for Claude Code when working with this test suite.

## Test Framework: MiniTest

Tests use [mini.test](https://github.com/echasnovski/mini.test), cloned into
`deps/mini.nvim` by the Makefile. The runner boots headless Neovim on
`scripts/minimal_init.lua`, which puts the repo root, `deps/mini.nvim` and
`deps/plenary.nvim` on the runtimepath — nothing else. Your real Neovim config
is NOT loaded.

### Basic structure

```lua
local T = MiniTest.new_set()
local expect = MiniTest.expect

T["describes what it checks"] = function()
  expect.equality(actual, expected)
end

return T
```

Name cases as sentences (`T["setup() rejects a non-table argument"]`) rather
than as identifiers — the name is what the failure output shows.

### Child Neovim tests

Anything that needs a real editor (commands, buffers, autocommands, `:w`
handling) runs in a child Neovim. Use the shared helper instead of repeating the
setup:

```lua
local child, new_set = require("tests.helpers.child")()

local T = new_set()                          -- standard hooks
local T = new_set({                          -- standard hooks + extra setup
  pre_case = function(c)
    c.lua([[ M = require('spacetime') ]])
  end,
})
```

The helper restarts the child per case, adds plenary to its runtimepath and
installs an `expect` global inside the child.

**`expect` inside `child.lua()` is the child's global, not the parent's.** The
helper installs it; if you build a child by hand you must do
`expect = require('mini.test').expect` in the child yourself.

## Key Assertions

- `expect.equality(actual, expected)`
- `expect.no_equality(actual, expected)`
- `expect.error(function() ... end)`
- `expect.no_error(function() ... end)`
- `expect.reference_screenshot(child.get_screenshot())` — visual regression

Screenshot references live in `tests/screenshots/`, named
`tests-{filename}---{test_name}`. Delete the reference and re-run the file to
re-baseline; review the new image before committing it.

## Running Tests

```bash
make test                                  # all
make test_file FILE=tests/test_main.lua    # one file
nix develop --command make test            # outside a direnv shell
```

## Mocking Dependencies with package.loaded

Prefer lazy `require()` calls (inside functions, not at file top level) in
plugin code — it lets tests inject mocks before the module is first used:

```lua
package.loaded["spacetime.lib.cli"] = {
  call = function()
    return { success = true, stdout = "", stderr = "" }
  end,
}
```

Force a fresh load when a test needs pristine module state:

```lua
package.loaded["spacetime"] = nil
local spacetime = require("spacetime")
```

Always restore what you stub — `tests/test_health.lua` shows the
stub → assert → restore shape for a module that captures a global (`vim.health`)
at require time.

## Gotchas Learned the Hard Way

- **`buftype` matters for `BufWriteCmd`.** A `nofile` buffer *refuses* `:w` with
  `E382` and never fires `BufWriteCmd`. A "write to submit" buffer must use
  `buftype = "acwrite"`.
- **Open the buffer in a split before driving `:q`/`:wq`/`ZZ` in a child.** If
  the target window is the last one, the quit exits the child Neovim and the
  test hangs.
- **Lua `ipairs` stops at the first `nil`.** A logging helper built with
  `for _, v in ipairs({...})` silently truncates at the first `nil` argument —
  common when debugging (`log("ok:", ok, "err:", err)` drops everything after a
  `nil` `err`). Use `select('#', ...)` when args may be `nil`.
- **Assertions on external side effects need a seam.** Code that shells out
  directly (rather than through a mockable CLI module) can't be observed; give
  it a seam, or replace the method on the instance with a counter and assert the
  count.

## Test Environment Assumptions

`tests/test_health.lua` asserts the `spacetime` CLI and plenary are both
present, which holds inside `nix develop` and in CI. Running `make test` from a
bare shell without the CLI on `PATH` will fail that case legitimately.
