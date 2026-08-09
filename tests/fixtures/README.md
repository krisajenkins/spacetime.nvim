# Test fixtures

Real responses captured from SpacetimeDB 2.8.0 on maincloud, from the `spacegym`
module. They exist so the test suite runs offline, with no token and no network —
every task in `ROADMAP.md` is executable against these alone.

| File | Endpoint | Pins down |
|---|---|---|
| `schema_v10.json` | `GET /v1/database/spacegym/schema?version=10` | the sectioned v10 shape |
| `schema_v9.json` | `GET /v1/database/spacegym/schema?version=9` | the flat v9 fallback shape |
| `sql_rows.json` | `POST /v1/database/spacegym/sql` | `£` and `🎟` in real rows; an Option as `[0,"£"]` |
| `sql_bigint.json` | `POST /v1/database/spacegym/sql` | U256 as a hex *string* beside U128 as a bare *number* |
| `logs.ndjson` | `GET /v1/database/spacegym/logs?num_lines=40` | 11 real NDJSON log lines |

`schema_v10.json` and `schema_v9.json` are the **same module** in both shapes, so the
v10→v9 fallback can be tested for equivalence rather than merely for parsing.

## Why these particular ones

- `sql_bigint.json` is the counter-example that justifies `lib/json.lua`. Its U128
  `connection_id` arrives as a bare JSON number with 39 digits; `vim.json.decode`
  silently returns `9223372036854775808` for it. The U256 `identity` in the same row
  arrives as a hex string instead — the wire format is not consistent per width, and
  both spellings have to survive.
- `sql_rows.json` carries `£` (1 display column, 2 bytes) and `🎟` (2 display columns,
  4 bytes). Column layout that uses `#s` gets both wrong, which is why `ui/grid.lua`
  measures with `vim.fn.strdisplaywidth`.
- `logs.ndjson` is all `Info` level. Tests for level ordering and filtering should add
  their own synthetic lines rather than expecting variety here.

## Re-capturing

A manual, credentialed step — deliberately not part of any task. The token comes from
`spacetimedb_token` in `~/.config/spacetime/cli.toml` and is passed to curl on **stdin**,
never in argv, because argv is visible in `ps` to any local user:

```bash
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > curlrc && chmod 600 curlrc
curl -sS -K curlrc \
  'https://maincloud.spacetimedb.com/v1/database/spacegym/schema?version=10'
rm curlrc
```

Before committing anything captured this way, scan it for tokens, JWTs and e-mail
addresses. The only identifier these files contain is the account identity
`c2005efe…`, which is a public value and is already recorded in `ROADMAP.md`.
