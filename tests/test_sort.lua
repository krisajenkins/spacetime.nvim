-- Tests for the grid's display order.
--
-- No child Neovim: `lib/sort.lua` is pure logic — rows and a column index in, a
-- permutation out — and so is the `lib/value.sort_key` walk underneath it.
--
-- The property under nearly every case here is that the order comes from the
-- *raw* values rather than from the strings `lib/value.format` would render
-- them as. The two disagree constantly: `"10"` sorts before `"9"`, `"1.5ms"`
-- before `"500µs"`, and `none` renders as the same `NULL` a missing value does.
local sort = require("spacetime.lib.sort")
local value = require("spacetime.lib.value")
local expect = MiniTest.expect

local T = MiniTest.new_set()

local U64 = { U64 = {} }
local STRING = { String = {} }
local DURATION = {
	Product = {
		elements = { { name = { some = "__time_duration_micros__" }, algebraic_type = { I64 = {} } } },
	},
}

---`Option<some>`, exactly as the server describes one.
---@param some table
---@return table
local function option(some)
	return {
		Sum = {
			variants = {
				{ name = { some = "some" }, algebraic_type = some },
				{ name = { some = "none" }, algebraic_type = { Product = { elements = {} } } },
			},
		},
	}
end

---Sort single-column `rows` and hand back the resulting order.
---@param rows any[][]
---@param atype any
---@param descending? boolean
---@return integer[]
local function order_of(rows, atype, descending)
	return sort.order(rows, 1, { algebraic_type = atype, descending = descending })
end

---Whether `order` is a permutation of `1..n` — the invariant a sort must never
---break, whatever it does with the order.
---@param order integer[]
---@param n integer
---@return boolean
local function is_permutation(order, n)
	if #order ~= n then
		return false
	end
	local seen = {}
	for _, index in ipairs(order) do
		if type(index) ~= "number" or index < 1 or index > n or seen[index] then
			return false
		end
		seen[index] = true
	end
	return true
end

--------------------------------------------------------------------------------
-- Raw values, not display strings
--------------------------------------------------------------------------------

T["a numeric column sorts 9 before 10, not lexicographically"] = function()
	local rows = { { 9 }, { 10 }, { 1 } }
	expect.equality(order_of(rows, U64), { 3, 1, 2 })
	expect.equality(order_of(rows, U64, true), { 2, 1, 3 })

	-- With no type at all the values are still numbers, so the order is the same.
	expect.equality(order_of(rows, nil), { 3, 1, 2 })

	-- The same digits under a String column *are* text, and sort as text.
	expect.equality(order_of({ { "9" }, { "10" } }, STRING), { 2, 1 })

	-- And a big integer that arrived as digits — which is how `lib/json.lua` hands
	-- back anything of 16 digits or more — sorts as the number it is.
	expect.equality(order_of({ { "9" }, { "10" } }, U64), { 1, 2 })
end

T["a duration column sorts by micros, not by the text it renders as"] = function()
	-- `500µs` and `1.5ms`: the strings sort the other way round from the values.
	local rows = { { { 500 } }, { { 1500 } }, { { 999999 } } }
	expect.equality(value.format(rows[1][1], DURATION), "500µs")
	expect.equality(value.format(rows[2][1], DURATION), "1.5ms")

	expect.equality(order_of(rows, DURATION), { 1, 2, 3 })
	expect.equality(order_of(rows, DURATION, true), { 3, 2, 1 })
end

T["a big integer keeps its exact order past 2^53"] = function()
	-- Two identifiers that `tonumber` rounds to the same float. The digits are the
	-- tiebreak, so they still order — and order correctly.
	local rows = { { "118584542101933595460429904643539362104" }, { "118584542101933595460429904643539362103" } }
	expect.equality(order_of(rows, U64), { 2, 1 })
end

--------------------------------------------------------------------------------
-- Ties and NULLs
--------------------------------------------------------------------------------

T["equal keys keep data-index order, in both directions"] = function()
	-- `table.sort` is not stable, so this is the tiebreak doing the work: without
	-- it the three 5s would come out in whatever order the quicksort left them.
	local rows = { { 5 }, { 5 }, { 5 }, { 1 } }
	expect.equality(order_of(rows, U64), { 4, 1, 2, 3 })
	-- Descending reverses the *values*; the tie is still in data order.
	expect.equality(order_of(rows, U64, true), { 1, 2, 3, 4 })
end

T["NULLs sort last in both directions"] = function()
	-- A missing cell, a JSON `null`, and a value the server simply did not send.
	local rows = { { 2 }, { vim.NIL }, { 1 }, {} }
	expect.equality(order_of(rows, U64), { 3, 1, 2, 4 })
	expect.equality(order_of(rows, U64, true), { 1, 3, 2, 4 })

	-- An Option's `none` is the same NULL the grid renders, and sorts as one.
	local optional = { { { 0, "b" } }, { { 1, {} } }, { { 0, "a" } } }
	expect.equality(order_of(optional, option(STRING)), { 3, 1, 2 })
	expect.equality(order_of(optional, option(STRING), true), { 1, 3, 2 })
end

--------------------------------------------------------------------------------
-- Total order
--------------------------------------------------------------------------------

T["a mixed-type column sorts rather than raising"] = function()
	-- `table.sort` raises "invalid order function for sorting" on an inconsistent
	-- comparator, and comparing a number against a string raises outright. Both
	-- are what a sum column, or a column with no type, hands over.
	local rows = { { 5 }, { "text" }, { true }, { vim.NIL }, { { 1, 2 } }, { "5" }, { -1 } }
	local order
	expect.no_error(function()
		order = order_of(rows, nil)
	end)
	expect.equality(is_permutation(order, #rows), true)
	expect.no_error(function()
		order = order_of(rows, nil, true)
	end)
	expect.equality(is_permutation(order, #rows), true)

	-- A real sum: different variants, different payload types.
	local sum = {
		Sum = {
			variants = {
				{ name = { some = "number" }, algebraic_type = U64 },
				{ name = { some = "text" }, algebraic_type = STRING },
			},
		},
	}
	local mixed = { { { 1, "b" } }, { { 0, 7 } }, { { 1, "a" } }, { { 0, 2 } } }
	expect.no_error(function()
		order = sort.order(mixed, 1, { algebraic_type = sum })
	end)
	-- Variants group before they order: both `number`s, then both `text`s.
	expect.equality(order, { 4, 2, 3, 1 })
end

T["a NaN is keyed as absent rather than poisoning the comparator"] = function()
	local nan = 0 / 0
	local rows = { { nan }, { 3 }, { 1 } }
	local order
	expect.no_error(function()
		order = order_of(rows, { F64 = {} })
	end)
	expect.equality(order, { 3, 2, 1 })
end

--------------------------------------------------------------------------------
-- order / rank
--------------------------------------------------------------------------------

T["order and rank stay mutually inverse across repeated sorts"] = function()
	local rows = {
		{ 3, "c" },
		{ 1, "a" },
		{ 3, "b" },
		{ 2, "a" },
		{ vim.NIL, "d" },
	}

	local sorts = {
		{ column = 1, atype = U64, descending = false },
		{ column = 1, atype = U64, descending = true },
		{ column = 2, atype = STRING, descending = false },
		{ column = 2, atype = STRING, descending = true },
		{ column = 1, atype = U64, descending = false },
	}
	for _, one in ipairs(sorts) do
		local order = sort.order(rows, one.column, { algebraic_type = one.atype, descending = one.descending })
		local rank = sort.rank(order)

		expect.equality(is_permutation(order, #rows), true)
		expect.equality(is_permutation(rank, #rows), true)
		for position = 1, #rows do
			expect.equality(rank[order[position]], position)
		end
		for index = 1, #rows do
			expect.equality(order[rank[index]], index)
		end
	end

	-- And the identity mapping is its own inverse.
	local identity = sort.identity(4)
	expect.equality(identity, { 1, 2, 3, 4 })
	expect.equality(sort.rank(identity), identity)
	expect.equality(sort.identity(0), {})
end

T["sorting reads the rows and never rewrites them"] = function()
	local rows = { { 3 }, { 1 }, { 2 } }
	local order = order_of(rows, U64)

	expect.equality(order, { 2, 3, 1 })
	-- The point of the whole mapping: the data is exactly where it was.
	expect.equality(rows, { { 3 }, { 1 }, { 2 } })
end

return T
