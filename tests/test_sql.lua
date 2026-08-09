-- Tests for the SQL response envelope and the SELECT builder.
--
-- No child Neovim: the module is pure logic, like `tests/test_json.lua`. The
-- envelope cases lean on the committed live fixtures where one exists, and fall
-- back to a hand-written envelope only for the shapes the server can return but
-- these two captures happen not to contain (an unnamed column, a null in a row,
-- a mutation response).
local sql = require("spacetime.lib.sql")
local read = require("tests.helpers.fixtures").read
local expect = MiniTest.expect

local T = MiniTest.new_set()

---Parse a body, asserting that it parsed.
---@param body string
---@return SpacetimeSqlResult
local function parsed(body)
	local result, err = sql.parse(body)
	expect.equality(err, nil)
	assert(result)
	return result
end

T["the committed fixture yields 2 rows and 4 columns"] = function()
	local result = parsed(read("sql_rows.json"))
	expect.equality(#result.rows, 2)
	expect.equality(#result.columns, 4)
end

T["column names come out of the some options in schema order"] = function()
	local names = {}
	for i, column in ipairs(parsed(read("sql_rows.json")).columns) do
		names[i] = column.name
	end
	expect.equality(names, { "security_id", "description", "code", "scale" })
end

T["column algebraic types are preserved for the value renderer"] = function()
	local columns = parsed(read("sql_rows.json")).columns
	expect.no_equality(columns[3].algebraic_type.Sum, nil)
	expect.no_equality(columns[4].algebraic_type.U8, nil)
end

T["rows stay positional and keep their nested Option"] = function()
	local rows = parsed(read("sql_rows.json")).rows
	expect.equality(rows[1], { "GBP", "British Pound Sterling", { 0, "£" }, 2 })
	expect.equality(rows[2][3][2], "🎟")
end

T["the duration comes from total_duration_micros"] = function()
	expect.equality(parsed(read("sql_rows.json")).duration_micros, 167)
end

T["a bare object parses identically to the one-element array"] = function()
	local text = read("sql_rows.json")
	local bare = assert(text:match("^%s*%[(.*)%]%s*$"), "fixture is not an array")
	expect.equality(parsed(bare), parsed(text))
end

T["an empty array yields no columns, no rows and zero duration"] = function()
	local result = parsed("[]")
	expect.equality(result.columns, {})
	expect.equality(result.rows, {})
	expect.equality(result.duration_micros, 0)
end

T["a mutation response with no schema key parses with no columns"] = function()
	local result = parsed(
		'[{"rows":[],"total_duration_micros":42,' .. '"stats":{"rows_inserted":1,"rows_deleted":0,"rows_updated":0}}]'
	)
	expect.equality(result.columns, {})
	expect.equality(result.rows, {})
	expect.equality(result.duration_micros, 42)
end

T["a big integer in a row survives as a decimal string"] = function()
	local rows = parsed(read("sql_bigint.json")).rows
	expect.equality(rows[1][2], "118584542101933595460429904643539362103")
end

T["a null in a row is kept so the row keeps its length"] = function()
	local result = parsed([==[
		[{"schema":{"elements":[
			{"name":{"some":"a"},"algebraic_type":{"String":[]}},
			{"name":{"some":"b"},"algebraic_type":{"String":[]}}
		]},"rows":[["x", null]],"total_duration_micros":1}]
	]==])
	expect.equality(#result.rows[1], 2)
	expect.equality(result.rows[1][2], vim.NIL)
end

T["an unnamed column falls back to its position"] = function()
	local result = parsed([==[
		[{"schema":{"elements":[
			{"name":{"some":"a"},"algebraic_type":{"String":[]}},
			{"name":{"none":[]},"algebraic_type":{"String":[]}}
		]},"rows":[],"total_duration_micros":1}]
	]==])
	expect.equality(result.columns[1].name, "a")
	expect.equality(result.columns[2].name, "column_2")
end

T["malformed JSON is reported rather than raised"] = function()
	local result, err
	expect.no_error(function()
		result, err = sql.parse("not json at all")
	end)
	expect.equality(result, nil)
	expect.equality(type(err), "string")
end

T["LIMIT renders and OFFSET is omitted when zero or absent"] = function()
	expect.equality(sql.select_all("account", 100), 'SELECT * FROM "account" LIMIT 100')
	expect.equality(sql.select_all("account", 100, 0), 'SELECT * FROM "account" LIMIT 100')
end

T["OFFSET renders when non-zero"] = function()
	expect.equality(sql.select_all("account", 100, 200), 'SELECT * FROM "account" LIMIT 100 OFFSET 200')
end

T["an embedded quote in a table name is doubled"] = function()
	expect.equality(sql.select_all('we"ird', 1), 'SELECT * FROM "we""ird" LIMIT 1')
end

T["an injection attempt stays inside the quoted identifier"] = function()
	expect.equality(sql.select_all('t"; DROP TABLE x; --', 1), 'SELECT * FROM "t""; DROP TABLE x; --" LIMIT 1')
end

T["a non-numeric or negative limit is rejected"] = function()
	expect.error(function()
		sql.select_all("t", "10; DROP TABLE x")
	end)
	expect.error(function()
		sql.select_all("t", -1)
	end)
	expect.error(function()
		sql.select_all("t", 1.5)
	end)
	expect.error(function()
		sql.select_all("t", nil)
	end)
end

return T
