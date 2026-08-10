-- Row-grid layout: columns and cells in, lines plus highlight spans out.
--
-- This module is "pure" in the referential sense — data in, data out, with no
-- buffers, windows, extmarks, `vim.api` or global state — but it is not pure in
-- the `lib/` sense, and that is why it lives under `ui/`. Column widths can only
-- be computed with `vim.fn.strdisplaywidth`: `#s` is the byte count, and the
-- live data has `£` (1 column, 2 bytes) and `🎟` (2 columns, 4 bytes) in the same
-- table. Truncation likewise needs `vim.fn.strcharpart` / `vim.fn.strchars` so a
-- multibyte sequence is never split down the middle. Those three functions are
-- the whole of this module's contact with Neovim.
--
-- Every cell (and every header name) is sanitised first: one line per row is the
-- invariant that every index mapping here depends on, and a String column
-- holding a newline would otherwise break it silently. Tabs are replaced for the
-- same reason — `strdisplaywidth("\t")` is 8 because a tab expands against
-- `'tabstop'`, so an unsanitised tab would make the whole layout depend on an
-- editor option.
--
-- Known and deliberately not fixed: `strdisplaywidth` for emoji depends on
-- `'ambiwidth'` and on the terminal's own width tables, so a column of emoji may
-- look a cell out in some terminals. That is cosmetic only — every index this
-- module reports is a byte offset, so extmarks and yanks stay on the right cell
-- regardless of what the terminal thinks the glyph is worth.
--
-- All offsets returned are 0-based byte offsets, ready for
-- `nvim_buf_set_extmark` without further conversion.

---@class SpacetimeGridColumn
---@field name string
---@field pk? boolean Render the header as `SpacetimePrimaryKey`.
---@field align? "left"|"right" Defaults to `"left"`.

---@class SpacetimeGridCell
---@field text string
---@field hl? string Highlight group for the cell text, e.g. `"SpacetimeNull"`.

---@class SpacetimeGridOpts
---@field max_width? integer Maximum display columns per column. Default 40.
---@field separator? string Column separator. Default two spaces.
---@field ellipsis? string Truncation marker. Default `"…"`.
---@field header? boolean Emit a header line. Default true.

---@class SpacetimeGridSpan
---@field line integer 0-based index into `lines`.
---@field start_col integer 0-based byte offset.
---@field end_col integer 0-based byte offset, exclusive.
---@field hl_group string

---@class SpacetimeGridRange
---@field start_col integer 0-based byte offset of the cell text, padding excluded.
---@field end_col integer 0-based byte offset, exclusive.
---@field truncated boolean

---@class SpacetimeGridLayout
---@field lines string[]
---@field widths integer[] Final display width of each column.
---@field first_data_line integer 1-based index into `lines`: 2 with a header, 1 without.
---@field spans SpacetimeGridSpan[]
---@field ranges SpacetimeGridRange[][] `ranges[data_row][col]`, indexed by `cells`, not by `lines`.

local M = {}

local DEFAULT_MAX_WIDTH = 40
local DEFAULT_SEPARATOR = "  "
local DEFAULT_ELLIPSIS = "…"

---Display width of `s` in screen columns.
---@param s string
---@return integer
function M.display_width(s)
	return vim.fn.strdisplaywidth(s)
end

---Fold `s` onto a single line with no control characters: `\r\n` and `\n` become
---`␊`, every other C0 control (tab included) and `DEL` become `·`. Both
---replacements are one display column wide.
---@param s string
---@return string
function M.sanitise(s)
	-- Bound to a local first, so gsub's replacement count never leaks to the
	-- caller as a second return value.
	local out = s:gsub("\r\n", "\n"):gsub("\n", "␊"):gsub("[%z\1-\9\11-\31\127]", "·")
	return out
end

---Longest prefix of `s` that fits in `w` display columns, by binary search on
---character count. Display width is monotone non-decreasing in the character
---count, so the search is sound. `skipcc = 1` on both calls keeps a combining
---mark attached to its base character — without it the default counts the mark
---as a character of its own and the prefix can end between the two.
---@param s string
---@param w integer
---@return string
local function fit(s, w)
	local lo, hi = 0, vim.fn.strchars(s, 1)
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if vim.fn.strdisplaywidth(vim.fn.strcharpart(s, 0, mid, 1)) <= w then
			lo = mid
		else
			hi = mid - 1
		end
	end
	return vim.fn.strcharpart(s, 0, lo, 1)
end

---Truncate `s` to at most `width` display columns, appending `ellipsis` when it
---does not fit. Never splits a multibyte character.
---@param s string
---@param width integer Display columns available.
---@param ellipsis? string Default `"…"`.
---@return string text
---@return boolean truncated Whether anything was dropped.
function M.truncate(s, width, ellipsis)
	ellipsis = ellipsis or DEFAULT_ELLIPSIS
	if width <= 0 then
		return "", s ~= ""
	end
	if M.display_width(s) <= width then
		return s, false
	end

	local budget = width - M.display_width(ellipsis)
	if budget <= 0 then
		-- No room for the marker; a truncated cell beats an overflowing one.
		return fit(s, width), true
	end
	return fit(s, budget) .. ellipsis, true
end

---Which grid column a byte offset on `line` falls in.
---
---The inverse of the layout, and the one thing "sort by the column under the
---cursor" needs. It works off *display* columns rather than byte ranges on
---purpose: the byte offsets of a cell differ line by line (`£` is 2 bytes, `🎟`
---is 4), but the display column a column starts at is the same on every line,
---header included — which is precisely the invariant `layout` maintains. So the
---answer is the same whether the cursor is on the header or on a row.
---
---A column owns its own width plus the separator that follows it, so a cursor
---parked in the padding after a cell still means that cell. The last column owns
---everything past its start, so a cursor beyond the end of a short line — Neovim
---allows one past the last byte — lands on it rather than nowhere.
---@param line string The line the cursor is on.
---@param col integer 0-based byte offset, as `nvim_win_get_cursor` reports it.
---@param widths integer[] `layout.widths`.
---@param opts? SpacetimeGridOpts Only `separator` is read.
---@return integer # 1-based column index, clamped to `1..#widths`.
function M.column_at(line, col, widths, opts)
	local separator = (opts and opts.separator) or DEFAULT_SEPARATOR
	local gap = M.display_width(separator)

	-- Back the offset off to a character boundary first. A cursor never sits
	-- inside a multibyte sequence, but an offset computed by arithmetic can, and
	-- `strdisplaywidth` charges four columns for the `<c2>` an orphaned lead byte
	-- displays as — enough to report the next column along.
	local boundary = col
	while boundary > 0 do
		local byte = line:byte(boundary + 1)
		if byte == nil or byte < 0x80 or byte >= 0xC0 then
			break
		end
		boundary = boundary - 1
	end

	local cursor = M.display_width(line:sub(1, boundary))

	local at = 0
	for c = 1, #widths - 1 do
		at = at + widths[c] + gap
		if cursor < at then
			return c
		end
	end
	return math.max(1, #widths)
end

---Normalise a cell to its text and optional highlight group.
---@param cell string|SpacetimeGridCell
---@param row integer
---@param col integer
---@return string text
---@return string? hl
local function cell_parts(cell, row, col)
	if type(cell) == "string" then
		return cell, nil
	end
	if type(cell) == "table" and type(cell.text) == "string" then
		return cell.text, cell.hl
	end
	error(("spacetime.ui.grid: cell at row %d, column %d is neither a string nor {text = string}"):format(row, col))
end

---Lay a grid out into lines, column widths, per-cell byte ranges and highlight
---spans. Cells are given row-major (`cells[row][col]`); a cell is either a bare
---string or a `SpacetimeGridCell`.
---
---A row whose length differs from `#columns` raises: SQL rows are positional and
---`lib/json.lua` keeps `vim.NIL` in place precisely so the lengths line up, so a
---ragged row means a decode bug and must fail loudly rather than render one
---column out.
---@param columns SpacetimeGridColumn[]
---@param cells (string|SpacetimeGridCell)[][]
---@param opts? SpacetimeGridOpts
---@return SpacetimeGridLayout
function M.layout(columns, cells, opts)
	vim.validate("columns", columns, "table")
	vim.validate("cells", cells, "table")
	vim.validate("opts", opts, "table", true)

	opts = opts or {}
	local max_width = opts.max_width or DEFAULT_MAX_WIDTH
	local separator = opts.separator or DEFAULT_SEPARATOR
	local ellipsis = opts.ellipsis or DEFAULT_ELLIPSIS
	local want_header = opts.header ~= false

	local ncols = #columns
	local lines = {} ---@type string[]
	local spans = {} ---@type SpacetimeGridSpan[]
	local ranges = {} ---@type SpacetimeGridRange[][]
	local widths = {} ---@type integer[]
	local first_data_line = want_header and 2 or 1

	if ncols == 0 then
		return { lines = {}, widths = {}, spans = {}, ranges = {}, first_data_line = 1 }
	end

	-- Pass 1: sanitise everything once, keeping text and display width in
	-- parallel arrays so no width is ever computed twice.
	local head_text, head_width = {}, {}
	for c, column in ipairs(columns) do
		if type(column.name) ~= "string" then
			error(("spacetime.ui.grid: column %d has no name"):format(c))
		end
		head_text[c] = M.sanitise(column.name)
		head_width[c] = M.display_width(head_text[c])
	end

	local text, width, hl = {}, {}, {}
	for r, row in ipairs(cells) do
		if type(row) ~= "table" then
			error(("spacetime.ui.grid: row %d is not a table"):format(r))
		end
		if #row ~= ncols then
			error(("spacetime.ui.grid: row %d has %d cells, expected %d"):format(r, #row, ncols))
		end
		text[r], width[r], hl[r] = {}, {}, {}
		for c = 1, ncols do
			local cell_text, cell_hl = cell_parts(row[c], r, c)
			text[r][c] = M.sanitise(cell_text)
			width[r][c] = M.display_width(text[r][c])
			hl[r][c] = cell_hl
		end
	end

	for c = 1, ncols do
		local widest = want_header and head_width[c] or 0
		for r = 1, #cells do
			if width[r][c] > widest then
				widest = width[r][c]
			end
		end
		widths[c] = math.max(0, math.min(max_width, widest))
	end

	-- Pass 2: anything wider than its column is truncated to fit. Headers too —
	-- a header longer than `max_width` would otherwise push its column out.
	local head_cut = {}
	for c = 1, ncols do
		head_cut[c] = false
		if head_width[c] > widths[c] then
			head_text[c], head_cut[c] = M.truncate(head_text[c], widths[c], ellipsis)
			head_width[c] = M.display_width(head_text[c])
		end
	end

	local cut = {}
	for r = 1, #cells do
		cut[r] = {}
		for c = 1, ncols do
			cut[r][c] = false
			if width[r][c] > widths[c] then
				text[r][c], cut[r][c] = M.truncate(text[r][c], widths[c], ellipsis)
				width[r][c] = M.display_width(text[r][c])
			end
		end
	end

	-- The marker is only really there when `truncate` had room to append it;
	-- below its own width it drops the marker and just cuts.
	local function marker_bytes(s, truncated)
		if not truncated or #ellipsis == 0 or #s < #ellipsis then
			return 0
		end
		return s:sub(-#ellipsis) == ellipsis and #ellipsis or 0
	end

	---Assemble one line and report each cell's byte range.
	---
	---The line stops at the end of the last non-empty cell: padding is only ever
	---emitted *between* cells, so no separator or run of pad spaces is left
	---dangling at the end (trailing whitespace would land in every yanked row).
	---Ranges for the trailing empty cells collapse onto that point, which keeps
	---them inside the line and therefore valid as extmark positions.
	---@param row_text string[]
	---@param row_width integer[]
	---@return string
	---@return { start_col: integer, end_col: integer }[]
	local function assemble(row_text, row_width)
		local last = 0
		for c = 1, ncols do
			if #row_text[c] > 0 then
				last = c
			end
		end
		if last == 0 then
			local cols = {}
			for c = 1, ncols do
				cols[c] = { start_col = 0, end_col = 0 }
			end
			return "", cols
		end

		local pieces, cursor, cols = {}, 0, {}
		for c = 1, last do
			if c > 1 then
				pieces[#pieces + 1] = separator
				cursor = cursor + #separator
			end

			local pad = math.max(0, widths[c] - row_width[c])
			local right = columns[c].align == "right"
			if right and pad > 0 then
				pieces[#pieces + 1] = string.rep(" ", pad)
				cursor = cursor + pad
			end

			local start_col = cursor
			pieces[#pieces + 1] = row_text[c]
			cursor = cursor + #row_text[c]
			cols[c] = { start_col = start_col, end_col = cursor }

			if not right and pad > 0 and c < last then
				pieces[#pieces + 1] = string.rep(" ", pad)
				cursor = cursor + pad
			end
		end
		for c = last + 1, ncols do
			cols[c] = { start_col = cursor, end_col = cursor }
		end
		return table.concat(pieces), cols
	end

	if want_header then
		local line, cols = assemble(head_text, head_width)
		lines[1] = line
		for c = 1, ncols do
			spans[#spans + 1] = {
				line = 0,
				start_col = cols[c].start_col,
				end_col = cols[c].end_col,
				hl_group = columns[c].pk and "SpacetimePrimaryKey" or "SpacetimeHeader",
			}
			local marker = marker_bytes(head_text[c], head_cut[c])
			if marker > 0 then
				spans[#spans + 1] = {
					line = 0,
					start_col = cols[c].end_col - marker,
					end_col = cols[c].end_col,
					hl_group = "SpacetimeTruncated",
				}
			end
		end
	end

	for r = 1, #cells do
		local index = first_data_line + r - 1
		local line, cols = assemble(text[r], width[r])
		lines[index] = line
		ranges[r] = {}
		for c = 1, ncols do
			ranges[r][c] = { start_col = cols[c].start_col, end_col = cols[c].end_col, truncated = cut[r][c] }
			-- No span for an unclassified, untruncated cell: the roadmap's budget
			-- is a few hundred extmarks for the grid, not one per cell.
			if hl[r][c] then
				spans[#spans + 1] = {
					line = index - 1,
					start_col = cols[c].start_col,
					end_col = cols[c].end_col,
					hl_group = hl[r][c],
				}
			end
			local marker = marker_bytes(text[r][c], cut[r][c])
			if marker > 0 then
				spans[#spans + 1] = {
					line = index - 1,
					start_col = cols[c].end_col - marker,
					end_col = cols[c].end_col,
					hl_group = "SpacetimeTruncated",
				}
			end
		end
	end

	return {
		lines = lines,
		widths = widths,
		first_data_line = first_data_line,
		spans = spans,
		ranges = ranges,
	}
end

return M
