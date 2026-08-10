-- The API surface every UI module calls: one method per SpacetimeDB endpoint,
-- `cb(err, value)` throughout.
--
-- This is the seam between the transport (`lib/http.lua`) and the parsers
-- (`lib/json.lua`, `lib/sql.lua`, `lib/schema.lua`, `lib/logs.lua`). Nothing
-- above it should ever build a URL, look at an HTTP status, or call
-- `vim.json.decode`.
--
-- Four things this file exists to get right:
--
-- 1. **`classify(status, body)` is the single error vocabulary.** A UI decides
--    what to draw from `err.kind`, never from a status code. In particular a SQL
--    error is HTTP 400 with a **plain-text** body (ROADMAP.md, verified fact 6),
--    so the body is used verbatim as the message and is never JSON-decoded —
--    decoding it would turn a perfectly good "unknown table foo" into "malformed
--    JSON response".
-- 2. **`paused` is never retried.** A paused database answers 503 on *every*
--    endpoint, so a retry loop would hammer it forever. Nothing here retries at
--    all except the schema version negotiation, and that is gated on
--    `schema.should_fallback`, which is 4xx-only — so the rule falls out of the
--    existing predicate rather than needing a check of its own.
-- 3. **`list_databases` is a fan-out with a completion counter**, not a serial
--    chain: it needs N+1 requests and doing those sequentially in Lua is
--    painfully slow. Results are written into pre-allocated slots keyed by the
--    wire index, so the output order is the server's order however the responses
--    interleave, and one failed child does not lose the other N-1.
-- 4. **Every body is decoded through `lib/json.lua`**, never `vim.json.decode`,
--    because the latter silently corrupts any integer above 2^53 (ROADMAP.md,
--    verified fact 1).
--
-- Scope: this module lives under `lib/`, so it makes no `vim.api`/`vim.fn`/
-- `vim.ui`/`vim.notify` call and holds no buffer. It takes an already-resolved
-- `SpacetimeConnection` rather than calling `config.current()`, which does touch
-- `vim.api`. `vim.json.encode` (for a reducer's argument array) is the whole of
-- its `vim.*` surface.
--
-- Callback context: every callback here runs on the main loop, because
-- `lib/http.lua` schedule-wraps them. The single exception is the `on_entry`
-- passed to `logs`, which inherits `http.stream`'s |fast-event| context and may
-- therefore touch plain Lua tables only.
--
-- `lib/http.lua` and the parsers are required **lazily, inside the functions**,
-- so a test can inject `package.loaded["spacetime.lib.http"]` before first use.

local M = {}

-- How much of an unrecognised error body to quote back. Enough to identify a
-- gateway's HTML error page; not so much that it fills a message area.
local MAX_DETAIL_BYTES = 200

---@param s string
---@return string
local function trim(s)
	return (s:match("^%s*(.-)%s*$"))
end

---Percent-encode one URL path segment.
---
---Hand-rolled rather than `vim.uri_encode`, which is a `vim.*` call this layer
---is not allowed to make, and which escapes a different set anyway. Everything
---outside the RFC 3986 unreserved set is encoded, so a database name containing
---a `/` cannot invent a path segment.
---@param value string
---@return string
local function encode_segment(value)
	if type(value) ~= "string" or value == "" then
		-- Level 3: the caller of the endpoint method, not this helper.
		error("spacetime.lib.client: path segment must be a non-empty string", 3)
	end
	return (value:gsub("[^%w%-%._~]", function(char)
		return ("%%%02X"):format(char:byte())
	end))
end

---@class SpacetimeClientError
---@field kind "paused"|"unauthorized"|"not_found"|"query"|"http"|"transport"|"decode"
---@field message string Human-readable and safe to render; never contains the token.
---@field status? integer HTTP status, when there was a response.
---@field body? string Raw response body, when there was one.

---Map a transport result onto the error vocabulary the UI understands.
---
---Pure, and the only place a status code is interpreted. First match wins, and
---the 503-plus-`paused` test comes first precisely because a paused database is
---the one 5xx that is a *state* rather than a fault.
---@param status any HTTP status code.
---@param body? string Raw response body.
---@return SpacetimeClientError|nil # `nil` for any 2xx: there is nothing wrong.
function M.classify(status, body)
	local text = type(body) == "string" and body or nil
	local detail = trim(text or "")

	if type(status) ~= "number" then
		return { kind = "http", message = "no HTTP status in response", body = text }
	end

	if status == 503 and (text or ""):lower():find("paused", 1, true) then
		return { kind = "paused", message = "database is paused", status = status, body = text }
	end
	if status == 401 then
		return {
			kind = "unauthorized",
			message = "unauthorized: the server rejected the token",
			status = status,
			body = text,
		}
	end
	if status == 404 then
		return { kind = "not_found", message = "not found", status = status, body = text }
	end
	if status == 400 then
		-- The body *is* the message. SQL errors arrive here as plain text, so
		-- decoding would replace a useful diagnostic with a parser complaint.
		return {
			kind = "query",
			message = detail ~= "" and detail or "bad request",
			status = status,
			body = text,
		}
	end
	if status >= 200 and status < 300 then
		return nil
	end

	local message = ("HTTP %d"):format(status)
	if detail ~= "" then
		message = message .. ": " .. detail:sub(1, MAX_DETAIL_BYTES)
	end
	return { kind = "http", message = message, status = status, body = text }
end

--------------------------------------------------------------------------------
-- Body transforms
--------------------------------------------------------------------------------

---Decode a response body, big integers intact.
---
---Returns `value, nil` or `nil, message`, which is the shape every transform
---below uses so `fetch` needs one branch rather than a `pcall` per endpoint.
---@param body string
---@return any
---@return string|nil
local function decode_body(body)
	local json = require("spacetime.lib.json")
	local ok, value = pcall(json.decode, body)
	if not ok then
		-- Strip the "file:line: " a raise inside vim.json.decode carries.
		return nil, "malformed JSON response: " .. (tostring(value):gsub("^.-:%d+: ", ""))
	end
	return value, nil
end

---A body that is allowed to be empty: a reducer call answers `200` with nothing
---at all, and "no content" is not a decode failure.
---@param body string
---@return any
---@return string|nil
local function decode_optional(body)
	if trim(body) == "" then
		return nil, nil
	end
	return decode_body(body)
end

---`{"names": [...]}` -> the array of strings.
---
---A response with no `names` key yields `{}` rather than an error: an unnamed
---database is a database with no names, not a broken response.
---@param body string
---@return string[]|nil
---@return string|nil
local function decode_names(body)
	local value, err = decode_body(body)
	if err then
		return nil, err
	end
	local names = {}
	if type(value) == "table" and type(value.names) == "table" then
		for _, name in ipairs(value.names) do
			if type(name) == "string" then
				names[#names + 1] = name
			end
		end
	end
	return names, nil
end

--------------------------------------------------------------------------------
-- The client
--------------------------------------------------------------------------------

---@class SpacetimeClient
---@field conn SpacetimeConnection The resolved connection every request is built from.
local Client = {}
Client.__index = Client

---Build a client for an already-resolved connection.
---@param conn SpacetimeConnection From `spacetime.config.resolve` / `config.current`.
---@return SpacetimeClient
function M.new(conn)
	if type(conn) ~= "table" or type(conn.url) ~= "string" or conn.url == "" then
		error("spacetime.lib.client: new requires a resolved connection with a url", 2)
	end
	return setmetatable({ conn = conn }, Client) --[[@as SpacetimeClient]]
end

---Base URL plus an already-encoded path.
---@param self SpacetimeClient
---@param path string Must start with `/`.
---@return string
local function url(self, path)
	return self.conn.url .. path
end

---Run one buffered request and hand the caller a decoded value or an error.
---
---Exactly one of `err` and `value` is non-nil here — `list_databases` is the one
---deliberate exception in this module, and it does not go through this helper.
---@param req SpacetimeHttpRequest
---@param cb fun(err: SpacetimeClientError|nil, value: any)
---@param transform? fun(body: string): any, string|nil Default: decode with `lib/json`.
---@return SpacetimeHttpHandle
local function fetch(req, cb, transform)
	local http = require("spacetime.lib.http")
	return http.request(req, function(err, res)
		if err then
			cb({ kind = "transport", message = err }, nil)
			return
		end
		if not res then
			cb({ kind = "transport", message = "no response from server" }, nil)
			return
		end

		local classified = M.classify(res.status, res.body)
		if classified then
			cb(classified, nil)
			return
		end

		local value, message = (transform or decode_body)(res.body)
		if message then
			cb({ kind = "decode", message = message, status = res.status, body = res.body }, nil)
			return
		end
		cb(nil, value)
	end)
end

---`GET /v1/ping` — is the server there and does it like our token?
---
---The body is not decoded: ping answers with an empty body, and `true` is the
---whole of the useful information.
---@param cb fun(err: SpacetimeClientError|nil, ok: boolean|nil)
---@return SpacetimeHttpHandle
function Client:ping(cb)
	return fetch({ url = url(self, "/v1/ping"), token = self.conn.token }, cb, function()
		return true, nil
	end)
end

---`GET /v1/database/{db}/names` — the names a database answers to.
---@param db string Database name or identity.
---@param cb fun(err: SpacetimeClientError|nil, names: string[]|nil)
---@return SpacetimeHttpHandle
function Client:database_names(db, cb)
	local path = "/v1/database/" .. encode_segment(db) .. "/names"
	return fetch({ url = url(self, path), token = self.conn.token }, cb, decode_names)
end

---`POST /v1/database/{db}/sql` — run one SQL statement.
---
---`Content-Type: text/plain` is **mandatory**, not decorative: curl's
---`--data-binary` otherwise defaults the type to `application/x-www-form-urlencoded`
---and the server rejects the statement (see `lib/http.lua`'s header comment).
---@param db string
---@param query string Raw SQL. Build it with `lib/sql.select_all`, never by concatenation.
---@param cb fun(err: SpacetimeClientError|nil, result: SpacetimeSqlResult|nil)
---@return SpacetimeHttpHandle
function Client:sql(db, query, cb)
	if type(query) ~= "string" then
		error("spacetime.lib.client: sql requires a query string", 2)
	end
	local path = "/v1/database/" .. encode_segment(db) .. "/sql"
	local req = {
		url = url(self, path),
		method = "POST",
		token = self.conn.token,
		body = query,
		headers = { ["Content-Type"] = "text/plain" },
	}
	return fetch(req, cb, function(body)
		return require("spacetime.lib.sql").parse(body)
	end)
end

---`POST /v1/database/{db}/call/{reducer}` — call a reducer.
---
---The body is a JSON **array** of arguments. An empty table encodes as `{}` in
---`vim.json.encode`, which the server would reject, so the no-argument case is
---spelled out as `[]` rather than encoded.
---@param db string
---@param reducer string Canonical reducer name — the SQL spelling, not the source one.
---@param args? any[]|string Argument array, or a pre-encoded JSON array.
---@param cb fun(err: SpacetimeClientError|nil, value: any)
---@return SpacetimeHttpHandle
function Client:call(db, reducer, args, cb)
	local body
	if type(args) == "string" then
		body = args
	elseif args == nil or next(args) == nil then
		body = "[]"
	else
		body = vim.json.encode(args)
	end

	local path = "/v1/database/" .. encode_segment(db) .. "/call/" .. encode_segment(reducer)
	local req = {
		url = url(self, path),
		method = "POST",
		token = self.conn.token,
		body = body,
		headers = { ["Content-Type"] = "application/json" },
	}
	return fetch(req, cb, decode_optional)
end

---`GET /v1/database/{db}/schema?version=…` — the module definition, normalised.
---
---`?version=` is required and accepts only `10` or `9`. With no `version` given
---this walks `schema.VERSIONS` most-capable-first and falls back on a 4xx, which
---is exactly the CLI's own negotiation. Because `schema.should_fallback` is
---4xx-only, a paused database (503) produces **one** request and one `paused`
---error — the "never retry a pause" rule needs no code of its own.
---@param db string
---@param version? integer `10` or `9`. Omit to negotiate.
---@param cb fun(err: SpacetimeClientError|nil, model: SpacetimeSchema|nil)
---@return SpacetimeHttpHandle
function Client:schema(db, version, cb)
	local http = require("spacetime.lib.http")
	local schema_lib = require("spacetime.lib.schema")

	local segment = encode_segment(db)
	local cancelled = false
	local finished = false
	local handles = {} ---@type SpacetimeHttpHandle[]

	-- Tracked rather than held in a single `current`, so a `kill()` arriving
	-- between the v10 failure and the v9 request cannot leave a live handle
	-- behind — and so a synchronously-completing stub cannot reorder the two.
	---@param handle SpacetimeHttpHandle
	local function track(handle)
		handles[#handles + 1] = handle
		if cancelled then
			handle.kill()
		end
	end

	---@param err SpacetimeClientError|nil
	---@param model SpacetimeSchema|nil
	local function finish(err, model)
		if cancelled or finished then
			return
		end
		finished = true
		cb(err, model)
	end

	local attempt ---@type fun(index: integer|nil, fixed: integer|nil)

	---@param index integer|nil Position in `schema.VERSIONS`; `nil` when pinned.
	---@param fixed integer|nil The pinned version, when the caller named one.
	attempt = function(index, fixed)
		local wanted = fixed or schema_lib.VERSIONS[index or 1]
		local path = ("/v1/database/%s/schema?version=%d"):format(segment, wanted)

		track(http.request({ url = url(self, path), token = self.conn.token }, function(err, res)
			if cancelled or finished then
				return
			end
			if err then
				finish({ kind = "transport", message = err }, nil)
				return
			end
			if not res then
				finish({ kind = "transport", message = "no response from server" }, nil)
				return
			end

			local classified = M.classify(res.status, res.body)
			if classified then
				if index and schema_lib.should_fallback(res.status) and schema_lib.VERSIONS[index + 1] then
					attempt(index + 1, nil)
					return
				end
				finish(classified, nil)
				return
			end

			local value, message = decode_body(res.body)
			if message then
				finish({ kind = "decode", message = message, status = res.status, body = res.body }, nil)
				return
			end

			-- `schema.parse` is the one part of that module that raises: an
			-- unrecognised payload is not something the UI can partly render.
			local ok, model = pcall(schema_lib.parse, value)
			if not ok then
				local detail = (tostring(model):gsub("^.-:%d+: ", ""))
				finish({ kind = "decode", message = detail, status = res.status, body = res.body }, nil)
				return
			end
			finish(nil, model --[[@as SpacetimeSchema]])
		end))
	end

	if type(version) == "number" then
		attempt(nil, math.floor(version))
	else
		attempt(1, nil)
	end

	return {
		kill = function()
			if cancelled then
				return
			end
			cancelled = true
			for _, handle in ipairs(handles) do
				handle.kill()
			end
		end,
	}
end

---One row of `list_databases`.
---@class SpacetimeDatabaseEntry
---@field identity string Hex identity, as it appears in a URL path.
---@field names string[] From `/names`; empty when that request failed.
---@field name string Display name: `names[1]`, falling back to `identity`.
---@field error? string Set only on the entries whose `/names` request failed.

---The hex identity of one element of `{"identities": [...]}`.
---
---The element shape was never pinned down by a captured fixture, so all three
---plausible spellings are accepted and anything else is skipped rather than
---turned into a bad URL. A leading `0x` is stripped: it belongs to the display
---form, not to the path.
---@param entry any
---@return string|nil
local function identity_hex(entry)
	local hex
	if type(entry) == "string" then
		hex = entry
	elseif type(entry) == "table" then
		if type(entry.__identity__) == "string" then
			hex = entry.__identity__
		elseif type(entry.identity) == "string" then
			hex = entry.identity
		end
	end
	if hex == nil or hex == "" then
		return nil
	end
	local stripped = (hex:gsub("^0[xX]", ""))
	return stripped ~= "" and stripped or nil
end

---`GET /v1/identity/{identity}/databases`, then one `/names` per database.
---
---**Both callback arguments may be non-nil.** This is the module's one
---deliberate exception to "exactly one of err/value": when some of the `/names`
---requests fail, throwing away the successful ones would be worse than reporting
---partial data alongside the first error. Entries whose `/names` failed still
---appear, named after their identity and carrying `error`.
---@param identity string Hex account identity, e.g. from `lib/identity.resolve`.
---@param cb fun(err: SpacetimeClientError|nil, databases: SpacetimeDatabaseEntry[]|nil)
---@return SpacetimeHttpHandle
function Client:list_databases(identity, cb)
	local cancelled = false
	local finished = false
	local handles = {} ---@type SpacetimeHttpHandle[]

	---@param handle SpacetimeHttpHandle
	local function track(handle)
		handles[#handles + 1] = handle
		if cancelled then
			handle.kill()
		end
	end

	---@param err SpacetimeClientError|nil
	---@param databases SpacetimeDatabaseEntry[]|nil
	local function finish(err, databases)
		if cancelled or finished then
			return
		end
		finished = true
		cb(err, databases)
	end

	local path = "/v1/identity/" .. encode_segment(identity) .. "/databases"
	track(fetch({ url = url(self, path), token = self.conn.token }, function(err, value)
		if cancelled or finished then
			return
		end
		if err then
			finish(err, nil)
			return
		end

		local hexes = {} ---@type string[]
		if type(value) == "table" and type(value.identities) == "table" then
			for _, entry in ipairs(value.identities) do
				local hex = identity_hex(entry)
				if hex then
					hexes[#hexes + 1] = hex
				end
			end
		end

		local total = #hexes
		if total == 0 then
			-- Nothing to count down from: a counter started at zero would wait
			-- for a completion that never comes.
			finish(nil, {})
			return
		end

		local results = {} ---@type SpacetimeDatabaseEntry[]
		local remaining = total
		local first_err = nil ---@type SpacetimeClientError|nil

		-- All N are fired in one pass. `results[i]` is keyed by the *wire* index,
		-- so the output order is the server's order regardless of the order the
		-- responses come back in, and `ui/tree.lua` keeps its "the caller owns
		-- the display order" contract.
		for i, hex in ipairs(hexes) do
			results[i] = { identity = hex, names = {}, name = hex }
			track(self:database_names(hex, function(child_err, names)
				if cancelled or finished then
					return
				end
				local entry = results[i]
				if child_err then
					first_err = first_err or child_err
					entry.error = child_err.message
				else
					entry.names = names or {}
					entry.name = entry.names[1] or hex
				end
				remaining = remaining - 1
				if remaining == 0 then
					finish(first_err, results)
				end
			end))
		end
	end))

	return {
		kill = function()
			if cancelled then
				return
			end
			cancelled = true
			for _, handle in ipairs(handles) do
				handle.kill()
			end
		end,
	}
end

---`GET /v1/database/{db}/logs` — stream log entries, one callback per entry.
---
---Always streamed, `follow` or not: a non-follow response is NDJSON too, so one
---code path covers both. Nothing is accumulated — the caller owns the ring
---buffer — and a blank or malformed line is dropped rather than being fatal,
---because a follow delivers half-written lines by construction.
---
---The completion mapping is the subtle part. `http.stream` reports a *cancelled*
---stream as `(nil, nil)` and a finished one as `(nil, response)`, so a clean stop
---is `cb(nil, nil)` while a 503 that never emitted a line still classifies as
---`paused` — which is what keeps a paused database detectable in follow mode.
---@param db string
---@param num_lines? integer Backlog to fetch first. Default 0.
---@param follow? boolean Keep the connection open. Default `false`.
---@param on_entry fun(entry: spacetime.LogEntry) Fast-event context. Plain tables only.
---@param cb fun(err: SpacetimeClientError|nil, value: nil) Fires exactly once.
---@return SpacetimeHttpHandle
function Client:logs(db, num_lines, follow, on_entry, cb)
	if type(on_entry) ~= "function" then
		error("spacetime.lib.client: logs needs an on_entry callback", 2)
	end

	local http = require("spacetime.lib.http")
	local logs_lib = require("spacetime.lib.logs")

	local count = math.floor(tonumber(num_lines) or 0)
	if count < 0 then
		count = 0
	end

	local path = ("/v1/database/%s/logs?num_lines=%d&follow=%s"):format(
		encode_segment(db),
		count,
		follow and "true" or "false"
	)

	return http.stream({ url = url(self, path), token = self.conn.token, stream = true }, function(line)
		local entry = logs_lib.parse_line(line)
		if entry then
			on_entry(entry)
		end
	end, function(err, res)
		if err then
			cb({ kind = "transport", message = err }, nil)
			return
		end
		if res == nil then
			-- Cancelled. Stopping a follow is not a failure.
			cb(nil, nil)
			return
		end
		cb(M.classify(res.status, res.body), nil)
	end)
end

return M
