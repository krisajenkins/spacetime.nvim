-- Which data row appears on which line of the grid.
--
-- Sorting a table of a hundred rows by clicking a column is a *display*
-- operation, and this module is what keeps it one: `order[display_position] =
-- data_index` and its inverse `rank[data_index] = display_position`. Sorting
-- rebuilds the two arrays and nothing else — the rows `lib/sql.parse` handed
-- over are never copied, reordered or rewritten, so nothing about them can be
-- lost on the way, and a cell yanked from line 7 is still the value the server
-- sent for whichever row that is.
--
-- Three properties the comparator has to have, none of them free in Lua:
--
-- 1. **It orders raw values, not display strings.** The key comes from
--    `lib/value.sort_key`, so a U64 column puts `9` before `10` and a Timestamp
--    column sorts by micros rather than by the leading digit of an ISO string.
-- 2. **It is total.** `table.sort` raises "invalid order function for sorting"
--    on a comparator that contradicts itself, and a mixed-type column is exactly
--    where a naive `a < b` does — comparing a number against a string raises
--    outright in Lua. `lib/value.compare_keys` orders by atom class first, and
--    the data-index tiebreak below makes the order strict.
-- 3. **It is deterministic.** `table.sort` is not stable, so equal keys would
--    otherwise come out in whatever order the quicksort left them, and a second
--    sort of the same column would reshuffle rows the user is reading. The
--    tiebreak is the data index, ascending in *both* directions.
--
-- NULLs sort last in both directions: the direction orders the values, and a
-- missing value is not one.
--
-- This module lives under `lib/` and is pure logic — no `vim.api`, `vim.fn`,
-- `vim.ui` or `vim.notify`, and no editor state at all.

local M = {}

---@class SpacetimeSortOpts
---@field algebraic_type? any The column's raw AlgebraicType, so the key is typed.
---@field types? SpacetimeSchema|table[] The schema model, so a `Ref` resolves.
---@field descending? boolean Default `false`.

---The identity mapping over `n` rows: display order is data order.
---@param n integer
---@return integer[]
function M.identity(n)
	local order = {}
	for i = 1, n do
		order[i] = i
	end
	return order
end

---Invert an `order`: `rank[data_index] = display_position`.
---
---The two are mutual inverses by construction, which is what lets the cursor be
---restored to the row it was on rather than to the line it was on.
---@param order integer[]
---@return integer[]
function M.rank(order)
	local rank = {}
	for position, index in ipairs(order) do
		rank[index] = position
	end
	return rank
end

---Order `rows` by column `column`, most significant first.
---
---Returns a fresh `order` — `order[display_position] = data_index`. `rows` is
---read and never touched.
---@param rows any[][] Positional rows, exactly as `lib/sql.parse` hands them over.
---@param column integer 1-based column index.
---@param opts? SpacetimeSortOpts
---@return integer[] order
function M.order(rows, column, opts)
	opts = opts or {}
	local value = require("spacetime.lib.value")
	local descending = opts.descending == true

	-- Keyed once per row, not once per comparison: `table.sort` calls the
	-- comparator O(n log n) times, and the key walk is the expensive half.
	local keys = {} ---@type SpacetimeSortKey[]
	local order = M.identity(#rows)
	for i, row in ipairs(rows) do
		local cell = type(row) == "table" and row[column] or nil
		keys[i] = value.sort_key(cell, opts.algebraic_type, opts.types)
	end

	table.sort(order, function(x, y)
		local a, b = keys[x], keys[y]
		if a.null ~= b.null then
			-- Not `descending`-aware, deliberately: a NULL is last either way.
			return b.null
		end
		if not a.null then
			local comparison = value.compare_keys(a, b)
			if comparison ~= 0 then
				if descending then
					return comparison > 0
				end
				return comparison < 0
			end
		end
		-- Equal keys keep data order, ascending, in both directions: a descending
		-- sort is a reversal of the *values*, not a reshuffle of the ties.
		return x < y
	end)

	return order
end

return M
