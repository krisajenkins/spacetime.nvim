# Roadmap: spacetime.nvim → a SpacetimeDB browser

## Context

`spacetime.nvim` is currently scaffolding: build, test, lint, docs and CI are wired
up, but the plugin does nothing. The goal is to turn it into a Neovim-native
SpacetimeDB browser — the same job as `spacetimedb-tui`, but as buffers and
`:Spacetime*` commands rather than a terminal app, and with a reusable Lua
SpacetimeDB client library underneath (the role `gleam-spacetimedb` plays for Gleam).

**Decisions taken:**

| Decision | Choice |
|---|---|
| Transport | **Direct HTTP** via `curl`, mirroring `spacetimedb-tui`. Not the `spacetime` CLI. |
| UI | **Neovim-native**: sidebar tree buffer + content buffers + `:Spacetime*` commands. Not a TUI clone, and not a wrapper around the `spacetimedb-tui` binary. |
| Entry point | **`:Spacetime` opens the full layout** — sidebar *and* content window — not just the sidebar. One front door; the other commands are shortcuts into it. |
| Project awareness | A repo's `spacetime.json` / `spacetime.local.json` selects the server and database, so `:Spacetime` inside a module repo opens the right database. |
| v1 scope | Browse databases → tables → schema → rows; log viewer with follow. |
| Writes | Reducer calls only, and not in v1. No INSERT/UPDATE/DELETE. |
| Live subscriptions | **Deferred.** v1 needs no WebSocket at all — log follow is plain HTTP streaming. |

Deferring subscriptions is what makes v1 tractable: no WebSocket client, no BSATN
decoder, no TLS handling in Lua. Everything is JSON over `curl`.

---

## Verified facts (probed live against SpacetimeDB 2.8.0 / maincloud)

These were confirmed by hand, not assumed. They pin down several designs.

**Endpoints** (base `{http|https}://{host}[:{port}]`, all with `Authorization: Bearer <token>`):

```
GET  /v1/ping
GET  /v1/identity/{hex_identity}/databases   -> {"identities":[...]}
GET  /v1/database/{db}/names                 -> {"names":[...]}
GET  /v1/database/{db}/schema?version=10     -> {sections:[{Typespace},{Types},{Tables},{Reducers},{Views},…]}
GET  /v1/database/{db}/schema?version=9      -> {typespace,tables,types,reducers,misc_exports,row_level_security}
POST /v1/database/{db}/sql                   body: raw SQL, Content-Type: text/plain
GET  /v1/database/{db}/logs?num_lines=N&follow=true|false   -> NDJSON
POST /v1/database/{db}/call/{reducer}        body: JSON array of args
```

1. **`vim.json.decode` corrupts large integers — the single most important finding.**
   `62380668703079865784535937082191660312` (a real `st_client.connection_id`, U128)
   decodes to `9223372036854775808`. `18446744073709551615` (U64 max) does too.
   `9007199254740993` loses its last digit. A U64 primary key above 2^53 is silently
   wrong. `vim.fn.json_decode` behaves identically — there is no built-in escape.
   See "Why a big-integer pre-pass" below for why no library solves this for us.
2. **Wire shapes are inconsistent per width.** U256 `identity` arrives as the hex
   *string* `"0xc2005efe…"`; U128 `connection_id` arrives as a bare *number*. The
   pre-pass has to handle both, and the formatter must not assume either.
3. **Auth is OIDC**, so blake3 identity derivation is unavoidable. The token's JWT
   payload has `iss`/`sub` and **no** `hex_identity`, so
   `/v1/identity/{hex}/databases` — the only way to list databases — needs
   `identity = 0xc200 ++ blake3(0xc200 ++ h)[..4] ++ h` where `h = blake3("{iss}|{sub}")[..26]`.
   Both blake3 inputs are far under 1024 bytes → **single-chunk blake3 only**, no
   tree hashing. LuaJIT's `bit` is available.
4. **Target schema version 10, not 9** — see "Why schema v10" below. `?version=` is
   **required** and accepts only `9` or `10`; omitting it or sending `11` is a 400, not a
   default. Both are live on maincloud (verified: 35,189 vs 41,026 bytes for the same
   module). The CLI's `describe --json` emits the *same* v10 sectioned shape, so it is a
   convenient way to capture fixtures rather than a red herring.
5. `~/.config/spacetime/cli.toml` exists at the **XDG path even on macOS**, holds
   `default_server`, `spacetimedb_token` (use this, *not* `web_session_token`), and
   repeated `[[server_configs]]` blocks.
6. SQL errors return **HTTP 400 with a plain-text body**, not JSON. Paused databases
   return **503 with "paused"** on every endpoint and must never be retried.
7. `vim.fn.strdisplaywidth`: `£`=1 (2 bytes), `🎟`=2 (4 bytes). Real data in these
   databases contains both, so `#s` is unusable for column layout.
8. SQL rows are **positional arrays**; sums arrive as `[variant_index, payload]`;
   Timestamp is a one-element array `[1780864718837447]`.
9. **`spacetime.json` is a real convention**, confirmed by reading five of the user's own
   module repos rather than inferring a shape. Keys seen: `server`, `database`,
   `module-path`, `generate[]`, `dev.run`. `spacetime.local.json` sits beside it as the
   per-developer override and is **`.gitignore`d in 3 of the 5** — so it must be treated
   as optional and possibly absent, never required. Only `server` and `database` matter
   to a browser.

**Fixtures are already captured and committed** to `tests/fixtures/`, so every task below
is executable offline with no token and no network:

| File | What it pins down |
|---|---|
| `schema_v10.json` (41 KB) | the sectioned v10 shape — task 17's primary path |
| `schema_v9.json` (35 KB) | the flat v9 shape — task 17's fallback path |
| `sql_rows.json` | `£` and `🎟` in real rows, plus an Option encoded as `[0,"£"]` |
| `sql_bigint.json` | U256 identity as a hex *string* beside a U128 as a bare *number* |
| `logs.ndjson` | 11 real NDJSON log lines |

All five were scanned for tokens, JWTs and e-mail addresses before committing; the only
identifier in them is the account identity already recorded in fact 3.

---

## Architecture

Split cleanly into a **library layer** and a **UI layer**. The library never touches
`vim.api`/`vim.fn`/`vim.ui`/`vim.notify` — so it is unit-testable headlessly with no
child Neovim, and usable as a scripting API from a user's own config.

```
lua/spacetime/lib/       -- no buffers, no windows, no user interaction
  json.lua        big-integer-preserving JSON decode (scanner + vim.json.decode)
  clitoml.lua     deliberately-partial cli.toml parser (documented as not general TOML)
  blake3.lua      single-chunk BLAKE3 on LuaJIT `bit`; error()s above 1023 bytes
  identity.lua    JWT payload decode; legacy hex_identity, else from_claims(iss, sub)
  http.lua        curl argv/stdin build, response-head parse, request(), stream()
  client.lua      one method per endpoint; cb(err, value); error classification
  schema.lua      /schema?version=10 (v9 fallback) -> tables, views, reducers, columns, PKs
  value.lua       AlgebraicType + raw value -> display string + highlight class
  sql.lua         SQL response envelope -> {columns, rows}; SELECT builder
  logs.lua        NDJSON line -> log entry; level ordering

lua/spacetime/
  config.lua      resolve connection from setup opts + env + spacetime.json + cli.toml
  state.lua       the one module-level state table; caches, in-flight registry, debounce
  commands.lua    :Spacetime* definitions and completion
  ui/
    highlights.lua  default-linked highlight groups
    buffer.lua      scratch-buffer primitives + the idempotent sidebar/content layout
    tree.lua        sidebar: databases -> tables
    grid.lua        pure row-grid layout (widths, truncation, byte offsets, spans)
    rows.lua        rows buffer controller: fetch, sort, page, yank
    schema.lua      schema detail buffer
    logs.lua        log buffer, follow lifecycle, coalesced flush
```

Roughly 3,500–4,000 lines total. `plugin/spacetime.lua` grows only by thin
require-on-invoke command registrations.

### Why Lua, and not a Rust or TypeScript sidecar

Lua is Neovim's primary extension language, not its only one, so "reimplement SpacetimeDB
in Lua" deserved a challenge before ~2,000 lines of `lib/` got written. Checked against
the 2.8.0 source at `~/Work/ThirdParty/SpacetimeDB`.

**The official client SDKs cannot do this job at all.** `sdks/rust/src/spacetime_module.rs:35`
defines `trait SpacetimeModule` with ten associated types — `DbConnection`, `EventContext`,
`Reducer`, `DbView`, `Reducers`, `Procedures` and more — every one supplied by
`spacetime generate` for one specific module. `sdks/typescript/src/sdk/spacetime_module.ts`
has the same shape. They give typed access to a database known at compile time; a browser
needs untyped access to arbitrary databases discovered at runtime. There is no
`connect_untyped()`.

The corroboration is in the reference project: `spacetimedb-tui/Cargo.toml` depends on
`reqwest`, `tokio-tungstenite`, `serde_json` and `blake3`, and **not** on `spacetimedb-sdk`.
Someone built this exact tool in Rust with every advantage available and still bypassed the
SDK. So "just use the Rust client" is not an option that exists.

What *is* valuable sits one layer below the SDKs, and is worth reading even though we are
not linking it:

- `crates/sats/src/de/impls.rs:583` — `impl DeserializeSeed for WithTypespace<'_, AlgebraicType>`,
  decoding any value against a runtime type.
- `sdks/typescript/src/lib/algebraic_type.ts:527` — `AlgebraicType.makeDeserializer(ty)`,
  which JIT-compiles a decoder with `Function(...)` and memoises it.

Both are reference implementations of the reflective decode that task 18 (`lib/value.lua`)
has to reproduce. Read them before writing it.

**A sidecar is technically easy.** `jobstart(cmd, {rpc = true})` opens a bidirectional
msgpack-RPC channel (`$VIMRUNTIME/doc/channel.txt:146`), so the child process can call
`nvim_buf_set_lines` itself rather than merely answering queries. The alternatives are
`nvim-oxi` as a cdylib loaded by `require` — no IPC, but pinned to Neovim's ABI, awkward
against 0.12.4 — and the legacy `rplugin` host, which needs `:UpdateRemotePlugins` and buys
nothing.

**And it would delete real work.** A sidecar removes essentially all of `lib/` — json,
blake3, identity, http, schema, value, sql, logs — about 2,000 of the ~3,800 lines. The UI
layer survives unchanged in every scenario, because that is Neovim API work either way.
Rust in particular kills the two top-ranked risks below outright: `blake3 = "1"` instead of
hand-rolled single-chunk BLAKE3 (risk 2), and native `u128`/`u256` in `sats` instead of a
pre-pass (risk 1). It also brings TLS, a real WebSocket and BSATN, which would move live
subscriptions from deferred-indefinitely to merely later.

Node solves the integer problem too, and natively. Verified on Node 24:

```
plain JSON.parse:    6.238066870307987e+37                    <- corrupted, as vim.json.decode
source-text reviver: 62380668703079865784535937082191660312   <- exact
```

A three-line reviver using the source-text argument replaces task 6 entirely. But the
TypeScript SDK is a browser *frontend* package — a 13 MB `dist/`, with peer dependencies on
React, Vue, Svelte, Solid and Angular — and its `AlgebraicType` is `{tag: 'Ref', value: n}`
(`algebraic_type_variants.ts:7`) where the HTTP schema wire format is `{"Ref": n}`, so an
adapter comes before any of it is usable.

**The decision.** v1 as scoped is the worst possible case for a sidecar. Browse-and-log is
JSON over HTTP: no BSATN, no WebSocket, no TLS in-process. Every one of the sidecar's real
wins lands in the deferred column. Against that it costs cross-compilation for five platform
triples, release CI, a download-or-build install step, and a permanent class of "the binary
didn't start" bug report — for a plugin whose entire dependency list is otherwise `curl`.

So: Lua, and the library/UI split is the hedge. `lua/spacetime/lib/` is *defined* as touching
no `vim.api`, which makes it a clean seam rather than an aesthetic preference. If
subscriptions come back on the table, the library layer can be swapped for an RPC sidecar and
the UI layer never learns about it. That is an argument for keeping the split honest — no
`vim.notify` creeping into `lib/`, no buffer handles in `client.lua` — not for abandoning Lua
now.

### Why curl (there is no native alternative)

Checked against the pinned Neovim 0.12.4 rather than assumed:

- **`vim.net.request` — Neovim 0.12's "native" HTTP client — is itself a curl wrapper.**
  `$VIMRUNTIME/lua/vim/net.lua` is ~60 lines that build `{'curl', '--silent',
  '--show-error', '--fail', '--location', '--retry', N, url}` and hand it to
  `vim.system`. Neovim shells out to curl too.
- **Neovim exposes no TLS to Lua.** `require` fails for `ssl`, `socket`, `openssl` and
  `mbedtls`; the `nvim` binary links no curl/ssl/tls library at all. `vim.uv` gives raw
  TCP only. HTTPS from pure Lua would mean implementing TLS 1.3 by hand — impractical,
  and a bad idea on its own merits. maincloud is HTTPS-only.
- LuaSocket + LuaSec are the mature ecosystem answer, but they are **C modules**. A
  Neovim plugin cannot require a compiler at install time.

So curl is not a shortcut we are taking in preference to something better — it is the
mechanism Neovim itself uses. What we add to `flake.nix` is a declaration of a
dependency that is already implicitly there.

**Why not just call `vim.net.request`?** Not from lack of trying — it is missing exactly
the things we need:

| Need | 0.12.4 (pinned) | neovim master |
|---|---|---|
| Custom headers (`Authorization: Bearer`) | ✗ | ✓ `--header` |
| `POST` with a body (`/sql`, `/call`) | ✗ GET only | ✓ `--request` + `--data-binary @-` |
| **Response status code** | ✗ `Response` is `{body}` only | ✗ still `{body}` only |
| **Streaming response** (log follow) | ✗ buffered `on_exit` | ✗ buffered `on_exit` |

On 0.12.4 it cannot even authenticate, so it is not an option today. Master has grown
headers, methods and bodies, but two blockers remain: without a status code we cannot
distinguish 503-paused from 401 from 404, and without streaming there is no log follow.
Worse, it passes `--fail`, which makes curl **discard the response body** on any non-2xx —
and SpacetimeDB returns SQL errors as HTTP 400 with the message in that body, so we would
lose every query error message. Its default `--retry 3` would also silently retry
non-idempotent reducer calls.

neovim#38946 ("vim.net as a full-fledged HTTP client") tracks closing the gap. Keep
`lib/http.lua` a thin seam so `vim.net` can be swapped in underneath it if status codes and
streaming ever land.

### HTTP primitive: `vim.system()` + curl; drop plenary

`plenary.curl` buffers the whole response, so log-follow would have to reach past its
API into `plenary.job` anyway — at which point plenary buys nothing. `vim.system`
gives incremental `stdout` callbacks and `obj:kill()` for free, and dropping plenary
leaves the plugin with **no Lua dependencies at all**.

- Base argv: `curl -sS -i --http1.1 --max-time N -X METHOD url` (`--no-buffer`, no
  `--max-time`, when streaming).
- `-i` gives one uniform code path for buffered and streaming requests, and means the
  503-paused case is still detectable in follow mode.
- **The bearer token goes via `-K -` on stdin, never in argv** — argv is visible in `ps`.
- `http.build()` and `http.parse_head()` are pure functions returning data, so the
  whole request-construction layer unit-tests without spawning a process.
- Every callback above `lib/http.lua` is `vim.schedule_wrap`ped there, so all higher
  layers can assume main-loop context. The one exception is the streaming `on_line`,
  which stays in the fast-event context and only mutates plain tables.

### Async and state discipline

One module-level table in `state.lua`; UI modules read it freely but mutate only
through `state.*` functions.

- **Cancellation:** every request registers under a stable key (`"schema:<db>"`,
  `"rows:<db>.<table>"`, `"logs:<db>"`). Starting a second under the same key kills the
  first, *and* a monotonic seq guard discards responses that arrive after a kill —
  `kill` is asynchronous, so without the seq guard rapid `<CR>` between two tables can
  paint table A's rows into table B's buffer.
- **Caching:** session-lifetime, no TTL, keyed by db name and `"{db}.{table}"`, exactly
  as the TUI does. `r` is the invalidation mechanism.
- **Paused status is discovered reactively**, never probed at startup — that would be
  N requests on launch for information that goes stale anyway.
- **Log follow coalesces:** parse inline in the fast-event callback, append to a pending
  buffer, and let a single repeating 100 ms `vim.uv` timer do the `nvim_buf_set_lines`.
  A chatty module at 500 lines/sec must produce 10 flushes per second, not 500.

### Why schema v10 (with a v9 fallback)

`RawModuleDefV10` landed in SpacetimeDB v2.0.4 (`crates/lib/src/db/raw_def/v10.rs`,
exposed by commit `018575d1f`), so every server from 2.0.4 onward accepts `?version=10`.
Verified live against maincloud on the real module:

| | v9 | v10 |
|---|---|---|
| Shape | flat struct | `{sections: [...]}`, one tagged object per section |
| Reducer **visibility** | **absent** | `{"ClientCallable":[]}` / `{"Private":[]}` |
| Reducer return types | absent | `ok_return_type`, `err_return_type` |
| Views | buried in `misc_exports` beside `ColumnDefaultValue` | first-class `Views` section |
| Schedules, lifecycle reducers | on the table / on the reducer | own sections |
| Column defaults | `misc_exports` | inline `default_values` on the table |
| Table names | canonical (`ledger_entry`) | `source_name` (`ledgerEntry`) + `ExplicitNames` mapping |
| `is_event` on tables | absent | present |
| Lossiness | drops `http_handlers`, `http_routes`, `submodules` | complete |

**The deciding factor is reducer visibility.** On the real `spacegym` module, 5 of 19
reducers are `Private`; v9 carries no visibility field at all, so a v9-based browser would
offer all 19 as callable and 5 would fail at call time. Since reducer calls are the one
planned write feature, that alone justifies v10.

**Names — a wrinkle that turned out benign.** In v10, `Tables[].source_name` is the name as
written in the module (`ledgerEntry`), while SQL and the system tables use the canonical
name (`ledger_entry`); the `ExplicitNames` section carries `{source_name, canonical_name}`
pairs. Verified that the SQL layer accepts **both** spellings (`SELECT * FROM ledgerEntry`
and `… FROM ledger_entry` both return 200), so this is not a correctness trap. Still,
resolve through `ExplicitNames` and *query* the canonical name, while *displaying* the
source name — the developer wrote `ledgerEntry` and that is what they will look for in the
sidebar. Column names are canonical in both versions' typespaces, so only table, reducer,
view and type names need mapping.

**Fallback.** Self-hosted servers older than 2.0.4 only speak v9. Mirror the CLI's own
negotiation (`crates/cli/src/api.rs:65-95`): request v10, and on a 4xx retry with v9 and
normalise into the same internal model. About ten lines, and it keeps old servers working.

**Caveat.** `RawModuleDefV10Section` is `#[non_exhaustive]` — new section kinds will appear
(the checkout already has `Procedures`, `HttpHandlers`, `HttpRoutes`, `ViewPrimaryKeys`,
`Submodules`, `CaseConversionPolicy`). The parser must skip unrecognised sections silently
rather than erroring.

### Why a small pre-pass of our own, and no vendored library

First, why no numeric type can save us. Lua numbers are IEEE-754 doubles with a 53-bit
mantissa; the widest integer reachable from Neovim Lua is LuaJIT's 64-bit cdata. **A
U128 is ~2^125 and a U256 far beyond — nothing available to us can hold one.** Any
correct decoder must hand these back as strings or bignum objects. The browser only
displays and sorts them, so a string is the right representation, not a compromise.

Second, the libraries. Two do expose custom number handling, so this was worth taking
seriously:

| Option | Licence | Why not |
|---|---|---|
| Friedl `JSON.lua`, `decodeIntegerStringificationLength = 16` | CC-BY 3.0 | The option works. But **it decodes `null` to `nil`**, so `[1, null, 3]` becomes a 3-element array of length 1. Needs a patch after all. Also 1869 lines, and CC-BY into an MIT repo is a wrinkle. |
| rxi/json.lua + 5-line patch | MIT | Clean and fast, but same `null` → `nil` defect, so it is a maintained fork. |
| lunajson | MIT | Source confirms `fixedtonumber` is a local with no hook; SAX `number(n)` receives an already-parsed number. |
| lua-cjson, rapidjson (`kParseNumbersAsStringsFlag`) | — | C modules. A Neovim plugin cannot require a compiler. |
| Neovim's fix (neovim#24532, closed in 0.11.3) | — | Raised *encode* precision 14→17 significant digits. Nothing above 2^53. Verified: 0.12.4 still returns `9223372036854775808` for U64 max. |
| `vim.fn.json_decode` | — | Byte-identical corruption. Verified. |

**Every third-party candidate needs patching, because they all drop JSON `null`.** That
matters more than the integers: SQL rows are *positional* arrays, so a dropped null
shortens the row and shifts every subsequent column — silent, and miserable to debug.
`vim.json.decode` is the only decoder here that already gets this right (`vim.NIL`).

**Decision: keep `vim.json.decode` and own a ~35-line pre-pass.** No fork, no upstream to
track, no licence question, and Neovim's maintained C decoder still does all the hard parts
— nulls, unicode escapes, deep nesting, error reporting. Our code only rewrites number
tokens outside string literals: walk the text, copy string literals verbatim (honouring
`\` escapes), and in the regions between them quote any integer of ≥16 digits.

Measured on the real 34.4 KB schema: `vim.json.decode` alone **0.18 ms**, pre-pass +
`vim.json.decode` **0.74 ms**. Perf is a non-issue at real payload sizes, so this is
decided on maintenance and licence, not speed.

Verified against the awkward cases: `62380668703079865784535937082191660312` and its
negative both survive exactly; `42`, `-17`, `1.5`, `-2.25` and `1e3` stay numbers; digits
inside string literals, `\"`-escaped quotes, a trailing `\\`, and `£` are all left
alone; `[1, null, 3]` keeps length 3 with `vim.NIL` in position 2.

Schema-awareness cannot substitute for this, incidentally: the response's `schema` does
say which columns are U64/U128/U256, but the corruption happens during the very decode
that produces that schema.

### Row grid rendering

- Widths from `vim.fn.strdisplaywidth`, cached per cell in a parallel array (`#s` is
  wrong for both `£` and `🎟`, which are in the live data).
- **Sanitise every cell first** (`\n` → `␊`, C0 → `·`). One line per row is the invariant
  every index mapping depends on; a String column containing a newline would break it
  silently.
- Truncate by binary-searching `strcharpart` + `strdisplaywidth` — never splits a
  multibyte sequence.
- Two arrays, `order[display_pos] = data_idx` and its inverse `rank`, so sorting rebuilds
  only the mapping and the cursor can be restored to the same *data* row. **Sort on raw
  values, not display strings** — otherwise `"10"` sorts before `"9"` and formatted
  timestamps misplace. `table.sort` is unstable, so tiebreak on the data index.
- One `nvim_buf_set_lines` for the whole grid, then extmarks only for headers, NULLs,
  PK columns, special newtypes and truncation ellipses — a few hundred marks, not one
  per cell.

---

## Ordered task list

Every task ends with `make` (typecheck + test) green — the repo rule. Each is sized to
be one commit.

### Phase 0 — Foundation

0. ~~**Write this roadmap into the repo.**~~ (done — this file)
1. **Widen `logger.lua`** — varargs with `select('#', ...)` (the `ipairs`-stops-at-nil
   gotcha in `tests/CLAUDE.md`), `get_level()`, and `redact()` that strips bearer tokens
   and bare JWTs from any logged string. → `tests/test_logger.lua`
2. **Bump the stated Neovim minimum to 0.11** in `health.lua`, `README.md`,
   `doc/spacetime.txt`. `lua/spacetime.lua:28` already uses the 0.11-only
   `vim.validate(name, value, type, optional)` signature, so the advertised 0.9.0 is
   already untrue. Free to fix now; a breaking change later.
3. **Declare curl in `flake.nix`; remove plenary.** Note the direction: curl is *added*
   (it is currently absent from `buildInputs` and CI only gets it ambiently from the
   runner image), plenary is *removed*. Touches eight files — `Makefile`, `scripts/minimal_init.lua`,
   `tests/helpers/child.lua`, `health.lua` (`check_plenary` → `check_curl`), `tests/test_health.lua`,
   `README.md`, `doc/spacetime.txt`, `flake.nix` (curl is not currently in `buildInputs`;
   CI only gets it ambiently). Completion criterion: `grep -ri plenary` is clean.
4. **Update `tests/CLAUDE.md`** — it currently prescribes mocking `spacetime.lib.cli` with
   a `{success, stdout, stderr}` shape. The seam is now `spacetime.lib.http` returning
   `{status, headers, body}`.
5. **`ui/highlights.lua`** — default-linked groups, registered from `plugin/spacetime.lua`,
   so renderers written later have something to reference.

### Phase 1 — Library: config, identity, JSON

6. **`lib/json.lua`** — `decode(text)`: a ~35-line pre-pass that quotes integer literals of
   ≥16 digits outside string literals, then delegates to `vim.json.decode`. No vendored
   library (see "Why a small pre-pass of our own" above — every candidate drops JSON `null`,
   which silently shortens positional row arrays).
   → `tests/test_json.lua`: the real U128 and its negative surviving exactly; `42`, `-17`,
   `1.5`, `-2.25`, `1e3` staying numbers; digits inside string literals, `\"`-escaped
   quotes, a trailing `\\` and non-ASCII all left alone; `[1, null, 3]` keeping length 3
   with `vim.NIL` in position 2. Benchmark against the 34.4 KB live schema fixture to keep
   the pass honest (budget: under 1 ms).
7. **`lib/clitoml.lua`** — the cli.toml subset: top-level `key = value`,
   `[[server_configs]]` blocks, `#` comments; unknown keys and malformed lines ignored.
   → `tests/test_clitoml.lua`, including a file containing `web_session_token` which must
   be ignored in favour of `spacetimedb_token`.
8. **`config.lua`** — XDG-aware `cli_config_path` (injectable for tests), host:port
   splitting with protocol-derived defaults (443/80, not 3000), and a pure
   `resolve(opts, env, project_cfg, cli_cfg)`. Port the resolution test cases from the
   TUI's `src/config.rs` — they are the specification. → `tests/test_config.lua`

   Also **per-project config discovery**, since a repo usually knows which database it
   means. Walk up from the current buffer's directory (falling back to `getcwd()`) to the
   VCS root, testing for `.jj` **or** `.git` at each level — `.git` may be a *file* in
   worktrees and submodules, so test existence, not directory-ness, and stop at the first
   hit so a colocated jj repo resolves once. Read `spacetime.json` there, then overlay
   `spacetime.local.json` on top of it. Only `server` and `database` concern us;
   `module-path`, `generate` and `dev` belong to the CLI's build flow and are ignored.
   `server` is a cli.toml nickname, so it resolves *through* the existing chain rather
   than around it. Full precedence, highest first:

   ```
   setup() opts  >  env  >  spacetime.local.json  >  spacetime.json  >  cli.toml default_server
   ```

   A missing or malformed project file is not an error — fall through to the next source.
   → `tests/test_config.lua` covers both files present, local-only, neither, malformed
   JSON, and a `.git` *file* rather than a directory.
9. **`lib/blake3.lua`** — single-chunk only. Gate it on the official BLAKE3 test vectors
   at 0/1/2/3/63/64/65/127/1023 bytes, and make it `error()` above 1023 rather than
   silently returning a wrong digest. → `tests/test_blake3.lua`
10. **`lib/identity.lua`** — base64url repad (`vim.base64.decode` rejects unpadded input)
    → `vim.json.decode` → legacy `hex_identity` if present, else `from_claims`. Golden
    vectors: the TUI's `("https://auth.spacetimedb.com","test-subject-0001")` →
    `c2005855e0…`, and this account's real identity. → `tests/test_identity.lua`
11. **`:SpacetimeStatus`** — first user-visible feature. Prints server, TLS, derived
    identity, `token: present`, cli.toml path. Must never print the token itself.
    Mirror it in `:checkhealth`.

### Phase 2 — Library: transport

12. **`http.build` + `http.parse_head`** — pure. Token in stdin via `-K -`, not argv.
    `parse_head` must accept both `HTTP/2 200 ` (no reason phrase) and
    `HTTP/1.1 503 Service Unavailable`, and skip any `1xx` preamble.
13. **`http.request`** over a `http._system` seam for stubbing; cancellation handles;
    curl exit-code → message mapping (6 DNS, 7 connection refused, 28 timeout, 35/60 TLS).
14. **`http.new_line_splitter` + `http.stream`** — feed a canned response one byte at a
    time, in one lump, and with the chunk boundary falling *inside* `\r\n\r\n`; all three
    must yield identical lines.
15. **`lib/client.lua`** — one method per endpoint; `classify(status, body)` mapping
    503+"paused" → `paused`, 401 → `unauthorized`, 404 → `not_found`, 400 → `query` (with
    the plain-text body as the message). `list_databases` is a **fan-out with a completion
    counter**, not a serial chain — the TUI does N+1 requests here and doing that
    sequentially in Lua would be painfully slow.

### Phase 3 — Library: decoding

16. **`lib/sql.lua`** — envelope → `{columns, rows, duration_micros}`, tolerating the
    array wrapper, a bare object, an empty array, and a **missing `schema`** (mutation
    responses). Plus the `SELECT` builder with identifier quoting.
17. **`lib/schema.lua`** — parse the v10 `sections` array into one internal model: typespace,
    tables, views, reducers (with `visibility` and return types), schedules, PK columns,
    autoinc from `sequences`, `{"User":[]}`/`{"Public":[]}` tag extraction, the system-table
    set, and the `ExplicitNames` source↔canonical map. **Skip unrecognised sections
    silently** (`RawModuleDefV10Section` is `#[non_exhaustive]`). Watch the **1-based Lua
    index vs 0-based `product_type_ref`** off-by-one. Then add the v9 fallback path
    (`?version=10` → on 4xx retry `?version=9`) normalising into the same model, with views
    lifted out of `misc_exports` and `visibility` left `nil` — the UI must treat unknown
    visibility as "assume callable" rather than hiding reducers on old servers.
    → test against the committed `tests/fixtures/schema_v10.json` and `schema_v9.json`,
    which are the same module in both shapes.
18. **`lib/value.lua`** — `AlgebraicType` → label, and `(value, atype, typespace)` →
    display string + highlight class. Covers Ref (depth-limited, cycle-safe), Product,
    Sum as `[idx, payload]`, Option, Array, and the four magic newtypes
    (`__identity__`, `__connection_id__`, `__timestamp_micros_since_unix_epoch__`,
    `__time_duration_micros__`) — remembering Timestamp arrives as a one-element array.
    Unrecognised newtypes pass through verbatim rather than guessing.
19. **`lib/logs.lua`** — NDJSON entry parse tolerating `ts` as micros, as an RFC3339
    string, or absent; level normalisation and ordering; malformed lines skipped, not fatal.

### Phase 4 — UI plumbing

20. **`state.lua`** — the state table, `start(key, handle)` (kills the previous), the seq
    guard, `debounce(key, ms, fn)` on `vim.uv`, cache accessors, `reset()`.
    → `tests/test_state.lua` proves cancel-on-restart, stale-seq drop, and debounce coalescing.
21. **`ui/buffer.lua`** — get-or-create by `spacetime://…` name, `set_lines` with
    modifiable toggling, namespace, and the **layout primitive**: open-or-focus a sidebar
    window of fixed width alongside a content window, reusing either if it already exists
    rather than stacking duplicates. `open_layout()` returns both window handles and is
    idempotent, so re-running `:Spacetime` focuses the existing layout instead of
    splitting again.
22. **`commands.lua` + registrations** — `:Spacetime`, `:SpacetimeToggle`,
    `:SpacetimeConnect [nick]`, `:SpacetimeDatabases`, `:SpacetimeTables [db]`,
    `:SpacetimeRows [db.]tbl`, `:SpacetimeSchema [db.]tbl`, `:SpacetimeLogs[!] [db]`,
    `:SpacetimeLogsStop`, `:SpacetimeStatus`, with completion from cli.toml nicknames and
    cached schema.

### Phase 5 — Sidebar tree

23. **Pure `tree.build_lines(model)`** → lines + line→node map. Collapsed/expanded,
    loading, error, and paused (`⏸`) states; tables grouped user / view / system.
24. **`:Spacetime` opens the full layout** — the single front door. Sidebar plus content
    window via `open_layout()`, then fetch databases and render the tree; the content
    window shows a placeholder until something is selected. Keymaps in the sidebar:
    `<CR>`/`o`, `r` refresh, `q` close the layout, `y` yank name, `gi` yank identity,
    `?` help. If the project config (task 8) named a `database`, expand straight to it so
    running `:Spacetime` inside a module repo lands where the user meant.
25. **Expanding a database fetches its schema** (cached by db name) and renders
    tables/views/system tables. A `paused` error sets the flag and renders `⏸` with
    **exactly one request and no retry**.

### Phase 6 — Row grid

26. **`ui/grid.lua`, pure** — `display_width`, `sanitise`, `truncate`, and
    `layout(columns, cells, opts)` returning lines, widths, per-cell byte offsets and
    highlight spans. Tested against the real `£` / `🎟` data.
27. **`ui/rows.lua`** — `<CR>` on a table → `SELECT * FROM "t" LIMIT n` → format → layout
    → extmarks. Errors render in-buffer, never as a stack trace.
28. **Sort** — `order`/`rank` rebuild, raw-value comparator with index tiebreak, cursor
    preserved by data index and column.
29. **Paging** (`]p`/`[p` over OFFSET), row/duration badge, `y` yank cell, `Y` yank row as
    JSON, `K` row-detail float with full untruncated values.

### Phase 7 — Schema view

30. **`ui/schema.lua`** — columns with resolved types, PK and autoinc markers, access,
    indexes and constraints, plus the database's reducers with parameter signatures,
    `ok`/`err` return types, and a `ClientCallable`/`Private` marker. Show both the source
    name and the canonical name where they differ (`ledgerEntry` → `ledger_entry`).

### Phase 8 — Logs

31. **Static log view** — `:SpacetimeLogs [db]` → `logs?num_lines=N&follow=false`.
32. **Follow** — `:SpacetimeLogs!` starts `http.stream`; coalesced 100 ms flush; sticky
    bottom only when the cursor was already on the last line; ring buffer capped at 5000;
    `BufWipeout`/`VimLeavePre` autocmds and `:SpacetimeLogsStop` kill the handle.
33. **Level filter** — `<`/`>` cycle the minimum level, re-rendering from the ring buffer.

### Phase 9 — Docs and release

34. **Rewrite `README.md`** — requirements (Neovim 0.11+, curl, a `cli.toml` from
    `spacetime login`), commands, keymaps, config, how auth resolves.
35. **Rewrite `doc/spacetime.txt`** to match, run `make helptags`. README and vimdoc must
    agree — repo rule.
36. **Update `CLAUDE.md`** — the Layout section, and "integrates the SpacetimeDB
    CLI" becomes "talks to SpacetimeDB's HTTP API directly".

### Deferred past v1

- SQL scratch buffer (`buftype=acwrite` + `BufWriteCmd`, `:w` to execute) — the
  `tests/CLAUDE.md` gotchas already anticipate this.
- `:SpacetimeCall` — reducer invocation with a form driven by the parameter signature.
  Offer only `visibility == ClientCallable` reducers (on the real module that is 14 of 19);
  show `Private` ones greyed out in the schema view rather than hiding them.
- WebSocket live subscriptions, using the `v1.json.spacetimedb` subprotocol so no BSATN
  decoder is ever needed.
- Metrics tab (`GET /metrics`, Prometheus text).

---

## Verification

**Per task:** `make` (= `make typecheck test`) plus `make check-format`, matching CI.

**Unit tests, headless, no network, no child Neovim** — the bulk of the suite, and the
reason for the library/UI split. `test_json`, `test_logger`, `test_clitoml`,
`test_config`, `test_blake3`, `test_identity`, `test_http`, `test_client`, `test_sql`,
`test_schema`, `test_value`, `test_logs`, `test_state`, `test_grid`, `test_tree`.

**Fixtures are already captured** from the live 2.8.0 server and committed to
`tests/fixtures/` — see the table under "Verified facts". `schema_v10.json` and
`schema_v9.json` are the same module in both shapes, so the fallback path is tested against
real data, including camelCase source names so `ExplicitNames` is exercised. They are
faster, deterministic and reviewable in a diff, and they are what makes the task list
executable without credentials.

Re-capturing them is a manual, credentialed step and deliberately **not** part of any task.
For the record, they came from `curl -K` against `/v1/database/spacegym/{schema,sql,logs}`
with the token supplied on stdin. Anything a task still needs beyond these — synthetic
edge cases like a malformed NDJSON line or a non-`Info` log level — the task writes itself.

**Child-Neovim tests** for anything touching buffers, windows, commands, keymaps,
autocmds or extmarks, stubbing `spacetime.lib.http` (not the client, so client logic is
still exercised): `test_commands`, `test_buffer`, `test_tree_ui`, `test_rows_ui`,
`test_schema_ui`, `test_logs_ui`. Remember the documented gotcha — open buffers in a split
before driving `:q` in a child, or the child exits and the test hangs.

**One screenshot test** (`expect.reference_screenshot`) on the rows grid with the
`£`/`🎟` fixture. Column alignment is genuinely a visual property; a string assertion
would miss a terminal-level regression.

**End-to-end, by hand**, against a real account:
`:Spacetime` → expand a database → open a table → confirm `£` and `🎟` align and an
Option column renders as `some("£")` → `:SpacetimeSchema <table>` → `:SpacetimeLogs! <db>`
→ confirm lines stream and `:SpacetimeLogsStop` terminates the curl process.

**Optional, Phase 9:** a `make test-integration` target using the `spacetimedb-standalone`
binary the Nix overlay already installs — real `/v1/ping`, real auth round-trip, real 404,
real curl behaviour on both macOS and Linux. Keep it out of the default `make`. It cannot
cover schema/rows/logs without a published WASM module, and committing a prebuilt `.wasm`
to a Lua plugin repo is not worth it.

---

## Risks, ranked

1. **Large-integer corruption** (task 6). Already proven to happen with real data. If
   `lib/json.lua` is not the first thing built, every later fixture bakes in wrong values.
   The residual risk is narrow — ~35 lines of string scanning, whose only subtlety is
   skipping string literals while honouring `\` escapes. Contained by making the awkward
   cases (negatives, escaped quotes, trailing backslash, digits inside strings) explicit
   tests, and by leaving all structural parsing to `vim.json.decode`.
2. **Pure-Lua BLAKE3** (task 9). A wrong digest means a wrong identity means an empty
   database list, which presents as an auth failure and will be misdiagnosed. Mitigated by
   official test vectors as a hard gate before task 10, and by a `setup({ identity = "c200…" })`
   escape hatch that skips derivation entirely.
3. **Responses landing in the wrong buffer.** Inherent to async cancellation. Mitigated by
   the key + seq guard, explicitly tested.
4. **Token exposure.** `-H "Authorization: …"` in argv is visible in `ps` to any local user;
   hence `-K -` on stdin, `logger.redact` on every log path, and never `vim.inspect`ing a
   request table.
5. **`curl -i` framing.** Proxies or a corporate MITM could emit more than one header block.
   Mitigated by `--http1.1`, redirects disabled, skipping `1xx` preambles, and failing
   loudly with the raw status line rather than mis-parsing.
6. **The plenary removal touches eight files** (task 3). Miss one and the failure is
   confusing rather than obvious.
7. **Display width vs terminal reality.** `strdisplaywidth` for emoji depends on
   `'ambiwidth'` and the terminal's own tables. Document it; don't try to fix it. Cosmetic
   only, because all index mapping is byte-based.

## Open question, non-blocking

The TUI auto-loads a table's rows as the cursor moves over it, debounced at 250 ms.
Neovim has `<CR>`, so **explicit open is the recommended default** — more idiomatic, and it
removes a whole class of race. The debounce machinery gets built anyway and
`auto_preview = false` is exposed in config for anyone who wants the TUI feel.

## References

- `spacetimedb-tui` — the Rust TUI this mirrors. `src/api/client.rs` (identity derivation,
  schema and SQL parsers, and their tests), `src/config.rs` (server resolution + its tests),
  and its `CLAUDE.md` (distilled API gotchas). **Note it is a v9 consumer**, so its
  `parse_schema_response` maps to our fallback path, not the primary one.
- SpacetimeDB source (`~/Work/ThirdParty/SpacetimeDB`) — the authority for schema shapes:
  `crates/lib/src/db/raw_def/v10.rs` (sections), `v9.rs`, `crates/client-api/src/routes/database.rs:504`
  (the `?version=` handler), `crates/cli/src/api.rs:65` (the v10→v9 negotiation to copy).
- **Reflective decoding, the prior art for `lib/value.lua`** (task 18):
  `crates/sats/src/de/impls.rs:583` in Rust, and
  `sdks/typescript/src/lib/algebraic_type.ts:527` plus `binary_reader.ts` in TypeScript.
  Neither is a dependency — see "Why Lua, and not a Rust or TypeScript sidecar" — but both
  solve exactly the problem that task faces.
- `gleam-spacetimedb` — a Gleam client library. Useful for the BSATN/WebSocket path if
  live subscriptions are ever built; not needed for v1.
