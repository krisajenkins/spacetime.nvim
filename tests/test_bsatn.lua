-- Tests for `lib/bsatn.lua`: a hex-encoded BSATN value decoded against its
-- `AlgebraicType`.
--
-- Pure logic, so no child Neovim and no transport stub. The assertions are
-- mostly written against `lib/value.format` rather than against the decoded
-- table, because the rendered text is what the decode exists to produce and
-- `{0, {}}` is a far less readable expectation than `"none"`.
--
-- Both captures carry exactly one column default — `class_instance.booking_count`,
-- a `u32` zero — so the fixtures cover the wire plumbing and nothing else. Every
-- other shape here is hand-written, because a default of any other type is
-- variety the captures simply do not have (tests/CLAUDE.md).
local expect = MiniTest.expect
local bsatn = require("spacetime.lib.bsatn")
local value = require("spacetime.lib.value")
local read = require("tests.helpers.fixtures").read

local T = MiniTest.new_set()

---`Option<T>`, spelled the way both schema versions send it.
---@param some any The `some` variant's AlgebraicType.
---@return table
local function option_of(some)
	return {
		Sum = {
			variants = {
				{ name = { some = "some" }, algebraic_type = some },
				{ name = { some = "none" }, algebraic_type = { Product = { elements = {} } } },
			},
		},
	}
end

---Decode and render, the way `ui/schema.lua` does.
---@param hex string
---@param atype table
---@param types? table
---@return string # The rendered text, or `"!" .. err` when the decode failed.
local function rendered(hex, atype, types)
	local decoded, err = bsatn.decode(hex, atype, types or {})
	if err ~= nil then
		return "!" .. err
	end
	return (value.format(decoded, atype, types or {}, { nested = true }))
end

--------------------------------------------------------------------------------
-- The reported bug
--------------------------------------------------------------------------------

T["an Option's None decodes to none, not to the byte 01"] = function()
	-- The whole reason this module exists. `01` is the sum tag of the `none`
	-- variant; read as a number it says the default age is one.
	expect.equality(rendered("01", option_of({ U16 = {} })), "none")
end

T["an Option's Some carries its payload"] = function()
	-- Tag 0, then `0539` little-endian.
	expect.equality(rendered("000539", option_of({ U16 = {} })), "some(14597)")
end

--------------------------------------------------------------------------------
-- Scalars
--------------------------------------------------------------------------------

T["integers are little-endian at every width"] = function()
	expect.equality(rendered("2a", { U8 = {} }), "42")
	expect.equality(rendered("0005", { U16 = {} }), "1280")
	expect.equality(rendered("00000000", { U32 = {} }), "0")
	expect.equality(rendered("2a00000000000000", { U64 = {} }), "42")
end

T["a big integer keeps every digit"] = function()
	-- Above 2^53 a Lua number stops being exact, so the decode never makes one:
	-- these are decimal strings built from the bytes by hand.
	expect.equality(rendered("ffffffffffffffff", { U64 = {} }), "18446744073709551615")
	expect.equality(rendered(string.rep("ff", 16), { U128 = {} }), "340282366920938463463374607431768211455")
	expect.equality(
		rendered(string.rep("ff", 32), { U256 = {} }),
		"115792089237316195423570985008687907853269984665640564039457584007913129639935"
	)
end

T["a signed integer is two's complement"] = function()
	expect.equality(rendered("ff", { I8 = {} }), "-1")
	expect.equality(rendered("80", { I8 = {} }), "-128")
	expect.equality(rendered("7f", { I8 = {} }), "127")
	expect.equality(rendered("ffffffffffffffff", { I64 = {} }), "-1")
	expect.equality(rendered("0000000000000080", { I64 = {} }), "-9223372036854775808")
	expect.equality(
		rendered("00" .. string.rep("00", 30) .. "80", { I256 = {} }),
		"-57896044618658097711785492504343953926634992332820282019728792003956564819968"
	)
end

T["bools and floats decode"] = function()
	expect.equality(rendered("00", { Bool = {} }), "false")
	expect.equality(rendered("01", { Bool = {} }), "true")
	expect.equality(rendered("0000c03f", { F32 = {} }), "1.5")
	expect.equality(rendered("000000000000f03f", { F64 = {} }), "1")
	expect.equality(rendered("000000000000f0bf", { F64 = {} }), "-1")
	-- Subnormals and the all-ones exponent are decoded rather than mangled.
	expect.equality(bsatn.decode("0100000000000000", { F64 = {} }) > 0, true)
	expect.equality(bsatn.decode("000000000000f07f", { F64 = {} }), math.huge)
end

T["a string is a length-prefixed run of bytes"] = function()
	expect.equality(rendered("0500000068656c6c6f", { String = {} }), '"hello"')
	-- Quoted, so the empty string is still visible as a value: this is what the
	-- `nested` option to `lib/value.format` is for.
	expect.equality(rendered("00000000", { String = {} }), '""')
end

--------------------------------------------------------------------------------
-- Composites
--------------------------------------------------------------------------------

T["a product decodes positionally"] = function()
	local point = {
		Product = {
			elements = {
				{ name = { some = "x" }, algebraic_type = { U8 = {} } },
				{ name = { some = "y" }, algebraic_type = { U8 = {} } },
			},
		},
	}
	expect.equality(rendered("0107", point), "{ x = 1, y = 7 }")
end

T["an array is a count then its elements"] = function()
	expect.equality(rendered("030000000102ff", { Array = { U8 = {} } }), "[1, 2, 255]")
	expect.equality(rendered("00000000", { Array = { U8 = {} } }), "[]")
end

T["a Ref resolves through the typespace"] = function()
	local types = {
		typespace = {
			{ String = {} },
			{ Product = { elements = { { name = { some = "id" }, algebraic_type = { Ref = 0 } } } } },
		},
	}
	expect.equality(rendered("020000006869", { Ref = 0 }, types), '"hi"')
	expect.equality(rendered("020000006869", { Ref = 1 }, types), '{ id = "hi" }')
end

T["an enum variant is named, and a unit variant carries no payload"] = function()
	local status = {
		Sum = {
			variants = {
				{ name = { some = "Idle" }, algebraic_type = { Product = { elements = {} } } },
				{ name = { some = "Busy" }, algebraic_type = { U8 = {} } },
			},
		},
	}
	expect.equality(rendered("00", status), "Idle")
	expect.equality(rendered("0109", status), "Busy(9)")
end

--------------------------------------------------------------------------------
-- Bad input
--------------------------------------------------------------------------------

T["a malformed payload is an error, never a guess"] = function()
	local cases = {
		{ "0z", { U8 = {} }, "not a hex string" },
		{ "0", { U8 = {} }, "not a hex string" },
		{ "0000", { U32 = {} }, "truncated" },
		{ "0102", { U8 = {} }, "1 trailing byte(s)" },
		{ "07", option_of({ U16 = {} }), "sum tag 7 is not in the type" },
		{ "00", { Ref = 3 }, "unresolvable Ref" },
	}
	for _, case in ipairs(cases) do
		local decoded, err = bsatn.decode(case[1], case[2], {})
		expect.equality(decoded, nil)
		expect.equality(err, case[3])
	end
end

T["a column with no type, and a value that is not a string, both fail cleanly"] = function()
	expect.equality(select(2, bsatn.decode("00", nil, {})), "no type to decode against")
	expect.equality(select(2, bsatn.decode(vim.NIL, { U8 = {} }, {})), "not a hex string")
end

T["an array count past the end of the value is rejected"] = function()
	-- Four billion elements of a zero-width type would otherwise be a loop that
	-- never ends; the count is checked against the bytes left before any of it
	-- is read.
	local unit = { Array = { Product = { elements = {} } } }
	expect.equality(select(2, bsatn.decode("ffffffff", unit, {})), "array of 4294967295 is longer than the value")
end

T["a self-referential type bottoms out instead of recursing"] = function()
	-- A product whose only element refers back to the product: every hop reads no
	-- bytes, so only the depth budget can stop it.
	local types = { typespace = { { Product = { elements = { { algebraic_type = { Ref = 0 } } } } } } }
	expect.equality(select(2, bsatn.decode("", { Ref = 0 }, types)), "type nests deeper than 32")
end

--------------------------------------------------------------------------------
-- Against the capture
--------------------------------------------------------------------------------

T["the fixture's only column default decodes to zero"] = function()
	-- `class_instance.booking_count`, a `u32`, in both wire shapes.
	for _, version in ipairs({ 9, 10 }) do
		local json = require("spacetime.lib.json")
		local model = require("spacetime.lib.schema").parse(json.decode(read("schema_v" .. version .. ".json")))
		local column = require("spacetime.lib.schema").table_by_name(model, "class_instance").columns[10]

		expect.equality(column.default, "00000000")
		expect.equality(rendered(column.default, column.type, model), "0")
	end
end

return T
