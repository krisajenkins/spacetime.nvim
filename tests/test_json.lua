-- Tests for the big-integer-preserving JSON decode.
--
-- No child Neovim: the module is pure logic and `vim.json.decode` is available
-- in the runner itself. Where the assertion is really about the rewrite rather
-- than the decode, it goes through `quote_big_integers` — comparing two JSON
-- strings says far more on failure than comparing two decoded tables.
local json = require("spacetime.lib.json")
local read = require("tests.helpers.fixtures").read
local expect = MiniTest.expect

local T = MiniTest.new_set()

-- The U128 connection_id in tests/fixtures/sql_bigint.json: 39 digits, far
-- beyond a double's 53-bit mantissa.
local U128 = "118584542101933595460429904643539362103"

T["the fixture's U128 connection_id survives exactly"] = function()
	local decoded = json.decode(read("sql_bigint.json"))
	expect.equality(decoded[1].rows[1][2], U128)
end

T["a U256 sent as a hex string in the same row is untouched"] = function()
	local decoded = json.decode(read("sql_bigint.json"))
	expect.equality(decoded[1].rows[1][1], "0xc2005efe02e92547ddd4bd106e84a281ead78a30fa26f42e619d70b20917c3dd")
end

T["a negative big integer keeps its minus sign inside the quotes"] = function()
	expect.equality(json.quote_big_integers("[-" .. U128 .. "]"), '["-' .. U128 .. '"]')
	expect.equality(json.decode("[-" .. U128 .. "]")[1], "-" .. U128)
end

T["small numbers, negatives, floats and exponents stay numbers"] = function()
	local decoded = json.decode('{"a": 42, "b": -17, "c": 1.5, "d": -2.25, "e": 1e3}')
	for key, want in pairs({ a = 42, b = -17, c = 1.5, d = -2.25, e = 1000 }) do
		expect.equality(type(decoded[key]), "number")
		expect.equality(decoded[key], want)
	end
end

T["a long digit run inside a string literal is left alone"] = function()
	local input = '{"s": "1234567890123456789", "n": 1234567890123456789}'
	-- Only the bare number is rewritten; the string keeps its single pair of quotes.
	expect.equality(json.quote_big_integers(input), '{"s": "1234567890123456789", "n": "1234567890123456789"}')

	local decoded = json.decode(input)
	expect.equality(decoded.s, "1234567890123456789")
	expect.equality(decoded.n, "1234567890123456789")
end

T["a backslash-escaped quote does not end the string literal early"] = function()
	expect.equality(json.decode('["a\\"b", ' .. U128 .. "]"), { 'a"b', U128 })
end

T["a string ending in an escaped backslash closes on the right quote"] = function()
	expect.equality(json.decode('["trailing\\\\", -' .. U128 .. "]"), { "trailing\\", "-" .. U128 })
end

T["a genuinely unterminated string raises rather than truncating"] = function()
	expect.error(function()
		json.decode('["abc\\')
	end)
end

T["non-ASCII rows pass through unchanged"] = function()
	local rows = json.decode(read("sql_rows.json"))[1].rows
	expect.equality(rows[1], { "GBP", "British Pound Sterling", { 0, "£" }, 2 })
	expect.equality(rows[2], { "PASS", "Gym class pass — 1 unit redeems 1 class booking", { 0, "🎟" }, 0 })
end

T["a null keeps its position in a row array"] = function()
	local decoded = json.decode("[1, null, 3]")
	expect.equality(#decoded, 3)
	expect.equality(decoded[2], vim.NIL)
	expect.equality(decoded[3], 3)
end

T["long digit runs in a fraction or an exponent are not quoted"] = function()
	local input = "[1.12345678901234567890, 1e-12345678901234567890, 12345678901234567890.5, 1e12345678901234567890]"
	expect.equality(json.quote_big_integers(input), input)
	for _, value in ipairs(json.decode(input)) do
		expect.equality(type(value), "number")
	end
end

T["the threshold is sixteen digits"] = function()
	local decoded = json.decode("[1234567890123456, 123456789012345]")
	expect.equality(decoded[1], "1234567890123456")
	expect.equality(type(decoded[2]), "number")
	expect.equality(decoded[2], 123456789012345)
end

T["a payload with no long digit run is returned untouched"] = function()
	local schema = read("schema_v10.json")
	expect.equality(json.quote_big_integers(schema), schema)
end

T["decoding the live schema fixture stays under a millisecond"] = function()
	local schema = read("schema_v10.json")
	for _ = 1, 10 do
		json.decode(schema)
	end

	-- Minimum of N rather than the mean: a scheduling hiccup on a loaded
	-- machine should not turn a perf budget into a flaky test.
	local best = math.huge
	for _ = 1, 20 do
		local t0 = vim.uv.hrtime()
		json.decode(schema)
		local elapsed = vim.uv.hrtime() - t0
		if elapsed < best then
			best = elapsed
		end
	end

	expect.equality(best < 1e6, true)
end

return T
