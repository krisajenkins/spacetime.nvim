-- Tests for the row-grid layout.
--
-- No child Neovim: `ui/grid.lua` is referentially pure — data in, data out, no
-- buffers, windows or extmarks — and the three functions it does need
-- (`strdisplaywidth`, `strcharpart`, `strchars`) are available in the runner
-- itself, exactly as `vim.json.decode` is for `tests/test_json.lua`.
--
-- Driven from the committed `tests/fixtures/sql_rows.json`, which holds the real
-- `£` (1 column, 2 bytes) and `🎟` (2 columns, 4 bytes) values plus a description
-- containing an em dash — the cases where a byte count and a display width part
-- company.
local grid = require("spacetime.ui.grid")
local json = require("spacetime.lib.json")
local highlights = require("spacetime.ui.highlights")
local read = require("tests.helpers.fixtures").read
local expect = MiniTest.expect

local T = MiniTest.new_set()

local POUND = "£"
local TICKET = "🎟"
local ELLIPSIS = "…"
-- "e" plus a combining acute accent: two characters, one grapheme.
local COMBINING = "e\204\129"

---The fixture's rows, as `{ security_id, code, description }`. `code` sits in
---the middle deliberately: it is the column holding `£` and `🎟`, so it is the
---one whose *padding* has to be computed from display widths. Were it last it
---would never be padded and the interesting case would go untested.
local function fixture_cells()
	local rows = json.decode(read("sql_rows.json"))[1].rows
	local cells = {}
	for i, row in ipairs(rows) do
		cells[i] = { row[1], row[3][2], row[2] }
	end
	return cells
end

local function fixture_columns()
	return {
		{ name = "security_id", pk = true },
		{ name = "code" },
		{ name = "description" },
	}
end

---True when `s` is well-formed UTF-8, i.e. contains no orphaned continuation
---byte — which is what a truncation splitting a character mid-sequence leaves.
local function valid_utf8(s)
	local i, n = 1, #s
	while i <= n do
		local b = s:byte(i)
		local len
		if b < 0x80 then
			len = 1
		elseif b >= 0xC2 and b <= 0xDF then
			len = 2
		elseif b >= 0xE0 and b <= 0xEF then
			len = 3
		elseif b >= 0xF0 and b <= 0xF4 then
			len = 4
		else
			return false
		end
		for k = 1, len - 1 do
			local c = s:byte(i + k)
			if not c or c < 0x80 or c > 0xBF then
				return false
			end
		end
		i = i + len
	end
	return true
end

local function has_trailing_space(lines)
	for _, line in ipairs(lines) do
		if line:match("%s$") then
			return true
		end
	end
	return false
end

T["display_width counts screen columns, not bytes"] = function()
	expect.equality(grid.display_width(POUND), 1)
	expect.equality(grid.display_width(TICKET), 2)
	expect.no_equality(grid.display_width(POUND), #POUND)
	expect.no_equality(grid.display_width(TICKET), #TICKET)
	expect.equality(grid.display_width(""), 0)
end

T["the fixture's columns align despite £ and 🎟"] = function()
	local columns, cells = fixture_columns(), fixture_cells()
	local layout = grid.layout(columns, cells, { max_width = 60 })

	-- Widths are the per-column maxima over the header and every cell.
	for c = 1, #columns do
		local widest = grid.display_width(columns[c].name)
		for r = 1, #cells do
			widest = math.max(widest, grid.display_width(cells[r][c]))
		end
		expect.equality(layout.widths[c], widest)
	end

	-- Every cell starts at the display column its own column dictates, on every
	-- row. Byte-based padding would put the `£` row two columns out from the `🎟`
	-- row from column 3 onward.
	local expected_start = {}
	local acc = 0
	for c = 1, #columns do
		expected_start[c] = acc
		acc = acc + layout.widths[c] + grid.display_width("  ")
	end
	for r = 1, #cells do
		local line = layout.lines[layout.first_data_line + r - 1]
		for c = 1, #columns do
			local prefix = line:sub(1, layout.ranges[r][c].start_col)
			expect.equality(grid.display_width(prefix), expected_start[c])
		end
	end

	-- And the header is padded by the same rule.
	local pad = string.rep(" ", layout.widths[2] - grid.display_width("code"))
	expect.equality(layout.lines[1], "security_id" .. "  " .. "code" .. pad .. "  " .. "description")
	expect.equality(has_trailing_space(layout.lines), false)
end

T["sanitise folds a cell onto one line"] = function()
	expect.equality(grid.sanitise("a\nb"), "a␊b")
	expect.equality(grid.sanitise("a\r\nb"), "a␊b")
	expect.equality(grid.sanitise("a\tb"), "a·b")
	expect.equality(grid.sanitise("a\tb\rc\ndx"), "a·b·c␊dx")
	expect.equality(grid.sanitise("a\0b\127c"), "a·b·c")
	expect.equality(grid.sanitise("plain"), "plain")

	-- The invariant: one line, and a width that cannot depend on 'tabstop'.
	local folded = grid.sanitise("a\nb\tc")
	expect.equality(folded:find("\n"), nil)
	expect.equality(folded:find("\t"), nil)
	expect.equality(grid.display_width(folded), 5)
end

T["truncation never splits a multibyte character"] = function()
	local wide, cut = grid.truncate(TICKET:rep(3), 3)
	expect.equality(cut, true)
	expect.equality(valid_utf8(wide), true)
	expect.equality(grid.display_width(wide) <= 3, true)

	local pounds, pcut = grid.truncate(POUND:rep(10), 4)
	expect.equality(pcut, true)
	expect.equality(valid_utf8(pounds), true)
	expect.equality(pounds, POUND:rep(3) .. ELLIPSIS)

	-- A combining mark stays with the base character it decorates.
	local combined, ccut = grid.truncate(COMBINING:rep(3), 2)
	expect.equality(ccut, true)
	expect.equality(combined, COMBINING .. ELLIPSIS)

	-- Degenerate widths.
	expect.equality(grid.truncate("abc", 0), "")
	expect.equality(select(2, grid.truncate("abc", 0)), true)
	expect.equality(select(2, grid.truncate("", 0)), false)
	expect.equality(grid.truncate("abc", 3), "abc")
	expect.equality(select(2, grid.truncate("abc", 3)), false)

	-- Too narrow for the marker: cut anyway rather than overflow the column.
	local tight, tcut = grid.truncate(TICKET:rep(3), 1)
	expect.equality(tcut, true)
	expect.equality(tight, "")
	expect.equality(grid.truncate("abcd", 1, "..."), "a")
end

T["a truncated cell is marked over exactly the ellipsis bytes"] = function()
	local layout = grid.layout(fixture_columns(), fixture_cells(), { max_width = 10 })

	local row, col = 2, 3 -- the long description
	local range = layout.ranges[row][col]
	expect.equality(range.truncated, true)

	local line = layout.first_data_line + row - 1
	local found = nil
	for _, span in ipairs(layout.spans) do
		if span.hl_group == "SpacetimeTruncated" and span.line == line - 1 and span.end_col == range.end_col then
			found = span
		end
	end
	expect.no_equality(found, nil)
	expect.equality(found.start_col, range.end_col - #ELLIPSIS)

	local text = layout.lines[line]:sub(range.start_col + 1, range.end_col)
	expect.equality(text:sub(-#ELLIPSIS), ELLIPSIS)
	expect.equality(grid.display_width(text), 10)
	expect.equality(has_trailing_space(layout.lines), false)
end

T["byte offsets index the right cell for multibyte content"] = function()
	local columns, cells = fixture_columns(), fixture_cells()
	local layout = grid.layout(columns, cells, { max_width = 60 })

	for r = 1, #cells do
		local line = layout.lines[layout.first_data_line + r - 1]
		for c = 1, #columns do
			local range = layout.ranges[r][c]
			expect.equality(line:sub(range.start_col + 1, range.end_col), cells[r][c])
			expect.equality(range.truncated, false)
		end
	end

	-- Explicitly: the cells a `#s`-based offset would get wrong.
	expect.equality(layout.lines[2]:sub(layout.ranges[1][2].start_col + 1, layout.ranges[1][2].end_col), POUND)
	expect.equality(layout.lines[3]:sub(layout.ranges[2][2].start_col + 1, layout.ranges[2][2].end_col), TICKET)
end

T["header spans distinguish primary keys, and every group is a real one"] = function()
	local columns = {
		{ name = "id", pk = true },
		{ name = "name" },
		{ name = "note", align = "right" },
	}
	local cells = {
		{ "1", { text = "NULL", hl = "SpacetimeNull" }, { text = "x", hl = "SpacetimeSpecial" } },
		{ "2", "plain", "y" },
	}
	local layout = grid.layout(columns, cells)

	local header = {}
	for _, span in ipairs(layout.spans) do
		if span.line == 0 then
			header[#header + 1] = span.hl_group
		end
		expect.no_equality(highlights.links[span.hl_group], nil)
	end
	expect.equality(header, { "SpacetimePrimaryKey", "SpacetimeHeader", "SpacetimeHeader" })

	-- Data spans cover the cell text only, and only classified cells get one.
	local data = {}
	for _, span in ipairs(layout.spans) do
		if span.line > 0 then
			data[#data + 1] = span
		end
	end
	expect.equality(#data, 2)
	expect.equality(data[1].hl_group, "SpacetimeNull")
	expect.equality(data[1].start_col, layout.ranges[1][2].start_col)
	expect.equality(data[1].end_col, layout.ranges[1][2].end_col)
	expect.equality(data[2].hl_group, "SpacetimeSpecial")

	-- A right-aligned column pads on the left, so its cells end together.
	expect.equality(layout.ranges[1][3].end_col, layout.ranges[2][3].end_col)
	expect.equality(has_trailing_space(layout.lines), false)
end

T["degenerate inputs lay out without erroring"] = function()
	local empty = grid.layout({}, { { "ignored" } })
	expect.equality(empty.lines, {})
	expect.equality(empty.widths, {})
	expect.equality(empty.spans, {})
	expect.equality(empty.ranges, {})
	expect.equality(empty.first_data_line, 1)

	local no_rows = grid.layout({ { name = "id" } }, {})
	expect.equality(no_rows.lines, { "id" })
	expect.equality(no_rows.ranges, {})
	expect.equality(no_rows.first_data_line, 2)

	local headless = grid.layout({ { name = "id" } }, { { "1" } }, { header = false })
	expect.equality(headless.first_data_line, 1)
	expect.equality(headless.lines, { "1" })
	expect.equality(headless.widths, { 1 })
	expect.equality(headless.spans, {})

	expect.equality(grid.layout({ { name = "id" } }, {}, { header = false }).lines, {})
end

T["a ragged row fails loudly"] = function()
	local columns = { { name = "a" }, { name = "b" } }
	expect.error(function()
		grid.layout(columns, { { "1", "2" }, { "3" } })
	end)
	expect.error(function()
		grid.layout(columns, { { "1", "2", "3" } })
	end)
	expect.error(function()
		grid.layout(columns, { { "1", 2 } })
	end)
	expect.error(function()
		grid.layout(columns, { { "1", { hl = "SpacetimeNull" } } })
	end)
	expect.error(function()
		---@diagnostic disable-next-line: param-type-mismatch
		grid.layout("not a table", {})
	end)
end

T["no line the grid produces has trailing whitespace"] = function()
	local columns = { { name = "wide_header_name" }, { name = "b" } }
	local cells = {
		{ "x", "y" },
		{ "a longer value", "" },
		{ "", "" },
	}
	for _, opts in ipairs({ {}, { max_width = 4 }, { header = false }, { separator = " | " } }) do
		local layout = grid.layout(columns, cells, opts)
		expect.equality(has_trailing_space(layout.lines), false)
	end
end

return T
