-- Tests for AlgebraicType-driven value rendering.
--
-- No child Neovim: the module is pure logic, like `tests/test_sql.lua`. Almost
-- every case is driven from the committed live captures — the real schema
-- carries every shape that matters (Option, ScheduleAt, both magic timestamp
-- newtypes, an `Array<Ref>` and the deliberately-unrecognised `__uuid__`), and
-- a hand-written type would only prove that this file and `value.lua` agree
-- with each other. The synthetic cases at the bottom cover what no real server
-- sends: cyclic types, mismatched values and garbage.

local value = require("spacetime.lib.value")
local schema = require("spacetime.lib.schema")
local sql = require("spacetime.lib.sql")
local read = require("tests.helpers.fixtures").read
local expect = MiniTest.expect

local T = MiniTest.new_set()

-- The live schema, parsed once: every `type_at` below indexes this.
local cached_model
local function model()
	if cached_model == nil then
		cached_model = schema.parse(require("spacetime.lib.json").decode(read("schema_v10.json")))
	end
	return cached_model
end

---The type of one element of a typespace product, by 0-based ref and 1-based
---element position.
---@param ref integer
---@param index integer
---@return table
local function element_type(ref, index)
	local ty = assert(schema.type_at(model(), ref), "no type at ref " .. ref)
	return ty.Product.elements[index].algebraic_type
end

---Parse a SQL fixture, asserting it parsed.
---@param name string
---@return SpacetimeSqlResult
local function rows_of(name)
	local result, err = sql.parse(read(name))
	expect.equality(err, nil)
	return assert(result)
end

--------------------------------------------------------------------------------
-- Driven from the live SQL captures
--------------------------------------------------------------------------------

T["an Option from the live rows renders as some(payload)"] = function()
	local result = rows_of("sql_rows.json")
	local code = result.columns[3].algebraic_type

	local text, hl = value.format(result.rows[1][3], code)
	expect.equality(text, 'some("£")')
	expect.equality(hl, nil)

	expect.equality((value.format(result.rows[2][3], code)), 'some("🎟")')
end

T["the none variant renders as none, highlighted as a null"] = function()
	local code = rows_of("sql_rows.json").columns[3].algebraic_type
	local text, hl = value.format({ 1, {} }, code)
	expect.equality(text, "none")
	expect.equality(hl, "SpacetimeNull")
end

T["a top-level string is bare and a small integer is plain digits"] = function()
	local result = rows_of("sql_rows.json")
	local text, hl = value.format(result.rows[1][1], result.columns[1].algebraic_type)
	expect.equality(text, "GBP")
	expect.equality(hl, nil)
	expect.equality((value.format(result.rows[1][4], result.columns[4].algebraic_type)), "2")
end

T["both bigint wire spellings survive verbatim"] = function()
	local result = rows_of("sql_bigint.json")
	local row = result.rows[1]

	-- The U256 arrives as hex, the U128 as a bare number that `lib/json` hands
	-- back as an exact 39-digit decimal string. Neither is converted.
	local identity, identity_hl = value.format(row[1], result.columns[1].algebraic_type)
	expect.equality(identity, "0xc2005efe02e92547ddd4bd106e84a281ead78a30fa26f42e619d70b20917c3dd")
	expect.equality(identity_hl, nil)

	local connection, connection_hl = value.format(row[2], result.columns[2].algebraic_type)
	expect.equality(connection, "118584542101933595460429904643539362103")
	expect.equality(connection_hl, nil)
end

--------------------------------------------------------------------------------
-- Driven from the live schema
--------------------------------------------------------------------------------

T["the __identity__ newtype renders its scalar as a special"] = function()
	local hex = "0xc2005efe02e92547ddd4bd106e84a281ead78a30fa26f42e619d70b20917c3dd"
	local text, hl = value.format({ hex }, element_type(1, 1), model())
	expect.equality(text, hex)
	expect.equality(hl, "SpacetimeSpecial")
end

T["a timestamp formats as ISO-8601 UTC from either wire spelling"] = function()
	local created_at = element_type(0, 6)

	-- 16 digits, so `lib/json` stringifies it; the bare number is what a shorter
	-- value would arrive as.
	local text, hl = value.format({ "1780864718837447" }, created_at, model())
	expect.equality(text, "2026-06-07T20:38:38.837447Z")
	expect.equality(hl, "SpacetimeSpecial")

	expect.equality((value.format({ 1780864718837447 }, created_at, model())), "2026-06-07T20:38:38.837447Z")
end

-- The two renderers exported for callers that have micros but no column: the
-- row grid's badge (`duration`) and the log view's stamp (`timestamp`). They
-- must be the *same* renderers a cell goes through, or a timestamp would read
-- one way in the grid and another in the logs.
T["the exported timestamp and duration renderers agree with the cell ones"] = function()
	local created_at = element_type(0, 6)

	expect.equality(value.timestamp(1780864718837447), "2026-06-07T20:38:38.837447Z")
	expect.equality(value.timestamp("1780864718837447"), (value.format({ 1780864718837447 }, created_at, model())))
	expect.equality(value.duration(90000000), "1m 30s")

	-- Anything that is not a count of micros is `nil` rather than a guess: the log
	-- view shows its own placeholder for an entry whose `ts` was unreadable.
	expect.equality(value.timestamp("nope"), nil)
	expect.equality(value.timestamp(nil), nil)
end

T["ScheduleAt renders both of its variants with their payloads"] = function()
	local scheduled_at = element_type(6, 2)
	expect.equality((value.format({ 0, { 90000000 } }, scheduled_at, model())), "Interval(1m 30s)")
	expect.equality(
		(value.format({ 1, { 1780864718837447 } }, scheduled_at, model())),
		"Time(2026-06-07T20:38:38.837447Z)"
	)
end

T["a payload-less sum variant renders as its bare name"] = function()
	local provider = assert(schema.type_at(model(), 2))
	expect.equality((value.format({ 0, {} }, provider, model())), "google")
	expect.equality((value.format({ 1, {} }, provider, model())), "spacetime")
end

T["an unrecognised newtype passes through as a plain product"] = function()
	-- `__uuid__` is a real upstream newtype and is in this fixture. Rendering it
	-- as anything other than what arrived would be a guess.
	local text, hl = value.format({ 42 }, element_type(12, 2), model())
	expect.equality(text, "{ __uuid__ = 42 }")
	expect.equality(hl, nil)
end

T["an array renders its elements at nesting depth"] = function()
	local account = element_type(13, 4)
	expect.equality((value.format({ "assets", "cash" }, account, model())), '["assets", "cash"]')
	expect.equality((value.format({}, account, model())), "[]")
end

T["a whole positional row renders as a named product"] = function()
	local user = assert(schema.type_at(model(), 0))
	local row = { 7, "a@b.com", "A B", { 0, "https://x/y.png" }, false, { "1780864718837447" } }
	expect.equality(
		(value.format(row, user, model())),
		'{ id = 7, primary_email = "a@b.com", display_name = "A B", picture_url = some("https://x/y.png"), '
			.. "is_admin = false, created_at = 2026-06-07T20:38:38.837447Z }"
	)
end

T["labels name the live types the way a module author would"] = function()
	expect.equality(value.label(element_type(0, 4), model()), "Option<String>")
	expect.equality(value.label(element_type(0, 6), model()), "Timestamp")
	expect.equality(value.label(element_type(1, 1), model()), "Identity")
	expect.equality(value.label(schema.type_at(model(), 2), model()), "{ google | spacetime }")
	expect.equality(value.label(element_type(13, 4), model()), "Array<String>")
	expect.equality(value.label(element_type(12, 2), model()), "{ __uuid__: U128 }")
	-- `Array<Ref 38>`; the alias beats the structural label.
	expect.equality(value.label(element_type(37, 1), model()), "Array<SeedTemplateArg>")
	expect.equality(value.label({ U64 = {} }), "U64")
end

--------------------------------------------------------------------------------
-- Synthetic: what no real server sends
--------------------------------------------------------------------------------

T["a self-referential Ref terminates"] = function()
	local typespace = { { Ref = 0 } }
	expect.equality(value.label({ Ref = 0 }, typespace), "Ref(0)")
	expect.equality((value.format({ 1, 2 }, { Ref = 0 }, typespace)), "…")
end

T["mutually recursive Refs terminate at the depth limit"] = function()
	local typespace = {
		{ Product = { elements = { { name = { some = "next" }, algebraic_type = { Ref = 1 } } } } },
		{ Product = { elements = { { name = { some = "prev" }, algebraic_type = { Ref = 0 } } } } },
	}
	expect.equality(value.label({ Ref = 0 }, typespace), "{ next: { prev: Ref(0) } }")

	local nested = {}
	for _ = 1, 20 do
		nested = { nested }
	end
	local text = value.format(nested, { Ref = 0 }, typespace)
	expect.equality(type(text), "string")
	expect.equality(text:find("…", 1, true) ~= nil, true)
end

T["a null renders as NULL with or without a type"] = function()
	local text, hl = value.format(vim.NIL, { String = {} })
	expect.equality(text, "NULL")
	expect.equality(hl, "SpacetimeNull")

	local bare_text, bare_hl = value.format(vim.NIL, nil)
	expect.equality(bare_text, "NULL")
	expect.equality(bare_hl, "SpacetimeNull")
end

T["a value that contradicts its type falls back to the untyped render"] = function()
	local product = { Product = { elements = { { name = { some = "a" }, algebraic_type = { U8 = {} } } } } }
	expect.no_error(function()
		local text, hl = value.format("oops", product)
		expect.equality(text, "oops")
		expect.equality(hl, nil)
	end)
end

T["garbage arguments yield a string rather than an error"] = function()
	expect.equality((value.format(nil, nil, nil)), "NULL")
	expect.equality((value.format({}, vim.NIL)), "{}")
	expect.equality(value.label(vim.NIL), "?")
	expect.equality(value.label(nil), "?")
	expect.equality(value.label({ 1, 2, 3 }), "?")
end

T["array rendering is capped by max_elements"] = function()
	local many = {}
	for i = 1, 100 do
		many[i] = i
	end
	local text = value.format(many, { Array = { U8 = {} } }, nil, { max_elements = 3 })
	expect.equality(text, "[1, 2, 3, …]")
end

T["the named shapes of a sum and a product render like the positional ones"] = function()
	local option = {
		Sum = {
			variants = {
				{ name = { some = "some" }, algebraic_type = { String = {} } },
				{ name = { some = "none" }, algebraic_type = { Product = { elements = {} } } },
			},
		},
	}
	expect.equality((value.format({ some = "x" }, option)), (value.format({ 0, "x" }, option)))

	local product = {
		Product = {
			elements = {
				{ name = { some = "a" }, algebraic_type = { U8 = {} } },
				{ name = { some = "b" }, algebraic_type = { U8 = {} } },
			},
		},
	}
	expect.equality((value.format({ a = 1, b = 2 }, product)), "{ a = 1, b = 2 }")
	expect.equality((value.format({ 1, 2 }, product)), "{ a = 1, b = 2 }")
end

T["an out-of-range sum tag says so rather than dropping the payload"] = function()
	local provider = assert(schema.type_at(model(), 2))
	expect.equality((value.format({ 9, "surprise" }, provider, model())), '<tag 9>("surprise")')
end

T["cell returns the grid cell shape and feeds grid.layout"] = function()
	expect.equality(value.cell(vim.NIL, nil), { text = "NULL", hl = "SpacetimeNull" })

	local grid = require("spacetime.ui.grid")
	local columns = { { name = "code" }, { name = "scale" } }
	local cells = { { value.cell("GBP", { String = {} }), value.cell(vim.NIL, { U8 = {} }) } }
	expect.no_error(function()
		local layout = grid.layout(columns, cells)
		expect.equality(layout.lines[2], "GBP   NULL")
	end)
end

T["a sort key orders the value, not the text it renders as"] = function()
	local timestamp = {
		Product = {
			elements = {
				{ name = { some = "__timestamp_micros_since_unix_epoch__" }, algebraic_type = { I64 = {} } },
			},
		},
	}

	local function key(v, atype)
		return value.sort_key(v, atype, model())
	end
	local function less(a, b)
		return value.compare_keys(a, b) < 0
	end

	-- The whole point: `"10"` renders before `"9"` and sorts after it.
	expect.equality(less(key(9, { U64 = {} }), key(10, { U64 = {} })), true)
	expect.equality(value.format(9, { U64 = {} }) > value.format(10, { U64 = {} }), true)

	-- A timestamp keys as its micros, not as the ISO string.
	expect.equality(less(key({ 1 }, timestamp), key({ 2 }, timestamp)), true)
	expect.equality(value.compare_keys(key({ 7 }, timestamp), key(7, timestamp)), 0)

	-- NULL, `none`, and a value no key survives are all absences, and an absence
	-- is flagged rather than ordered.
	local option = rows_of("sql_rows.json").columns[3].algebraic_type -- Option<String>
	expect.equality(key(vim.NIL, { String = {} }).null, true)
	expect.equality(key({ 1, {} }, option).null, true)
	expect.equality(key({ 0, "GBP" }, option).null, false)
	expect.equality(value.compare_keys(key(nil, nil), key(vim.NIL, nil)), 0)
	expect.equality(less(key("a", { String = {} }), key(nil, nil)), true)

	-- A key that is a prefix of another sorts before it, and nothing raises on
	-- arguments no schema would produce.
	expect.no_error(function()
		local pair = key({ "a", "b" }, nil)
		expect.equality(less(key({ "a" }, nil), pair), true)
		expect.equality(value.compare_keys(pair, pair), 0)
		expect.equality(key(print, nil).null, false)
	end)
end

T["durations render at a sensible scale"] = function()
	local duration = {
		Product = {
			elements = { { name = { some = "__time_duration_micros__" }, algebraic_type = { I64 = {} } } },
		},
	}
	local cases = {
		{ 0, "0s" },
		{ 500, "500µs" },
		{ 1500, "1.5ms" },
		{ 1500000, "1.5s" },
		{ 90000000, "1m 30s" },
		{ 5400000000, "1h 30m" },
		{ 183845000000, "2d 3h 4m 5s" },
		{ -1500000, "-1.5s" },
	}
	for _, case in ipairs(cases) do
		local text, hl = value.format({ case[1] }, duration)
		expect.equality(text, case[2])
		expect.equality(hl, "SpacetimeSpecial")
	end
end

return T
