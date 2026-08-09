# Testing Notes for spacetime.nvim

Testing-specific guidance for Claude Code when working with this test suite.

## Test Framework: MiniTest

Tests use [mini.test](https://github.com/echasnovski/mini.test), cloned into
`deps/mini.nvim` by the Makefile. The runner boots headless Neovim on
`scripts/minimal_init.lua`, which puts the repo root and `deps/mini.nvim` on the
runtimepath — nothing else. Your real Neovim config is NOT loaded.

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

The helper restarts the child per case and installs an `expect` global inside
the child.

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
plugin code — it lets tests inject mocks before the module is first used.

The transport seam is `spacetime.lib.http`. A buffered request stub:

```lua
package.loaded["spacetime.lib.http"] = {
  request = function(opts, on_done)
    on_done(nil, { status = 200, headers = { ["content-type"] = "application/json" }, body = "{}" })
  end,
}
```

A response table is always `{status = <number>, headers = <table>, body = <string>}`.

Streaming is stubbed at `http.stream`, which drives an `on_line` callback per line
and then a completion callback:

```lua
package.loaded["spacetime.lib.http"] = {
  stream = function(opts, on_line, on_done)
    for _, line in ipairs({ '{"level":"Info"}', '{"level":"Error"}' }) do
      on_line(line)
    end
    on_done(nil)
    return { kill = function() end }
  end,
}
```

Every callback above `lib/http.lua` is `vim.schedule_wrap`ped there, so higher
layers may assume main-loop context. The sole exception is the streaming
`on_line`, which stays in the fast-event context and may only touch plain
tables — a test asserting on `on_line` must not call `vim.api` from it.

`http._system` is the injection point for a fake `vim.system`, so exit-code
mapping can be exercised with no process spawned:

```lua
local http = require("spacetime.lib.http")
local saved = http._system
http._system = function(cmd, opts, on_exit)
  on_exit({ code = 0, stdout = "HTTP/1.1 200 OK\r\n\r\n{}", stderr = "" })
  return { kill = function() end }
end
-- ... assert ...
http._system = saved
```

`http.build()` and `http.parse_head()` are pure — argv/stdin in, data out — so
they need no stub at all. The bearer token travels via `-K -` on stdin, never in
argv, so argv assertions must confirm the token is *absent*.

Force a fresh load when a test needs pristine module state:

```lua
package.loaded["spacetime"] = nil
local spacetime = require("spacetime")
```

Always restore what you stub — `tests/test_health.lua` shows the
stub → assert → restore shape for a module that captures a global (`vim.health`)
at require time.

### Stub the transport, not the client

Child-Neovim tests stub `spacetime.lib.http`, **never** `spacetime.lib.client`.
That keeps client-level logic genuinely exercised rather than mocked away: the
`classify(status, body)` error mapping (503 + `"paused"`, 401, 404, 400) and the
`list_databases` fan-out with its completion counter.

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
  directly (rather than through `spacetime.lib.http`, or through its `http._system`
  injection point) can't be observed; give it a seam, or replace the method on the
  instance with a counter and assert the count.

## Test Environment Assumptions

`tests/test_health.lua` asserts the `spacetime` CLI and `curl` are both
present, which holds inside `nix develop` and in CI. Running `make test` from a
bare shell without the CLI on `PATH` will fail that case legitimately.
