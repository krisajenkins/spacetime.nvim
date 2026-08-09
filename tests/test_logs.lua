-- Tests for NDJSON log entry parsing and the level ordering.
--
-- No child Neovim: the module is pure logic, like `tests/test_sql.lua`. The
-- committed fixture is 11 real `Info` lines, so it carries the `ts`-as-big-
-- integer and omitted-field cases; every other level, every other `ts` form and
-- every malformed shape is written inline here, because re-capturing the
-- fixture is a manual credentialed step.
local logs = require("spacetime.lib.logs")
local read = require("tests.helpers.fixtures").read
local expect = MiniTest.expect

local T = MiniTest.new_set()

---Parse one line, asserting that it parsed at all.
---@param line string
---@return spacetime.LogEntry
local function parsed(line)
	local entry = logs.parse_line(line)
	assert(entry, "line did not parse: " .. line)
	return entry
end

---The `ts` of a one-off line carrying `value` verbatim as its `ts`.
---@param value string JSON for the `ts` field, e.g. `"1000"` or `'"1970-01-01T00:00:00Z"'`.
---@return integer|nil
local function ts_of(value)
	return parsed('{"level":"Info","ts":' .. value .. ',"message":"m"}').ts
end

T["every line of the committed fixture parses"] = function()
	local entries = logs.parse_lines(read("logs.ndjson"))
	expect.equality(#entries, 11)
	for _, entry in ipairs(entries) do
		expect.equality(entry.level, "Info")
		expect.no_equality(entry.ts, nil)
	end
end

T["a fixture line with no line_number yields every other field"] = function()
	local entries = logs.parse_lines(read("logs.ndjson"))
	expect.equality(entries[1], {
		level = "Info",
		ts = 1786265033970840,
		target = "__spacetimedb__",
		filename = "__spacetimedb__",
		["function"] = "__spacetimedb__",
		message = "Repairing stale view backing tables",
	})
end

T["a fixture line with no target yields every other field"] = function()
	local entries = logs.parse_lines(read("logs.ndjson"))
	expect.equality(entries[3], {
		level = "Info",
		ts = 1786299685393505,
		filename = "spacetimedb_module",
		line_number = 12030,
		["function"] = "on_connect",
		message = "clientConnected sender=c2005efe02e92547ddd4bd106e84a281ead78a30fa26f42e619d70b20917c3dd"
			.. " issuer=https://auth.spacetimedb.com",
	})
end

T["a 16-digit ts survives lib/json stringifying it"] = function()
	local entry = logs.parse_lines(read("logs.ndjson"))[1]
	expect.equality(string.format("%.0f", entry.ts), "1786265033970840")
end

T["a ts sent as a bare JSON number is taken as micros"] = function()
	expect.equality(ts_of("1000"), 1000)
end

T["an RFC3339 ts converts to micros"] = function()
	expect.equality(ts_of('"1970-01-01T00:00:00Z"'), 0)
	expect.equality(ts_of('"1970-01-01T01:00:00+01:00"'), 0)
	expect.equality(ts_of('"2026-08-09T12:00:00Z"'), 1786276800000000)
	expect.equality(ts_of('"2026-01-01T00:00:00Z"'), 1767225600000000)
	expect.equality(ts_of('"2000-02-29T12:34:56.123456Z"'), 951827696123456)
end

T["an RFC3339 fraction pads when short and truncates when long"] = function()
	expect.equality(ts_of('"1970-01-01T00:00:01.5Z"'), 1500000)
	expect.equality(ts_of('"1970-01-01T00:00:01.1234567Z"'), 1123456)
end

T["an absent, null or unreadable ts still yields the message"] = function()
	for _, line in ipairs({
		'{"level":"Info","message":"m"}',
		'{"level":"Info","ts":null,"message":"m"}',
		'{"level":"Info","ts":"not a date","message":"m"}',
	}) do
		local entry = parsed(line)
		expect.equality(entry.ts, nil)
		expect.equality(entry.message, "m")
	end
end

T["the canonical levels are ordered most severe first"] = function()
	for i = 2, #logs.LEVELS do
		expect.equality(logs.rank(logs.LEVELS[i - 1]) > logs.rank(logs.LEVELS[i]), true)
	end
	expect.equality(logs.at_least("Error", "Warn"), true)
	expect.equality(logs.at_least("Info", "Warn"), false)
	expect.equality(logs.at_least("Panic", "Error"), true)
end

T["level names are matched case-insensitively"] = function()
	expect.equality(parsed('{"level":"warn","message":"m"}').level, "Warn")
	expect.equality(parsed('{"level":"WARN","message":"m"}').level, "Warn")
end

T["an unknown level is kept verbatim and sorts as Info"] = function()
	expect.equality(parsed('{"level":"Fatal","message":"m"}').level, "Fatal")
	expect.equality(logs.rank("Fatal"), logs.rank("Info"))
end

T["a Panic line parses despite its extra trace array"] = function()
	local entry =
		parsed('{"level":"Panic","ts":1000,"message":"boom",' .. '"trace":[{"module_name":"m","func_name":"f"}]}')
	expect.equality(entry.level, "Panic")
	expect.equality(entry.message, "boom")
	expect.equality(logs.at_least(entry.level, "Error"), true)
end

T["a malformed line is nil rather than fatal"] = function()
	for _, line in ipairs({
		"",
		"   ",
		"not json",
		'{"level":"Info","ts":178',
		"5",
		"[1,2]",
		"{}",
		'{"message":null}',
	}) do
		local entry
		expect.no_error(function()
			entry = logs.parse_line(line)
		end)
		expect.equality(entry, nil)
	end
end

T["parse_lines drops a bad line and keeps the order of the good ones"] = function()
	local entries = logs.parse_lines(
		'{"level":"Info","message":"first"}\n' .. "{ not json\n" .. '{"level":"Error","message":"second"}\n'
	)
	expect.equality(#entries, 2)
	expect.equality(entries[1].message, "first")
	expect.equality(entries[2].message, "second")
	expect.equality(entries[2].level, "Error")
end

return T
