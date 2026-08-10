-- Tests for the endpoint client.
--
-- No child Neovim: everything below `lib/http.lua` is plain Lua, and the
-- transport is replaced wholesale by injecting `package.loaded["spacetime.lib.http"]`
-- before the client's lazy `require` runs. **The stub is always the transport,
-- never the client** — the whole point is that `classify`, the fan-out counter
-- and the schema negotiation are genuinely exercised rather than mocked away.
--
-- The stub is synchronous by default, which is stricter than reality (the real
-- `http.request` schedules its callback), so anything that depends on a handle
-- being assigned before its callback fires shows up here as a failure rather
-- than as a race in production. Where completion *order* is the point — the
-- fan-out — the stub defers instead, and the test fires the pending callbacks by
-- hand.
local client = require("spacetime.lib.client")
local read = require("tests.helpers.fixtures").read
local expect = MiniTest.expect

local CONN = {
	host = "localhost",
	port = 3000,
	tls = false,
	url = "http://localhost:3000",
	database = "quickstart",
	token = "s3cret-token",
}

-- Recorded per case by the stub below.
local requests ---@type table[]
local killed ---@type string[]
local saved_http

---Install a fake transport.
---@param handlers table `request` and/or `stream`, called after the request is recorded.
local function install(handlers)
	package.loaded["spacetime.lib.http"] = {
		request = function(req, on_done)
			requests[#requests + 1] = req
			local handle = {
				kill = function()
					killed[#killed + 1] = req.url
				end,
			}
			if handlers.request then
				handlers.request(req, on_done)
			end
			return handle
		end,
		stream = function(req, on_line, on_done)
			requests[#requests + 1] = req
			local handle = {
				kill = function()
					killed[#killed + 1] = req.url
				end,
			}
			if handlers.stream then
				handlers.stream(req, on_line, on_done)
			end
			return handle
		end,
	}
end

---A transport that answers every request with the same response.
---@param status integer
---@param body string
local function responds(status, body)
	install({
		request = function(_, on_done)
			on_done(nil, { status = status, headers = {}, body = body })
		end,
	})
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			saved_http = package.loaded["spacetime.lib.http"]
			requests, killed = {}, {}
		end,
		post_case = function()
			package.loaded["spacetime.lib.http"] = saved_http
		end,
	},
})

--------------------------------------------------------------------------------
-- classify
--------------------------------------------------------------------------------

T["classify maps 503 with a paused body to paused"] = function()
	local err = client.classify(503, "database is paused")
	expect.equality(err.kind, "paused")
	expect.equality(err.message, "database is paused")
	expect.equality(err.status, 503)
end

T["classify maps a 503 that is not about pausing to http"] = function()
	local err = client.classify(503, "upstream connect error")
	expect.equality(err.kind, "http")
	expect.equality(err.status, 503)
	expect.equality(err.message:find("upstream connect error", 1, true) ~= nil, true)
end

T["classify maps 401 to unauthorized and 404 to not_found"] = function()
	expect.equality(client.classify(401, "").kind, "unauthorized")
	expect.equality(client.classify(404, "").kind, "not_found")
end

T["classify uses a 400 body verbatim as the query message"] = function()
	local err = client.classify(400, "unknown table foo\n")
	expect.equality(err.kind, "query")
	expect.equality(err.message, "unknown table foo")
end

T["classify falls back to bad request for an empty 400"] = function()
	local err = client.classify(400, "")
	expect.equality(err.kind, "query")
	expect.equality(err.message, "bad request")
end

T["classify never decodes a 400 body"] = function()
	local err
	expect.no_error(function()
		err = client.classify(400, "{not json at all")
	end)
	expect.equality(err.kind, "query")
	expect.equality(err.message, "{not json at all")
end

T["classify returns nil for a 2xx"] = function()
	expect.equality(client.classify(200, "{}"), nil)
	expect.equality(client.classify(204, ""), nil)
end

T["classify reports an unmapped status as http, carrying the status"] = function()
	local err = client.classify(500, "boom")
	expect.equality(err.kind, "http")
	expect.equality(err.status, 500)
	expect.equality(err.message, "HTTP 500: boom")
end

T["classify truncates a long error body"] = function()
	local err = client.classify(502, string.rep("x", 5000))
	expect.equality(#err.message <= 220, true)
end

--------------------------------------------------------------------------------
-- ping, token hygiene
--------------------------------------------------------------------------------

T["ping succeeds on an empty 200 without decoding"] = function()
	responds(200, "")
	local seen = {}
	client.new(CONN):ping(function(err, ok)
		seen = { err = err, ok = ok }
	end)
	expect.equality(seen.err, nil)
	expect.equality(seen.ok, true)
	expect.equality(requests[1].url, "http://localhost:3000/v1/ping")
end

T["the token travels as req.token, never as an Authorization header"] = function()
	responds(200, "")
	client.new(CONN):ping(function() end)

	expect.equality(requests[1].token, "s3cret-token")
	expect.equality(requests[1].headers == nil or requests[1].headers.Authorization == nil, true)
end

T["a transport failure is reported as kind transport"] = function()
	install({
		request = function(_, on_done)
			on_done("connection refused", nil)
		end,
	})
	local seen
	client.new(CONN):ping(function(err)
		seen = err
	end)
	expect.equality(seen.kind, "transport")
	expect.equality(seen.message, "connection refused")
end

--------------------------------------------------------------------------------
-- sql
--------------------------------------------------------------------------------

T["sql posts the query as text/plain to the sql endpoint"] = function()
	responds(200, "[]")
	client.new(CONN):sql("quickstart", "SELECT * FROM x LIMIT 1", function() end)

	local req = requests[1]
	expect.equality(req.method, "POST")
	expect.equality(req.body, "SELECT * FROM x LIMIT 1")
	expect.equality(req.headers["Content-Type"], "text/plain")
	expect.equality(req.url, "http://localhost:3000/v1/database/quickstart/sql")
end

T["a sql error is a 400 with its plain-text body as the message"] = function()
	responds(400, "unknown table `nope`")
	local seen
	client.new(CONN):sql("quickstart", "SELECT * FROM nope", function(err)
		seen = err
	end)
	expect.equality(seen.kind, "query")
	expect.equality(seen.message, "unknown table `nope`")
end

T["a sql body is decoded through lib/json, so big integers survive"] = function()
	responds(200, read("sql_bigint.json"))
	local result
	client.new(CONN):sql("quickstart", "SELECT * FROM st_client", function(err, value)
		expect.equality(err, nil)
		result = value
	end)

	-- The U128 stays an exact decimal *string*; `vim.json.decode` would have
	-- turned it into 9223372036854775808.
	expect.equality(result.rows[1][2], "118584542101933595460429904643539362103")
	-- And the U256 identity beside it is a hex string on the wire already.
	expect.equality(result.rows[1][1], "0xc2005efe02e92547ddd4bd106e84a281ead78a30fa26f42e619d70b20917c3dd")
end

T["a paused database is reported as paused on the sql endpoint too"] = function()
	responds(503, "database is paused")
	local seen
	client.new(CONN):sql("quickstart", "SELECT 1", function(err)
		seen = err
	end)
	expect.equality(seen.kind, "paused")
	expect.equality(#requests, 1)
end

--------------------------------------------------------------------------------
-- database_names, call
--------------------------------------------------------------------------------

T["database_names returns the names array"] = function()
	responds(200, '{"names":["quickstart","qs"]}')
	local seen
	client.new(CONN):database_names("quickstart", function(_, names)
		seen = names
	end)
	expect.equality(seen, { "quickstart", "qs" })
	expect.equality(requests[1].url, "http://localhost:3000/v1/database/quickstart/names")
end

T["database_names yields an empty list when the key is absent"] = function()
	responds(200, "{}")
	local seen
	client.new(CONN):database_names("quickstart", function(_, names)
		seen = names
	end)
	expect.equality(seen, {})
end

T["a malformed body is reported as kind decode, not raised"] = function()
	responds(200, "{ not json")
	local seen
	expect.no_error(function()
		client.new(CONN):database_names("quickstart", function(err)
			seen = err
		end)
	end)
	expect.equality(seen.kind, "decode")
	expect.equality(seen.status, 200)
end

T["a path segment is percent-encoded"] = function()
	responds(200, "{}")
	client.new(CONN):database_names("a/b c", function() end)
	expect.equality(requests[1].url, "http://localhost:3000/v1/database/a%2Fb%20c/names")
end

T["call posts a JSON array and tolerates an empty response body"] = function()
	responds(200, "")
	local seen = { called = false }
	client.new(CONN):call("quickstart", "add", { 1, "two" }, function(err, value)
		seen = { called = true, err = err, value = value }
	end)

	expect.equality(seen.called, true)
	expect.equality(seen.err, nil)
	expect.equality(seen.value, nil)
	expect.equality(requests[1].method, "POST")
	expect.equality(requests[1].body, '[1,"two"]')
	expect.equality(requests[1].url, "http://localhost:3000/v1/database/quickstart/call/add")
end

T["call with no arguments sends an empty JSON array, not an object"] = function()
	responds(200, "")
	client.new(CONN):call("quickstart", "tick", nil, function() end)
	expect.equality(requests[1].body, "[]")
end

--------------------------------------------------------------------------------
-- list_databases fan-out
--------------------------------------------------------------------------------

-- The `/databases` list every fan-out case below starts from.
local IDENTITIES = '{"identities":["aa11","bb22","cc33"]}'

---A transport that answers the identity list at once and *defers* every
---`/names` request, so the test decides the completion order.
---@param names table<string,string> identity -> response body
---@param statuses? table<string,integer> identity -> status, default 200
---@return fun(): table[] pending Deferred children, in the order they were fired.
local function fan_out_stub(names, statuses)
	local pending = {}
	install({
		request = function(req, on_done)
			local hex = req.url:match("/v1/database/([^/]+)/names$")
			if hex then
				pending[#pending + 1] = {
					hex = hex,
					fire = function()
						on_done(nil, {
							status = (statuses and statuses[hex]) or 200,
							headers = {},
							body = names[hex] or "{}",
						})
					end,
				}
				return
			end
			on_done(nil, { status = 200, headers = {}, body = IDENTITIES })
		end,
	})
	return function()
		return pending
	end
end

T["the fan-out fires every child before any of them completes"] = function()
	local pending = fan_out_stub({})
	client.new(CONN):list_databases("c200ff", function() end)

	-- One list request plus one per identity, all issued already.
	expect.equality(#requests, 4)
	expect.equality(#pending(), 3)
	expect.equality(requests[1].url, "http://localhost:3000/v1/identity/c200ff/databases")
end

T["the fan-out survives out-of-order completion and calls back once"] = function()
	local pending = fan_out_stub({
		aa11 = '{"names":["alpha"]}',
		bb22 = '{"names":["beta"]}',
		cc33 = '{"names":["gamma"]}',
	})

	local calls, seen = 0, nil
	client.new(CONN):list_databases("c200ff", function(err, databases)
		calls = calls + 1
		seen = { err = err, databases = databases }
	end)

	-- Reverse order, with the first child finishing last.
	local children = pending()
	children[3].fire()
	children[2].fire()
	expect.equality(calls, 0)
	children[1].fire()

	expect.equality(calls, 1)
	expect.equality(seen.err, nil)
	local order = {}
	for i, entry in ipairs(seen.databases) do
		order[i] = { entry.identity, entry.name }
	end
	-- Output order is the wire order, not the completion order.
	expect.equality(order, { { "aa11", "alpha" }, { "bb22", "beta" }, { "cc33", "gamma" } })
end

T["a failed child costs its names, not the whole list"] = function()
	local pending = fan_out_stub({
		aa11 = '{"names":["alpha"]}',
		cc33 = '{"names":["gamma"]}',
	}, { bb22 = 404 })

	local seen
	client.new(CONN):list_databases("c200ff", function(err, databases)
		seen = { err = err, databases = databases }
	end)
	for _, child in ipairs(pending()) do
		child.fire()
	end

	-- Both arguments are non-nil: partial data *and* the error.
	expect.equality(seen.err.kind, "not_found")
	expect.equality(#seen.databases, 3)
	expect.equality(seen.databases[1].name, "alpha")
	expect.equality(seen.databases[3].name, "gamma")

	local failed = seen.databases[2]
	expect.equality(failed.identity, "bb22")
	expect.equality(failed.name, "bb22")
	expect.equality(failed.names, {})
	expect.equality(failed.error, "not found")
end

T["an empty identities list calls back at once with no child requests"] = function()
	install({
		request = function(_, on_done)
			on_done(nil, { status = 200, headers = {}, body = '{"identities":[]}' })
		end,
	})

	local calls, seen = 0, nil
	client.new(CONN):list_databases("c200ff", function(err, databases)
		calls = calls + 1
		seen = { err = err, databases = databases }
	end)

	expect.equality(calls, 1)
	expect.equality(seen.err, nil)
	expect.equality(seen.databases, {})
	expect.equality(#requests, 1)
end

T["identity entries are accepted as objects and stripped of 0x"] = function()
	install({
		request = function(req, on_done)
			if req.url:find("/databases", 1, true) then
				on_done(nil, {
					status = 200,
					headers = {},
					body = '{"identities":[{"__identity__":"0xAA11"},{"identity":"bb22"},42]}',
				})
			else
				on_done(nil, { status = 200, headers = {}, body = '{"names":["n"]}' })
			end
		end,
	})

	local seen
	client.new(CONN):list_databases("c200ff", function(_, databases)
		seen = databases
	end)

	-- The junk element is skipped rather than turned into a bad URL.
	expect.equality(#seen, 2)
	expect.equality(seen[1].identity, "AA11")
	expect.equality(seen[2].identity, "bb22")
end

T["a failed identity list is reported with no databases"] = function()
	install({
		request = function(_, on_done)
			on_done(nil, { status = 401, headers = {}, body = "" })
		end,
	})

	local seen
	client.new(CONN):list_databases("c200ff", function(err, databases)
		seen = { err = err, databases = databases }
	end)

	expect.equality(seen.err.kind, "unauthorized")
	expect.equality(seen.databases, nil)
	expect.equality(#requests, 1)
end

T["killing the fan-out kills every child and suppresses the callback"] = function()
	local pending = fan_out_stub({ aa11 = '{"names":["alpha"]}' })

	local calls = 0
	local handle = client.new(CONN):list_databases("c200ff", function()
		calls = calls + 1
	end)
	handle.kill()

	-- The list request plus all three children.
	expect.equality(#killed, 4)
	for _, child in ipairs(pending()) do
		child.fire()
	end
	expect.equality(calls, 0)
end

--------------------------------------------------------------------------------
-- schema negotiation
--------------------------------------------------------------------------------

---A transport answering `?version=N` from `bodies[N]`, or `fallbacks[N]` when
---that version is not served.
---@param bodies table<integer,string>
---@param failures? table<integer,table> version -> `{status, body}`
local function schema_stub(bodies, failures)
	install({
		request = function(req, on_done)
			local version = tonumber(req.url:match("version=(%d+)"))
			local failure = failures and failures[version]
			if failure then
				on_done(nil, { status = failure.status, headers = {}, body = failure.body or "" })
				return
			end
			on_done(nil, { status = 200, headers = {}, body = bodies[version] or "{}" })
		end,
	})
end

T["a served v10 schema is fetched in exactly one request"] = function()
	schema_stub({ [10] = read("schema_v10.json") })

	local seen
	client.new(CONN):schema("quickstart", nil, function(err, model)
		expect.equality(err, nil)
		seen = model
	end)

	expect.equality(#requests, 1)
	expect.equality(requests[1].url, "http://localhost:3000/v1/database/quickstart/schema?version=10")
	expect.equality(seen.version, 10)
end

T["a 400 on v10 falls back to v9"] = function()
	schema_stub({ [9] = read("schema_v9.json") }, { [10] = { status = 400, body = "unsupported version" } })

	local seen
	client.new(CONN):schema("quickstart", nil, function(err, model)
		expect.equality(err, nil)
		seen = model
	end)

	expect.equality(#requests, 2)
	expect.equality(requests[2].url:match("version=(%d+)"), "9")
	expect.equality(seen.version, 9)
end

T["a paused database is never retried at a lower version"] = function()
	schema_stub({}, { [10] = { status = 503, body = "database is paused" } })

	local seen
	client.new(CONN):schema("quickstart", nil, function(err)
		seen = err
	end)

	expect.equality(#requests, 1)
	expect.equality(seen.kind, "paused")
end

T["a 5xx on v10 is reported rather than retried"] = function()
	schema_stub({}, { [10] = { status = 500, body = "boom" } })

	local seen
	client.new(CONN):schema("quickstart", nil, function(err)
		seen = err
	end)

	expect.equality(#requests, 1)
	expect.equality(seen.kind, "http")
end

T["an explicit version does exactly one request and never falls back"] = function()
	schema_stub({}, { [9] = { status = 400, body = "nope" } })

	local seen
	client.new(CONN):schema("quickstart", 9, function(err)
		seen = err
	end)

	expect.equality(#requests, 1)
	expect.equality(requests[1].url:match("version=(%d+)"), "9")
	expect.equality(seen.kind, "query")
end

T["an unrecognised schema payload is reported as kind decode"] = function()
	schema_stub({ [10] = '{"nothing":true}' })

	local seen
	expect.no_error(function()
		client.new(CONN):schema("quickstart", 10, function(err)
			seen = err
		end)
	end)
	expect.equality(seen.kind, "decode")
	expect.equality(seen.message:find("unrecognised schema payload", 1, true) ~= nil, true)
end

T["killing a schema request suppresses the callback"] = function()
	local fire
	install({
		request = function(_, on_done)
			fire = function()
				on_done(nil, { status = 200, headers = {}, body = read("schema_v10.json") })
			end
		end,
	})

	local calls = 0
	local handle = client.new(CONN):schema("quickstart", nil, function()
		calls = calls + 1
	end)
	handle.kill()
	fire()

	expect.equality(#killed, 1)
	expect.equality(calls, 0)
end

--------------------------------------------------------------------------------
-- logs
--------------------------------------------------------------------------------

---A streaming transport that emits `lines` and then completes.
---@param lines string[]
---@param err string|nil
---@param res table|nil
local function log_stub(lines, err, res)
	install({
		stream = function(_, on_line, on_done)
			for _, line in ipairs(lines) do
				on_line(line)
			end
			on_done(err, res)
		end,
	})
end

T["logs parses each line and drops the ones that are not log records"] = function()
	log_stub({
		'{"level":"Info","ts":"1780864718837447","message":"one"}',
		"half-written {",
		'{"level":"Error","message":"two"}',
	}, nil, { status = 200, headers = {}, body = "" })

	local entries, done = {}, { called = false }
	client.new(CONN):logs("quickstart", 25, false, function(entry)
		entries[#entries + 1] = entry
	end, function(err)
		done = { called = true, err = err }
	end)

	expect.equality(#entries, 2)
	expect.equality(entries[1].message, "one")
	expect.equality(entries[1].ts, 1780864718837447)
	expect.equality(entries[2].level, "Error")
	expect.equality(done, { called = true, err = nil })
	expect.equality(requests[1].url, "http://localhost:3000/v1/database/quickstart/logs?num_lines=25&follow=false")
	expect.equality(requests[1].stream, true)
end

T["follow is spelled out in the query string"] = function()
	log_stub({}, nil, { status = 200, headers = {}, body = "" })
	client.new(CONN):logs("quickstart", 0, true, function() end, function() end)
	expect.equality(requests[1].url:match("follow=(%a+)"), "true")
end

T["a cancelled stream completes with neither an error nor a value"] = function()
	log_stub({}, nil, nil)

	local seen = { called = false }
	client.new(CONN):logs("quickstart", 0, true, function() end, function(err, value)
		seen = { called = true, err = err, value = value }
	end)

	expect.equality(seen, { called = true, err = nil, value = nil })
end

T["a paused database is detectable while following"] = function()
	log_stub({}, nil, { status = 503, headers = {}, body = "database is paused" })

	local seen
	client.new(CONN):logs("quickstart", 0, true, function() end, function(err)
		seen = err
	end)

	expect.equality(seen.kind, "paused")
end

T["a stream transport failure is reported as kind transport"] = function()
	log_stub({}, "timed out", nil)

	local seen
	client.new(CONN):logs("quickstart", 0, true, function() end, function(err)
		seen = err
	end)

	expect.equality(seen.kind, "transport")
	expect.equality(seen.message, "timed out")
end

--------------------------------------------------------------------------------

T["new rejects a connection with no url"] = function()
	expect.error(function()
		client.new({})
	end)
	expect.error(function()
		client.new(nil)
	end)
end

return T
