-- The row grid: what `<CR>` on a table (or a view) in the sidebar produces.
--
-- One pipeline, and every stage of it already exists: `lib/sql.select_all`
-- builds the statement, `lib/client:sql` puts it on the wire, `lib/sql.parse`
-- flattens the envelope into columns and positional rows, `lib/value.format`
-- turns each cell into display text plus a highlight class, `ui/grid.layout`
-- lays those out into lines and byte-offset spans, and this module is the part
-- that owns the buffer. It lives under `ui/` and may therefore touch `vim.api`;
-- everything it calls under `lib/` may not.
--
-- Five things this file exists to get right:
--
-- 1. **One `nvim_buf_set_lines` for the whole grid.** The lines are assembled in
--    full — grid, `(no rows)` marker, error text, all of it — and written once.
--    Extmarks are then set only for the features `ui/grid.lua` reported a span
--    for: headers, primary keys, NULLs, the special newtypes and truncation
--    ellipses. That is a few hundred marks on a real table rather than one per
--    cell, which is the difference between a grid that renders and one that
--    stalls the editor.
-- 2. **Switching tables cancels the table you switched away from.** The sequence
--    guard is per key, and two tables are two keys, so `state.start` on the
--    second one would *not* touch the first: table A's in-flight fetch is
--    cancelled explicitly in `open`, which kills its handle and burns its token,
--    and A's response — already on the wire, possibly already queued inside
--    `vim.schedule` — is then dropped by `state.finish` instead of being painted
--    over B's rows (ROADMAP.md, risk 3).
-- 3. **Errors are buffer text.** A SQL error is an HTTP 400 whose body is
--    *plain text* (ROADMAP.md, verified fact 6); `lib/client.classify` passes it
--    through verbatim as `kind = "query"`, and it is rendered as-is. Nothing here
--    raises at the user: even a malformed response — a ragged row, which
--    `ui/grid.lua` deliberately treats as fatal — is caught and rendered as a
--    line of text rather than a stack trace under the cursor.
-- 4. **The result is cached under the same key the request registers with.**
--    `state.key("rows", db, table)` is both the in-flight key and the cache key,
--    so re-opening a table is a table lookup, and `r` on the sidebar drops it
--    through `state.cache_invalidate_db` along with the schema it belongs to.
-- 5. **The whole view is one table, rebuilt on open and repainted from.** Sort
--    and paging change `view` and call `M.render()`; neither needs to know
--    anything about buffers. `view.limit` and `view.offset` are already what
--    `lib/sql.select_all` is given, so paging is an offset change and a refetch
--    rather than a new code path. Sorting is smaller still: `view.order` says
--    which data row is painted on which line, so a sort rebuilds *that* — the
--    rows themselves are never touched, and `view.rank`, its inverse, is what
--    puts the cursor back on the row it was on rather than the line it was on.
--
-- Three things paging, yanking and the detail float then add to that:
--
-- 6. **A page is a `LIMIT`/`OFFSET` window, fetched under the *same* key.**
--    `]p`/`[p` move `view.offset` and refetch, and because the key is
--    `rows:<db>.<table>` — no offset in it — `state.start` supersedes the page
--    the user has already paged past. Holding `]p` down therefore leaves exactly
--    one live request, and every response it overtook is dropped by
--    `state.finish` rather than painted. The corollary is that only page one is
--    *cached*: the cache key is the same key, so caching page seven under it
--    would hand page seven's rows to the next plain `<CR>` on the table.
-- 7. **The grid truncates; the yank and the float do not.** `ui/grid.lua` cuts a
--    cell to 40 columns for the layout's sake, but that is a rendering, not the
--    data. `y` yanks what `lib/value.format` produced *before* the cut — the
--    exact digits of a 39-digit integer, the whole of a long string — `Y` yanks
--    the row as JSON built from the raw decoded values, and `K` floats every
--    column of the row untruncated. Truncation is therefore never lossy from the
--    user's point of view, which is what makes a 40-column budget acceptable.
-- 8. **The badge is line one, so every line index shifts with it.** It reports
--    the row count, the offset and the query's `total_duration_micros`. The
--    shift is applied once, in `build`, to the spans and to
--    `layout.first_data_line` — which every cursor mapping here is expressed
--    in — so nothing downstream has to know the badge exists.

local M = {}

---How many rows one `<CR>` asks for.
---
---There is no server-side cursor, so a page is a `LIMIT`/`OFFSET` window and
---this is its size — the step `]p` and `[p` move `view.offset` by. Exported
---rather than inlined so the code, the tests and a user reading `:help` all have
---one number to point at.
M.PAGE_SIZE = 100

local LOADING = "loading…"
local NO_ROWS = "(no rows)"
local NO_COLUMNS = "(no columns)"
local UNKNOWN_ERROR = "unknown error"

---What |spacetime.ui.rows.open()| needs to fetch and render a table.
---
---The connection is passed in rather than resolved here: `config.current()`
---reads the project config governing the *current* buffer, and by the time
---`<CR>` is pressed that buffer is our own `spacetime://sidebar` scratch. The
---sidebar resolved it from the user's buffer before the layout displaced it, and
---that is the connection this browsing session means.
---@class SpacetimeRowsRequest
---@field connection SpacetimeConnection Resolved by the sidebar, not by this module.
---@field database string Database name or identity, as it goes in the URL path.
---@field table_name string **Canonical** SQL name — `node.canonical`, not `node.name`.
---@field label? string Display name, for messages.
---@field entry? SpacetimeSchemaTable|SpacetimeSchemaView The schema entry, for primary keys.
---@field schema? SpacetimeSchema The database's schema, so a `Ref` in a column type resolves.

---Which column the grid is sorted by, and which way.
---@class SpacetimeRowsSort
---@field column integer 1-based index into `result.columns`.
---@field descending boolean

---The request plus everything the render needs. |spacetime.ui.rows.sort()| and
---|spacetime.ui.rows.page()| mutate this and call `M.render()`.
---@class SpacetimeRowsView : SpacetimeRowsRequest
---@field limit integer Rows asked for, i.e. `M.PAGE_SIZE`.
---@field offset integer Rows skipped: `M.PAGE_SIZE` per page turned.
---@field status "loading"|"ready"|"error"
---@field error? string Set when `status == "error"`.
---@field result? SpacetimeSqlResult Set when `status == "ready"`.
---@field order integer[] Display position -> index into `result.rows`.
---@field rank integer[] The inverse: index into `result.rows` -> display position.
---@field sort? SpacetimeRowsSort Absent until the user sorts.
---@field layout? SpacetimeGridLayout What was last painted, for mapping the cursor.

---What is on screen, or being fetched onto it. `nil` before the first open.
---@type SpacetimeRowsView|nil
local view = nil

---Point the display order back at the data order.
---
---Called wherever a result is *set*, cache or wire, so `order` and `rank` can
---never describe a different set of rows from the one on screen.
---@param current SpacetimeRowsView
local function reset_order(current)
	local sorting = require("spacetime.lib.sort")
	local result = current.result
	local rows = (type(result) == "table" and type(result.rows) == "table") and result.rows or {}
	current.order = sorting.identity(#rows)
	current.rank = sorting.rank(current.order)
	current.sort = nil
end

--------------------------------------------------------------------------------
-- Building the lines
--------------------------------------------------------------------------------

---The names of the primary-key columns of a table or view.
---
---Read from the schema entry rather than from the SQL response, which carries
---names and types but says nothing about keys. A view has no primary key, so it
---simply contributes an empty set.
---@param entry any
---@return table<string, boolean>
local function primary_keys(entry)
	local keys = {}
	if type(entry) ~= "table" or type(entry.columns) ~= "table" then
		return keys
	end
	for _, column in ipairs(entry.columns) do
		if type(column) == "table" and column.is_primary_key and type(column.name) == "string" then
			keys[column.name] = true
		end
	end
	return keys
end

---Message text as buffer lines, each marked in full.
---
---Split on newlines first: a server's plain-text SQL error is regularly several
---lines long, and folding it onto one (as `ui/grid.lua` must, for cells) would
---hide the part that says which token it choked on.
---@param message any
---@return string[] lines
---@return SpacetimeGridSpan[] spans
local function error_lines(message)
	local grid = require("spacetime.ui.grid")
	local text = (type(message) == "string" and message ~= "") and message or UNKNOWN_ERROR

	local lines, spans = {}, {}
	for _, raw in ipairs(vim.split("error: " .. text, "\n", { plain = true })) do
		local line = grid.sanitise(raw)
		lines[#lines + 1] = line
		if #line > 0 then
			spans[#spans + 1] = { line = #lines - 1, start_col = 0, end_col = #line, hl_group = "SpacetimeError" }
		end
	end
	return lines, spans
end

---The badge: how many rows are on screen, where in the table they start, and how
---long the server said the query took.
---
---The duration goes through `lib/value.duration`, which is the same renderer a
---`TimeDuration` column uses, so `167µs` here and `167µs` in a cell mean the
---same thing. A server that sent no `total_duration_micros` has it parsed as `0`
---and reads `0s`, which is honest: it is what we were told.
---@param current SpacetimeRowsView
---@param count integer Rows in the result.
---@return string
local function badge_text(current, count)
	local pieces = { ("%d row%s"):format(count, count == 1 and "" or "s") }
	if current.offset > 0 then
		pieces[#pieces + 1] = ("offset %d"):format(current.offset)
	end
	local result = current.result
	local micros = (type(result) == "table" and result.duration_micros) or 0
	pieces[#pieces + 1] = require("spacetime.lib.value").duration(micros) or "?"
	return table.concat(pieces, " · ")
end

---Every line of the view, and every span to mark on it.
---
---May raise — on a ragged row, which `ui/grid.layout` treats as fatal because it
---means a decode bug rather than odd data. `M.render` calls this through `pcall`
---and turns anything that escapes into buffer text.
---@param current SpacetimeRowsView
---@return string[] lines
---@return SpacetimeGridSpan[] spans
---@return SpacetimeGridLayout|nil layout Absent unless a grid was laid out.
local function build(current)
	if current.status == "loading" then
		return { LOADING }, {}
	end
	if current.status == "error" then
		return error_lines(current.error)
	end

	local result = current.result
	if type(result) ~= "table" then
		return { NO_ROWS }, {}
	end

	local keys = primary_keys(current.entry)
	local columns = {} ---@type SpacetimeGridColumn[]
	for i, column in ipairs(result.columns) do
		columns[i] = { name = column.name, pk = keys[column.name] == true }
	end
	if #columns == 0 then
		-- A mutation response has rows but no schema. `SELECT *` never lands here.
		return { NO_COLUMNS }, {}
	end

	-- The one place the sort is visible: rows are read through `order`, so a sort
	-- is a different *reading* of the same data rather than a different copy of it.
	local order = current.order
	if type(order) ~= "table" or #order ~= #result.rows then
		order = require("spacetime.lib.sort").identity(#result.rows)
	end

	local value = require("spacetime.lib.value")
	local cells = {} ---@type SpacetimeGridCell[][]
	for position, index in ipairs(order) do
		local row = result.rows[index]
		-- A row whose length disagrees with the schema is a decode bug, and one
		-- column out is worse than no grid: `lib/json.lua` keeps a JSON `null` as
		-- `vim.NIL` precisely so the lengths line up. Said plainly here rather than
		-- padded over, and caught by `M.render` so it reads as a line of text.
		if type(row) ~= "table" or #row ~= #columns then
			local count = type(row) == "table" and #row or 0
			error(("row %d has %d values, expected %d"):format(index, count, #columns), 0)
		end

		local out = {}
		for c, column in ipairs(result.columns) do
			-- Positional, and `vim.NIL` is left in place by `lib/json.lua`, so
			-- column `c` of the row really is column `c` of the schema.
			out[c] = value.cell(row[c], column.algebraic_type, current.schema)
		end
		cells[position] = out
	end

	local layout = require("spacetime.ui.grid").layout(columns, cells)
	local lines = layout.lines
	if #cells == 0 then
		-- The header alone reads as a rendering failure; say so instead.
		lines[#lines + 1] = NO_ROWS
	end

	-- Point 8 of the module header. The badge takes line one, so everything the
	-- grid reported in line numbers moves down by one — spans, and
	-- `first_data_line`, which is what every cursor mapping in this file is
	-- written in. Done here, once, rather than by each of `sort`, `y`, `Y` and `K`.
	local badge = badge_text(current, #result.rows)
	table.insert(lines, 1, badge)
	local spans = layout.spans
	for _, span in ipairs(spans) do
		span.line = span.line + 1
	end
	spans[#spans + 1] = { line = 0, start_col = 0, end_col = #badge, hl_group = "SpacetimeHeader" }
	layout.first_data_line = layout.first_data_line + 1

	return lines, spans, layout
end

--------------------------------------------------------------------------------
-- Painting
--------------------------------------------------------------------------------

---Paint the current view into the content buffer.
---
---A no-op when there is nothing to show or the content buffer does not exist:
---the view is still there, and the next `open()` renders it.
function M.render()
	local current = view
	if current == nil then
		return
	end

	local buffer = require("spacetime.ui.buffer")
	local bufnr = buffer.find(buffer.CONTENT_NAME)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	-- Idempotent, and cheap: a grid on screen always has its keys, including one
	-- painted into a buffer the user had already opened by hand.
	M.apply_keymaps(bufnr)

	local lines, spans, layout
	local ok, built_lines, built_spans, built_layout = pcall(build, current)
	if ok then
		lines, spans, layout = built_lines, built_spans, built_layout
	else
		-- Strip the "file:line: " a raise carries: the message is for a user, not
		-- for whoever is reading this file.
		lines, spans = error_lines((tostring(built_lines):gsub("^.-:%d+: ", "")))
	end
	-- `nil` for `loading…`, an error, or an empty result: there is no grid to map
	-- a cursor against, and `M.sort` says so by refusing to run.
	current.layout = layout

	-- The one write. Everything above assembles; nothing below adds a line.
	buffer.set_lines(bufnr, lines)

	local namespace = buffer.namespace()
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(bufnr, namespace, span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
end

--------------------------------------------------------------------------------
-- The cursor
--------------------------------------------------------------------------------

---The window showing the content buffer, and the buffer itself.
---@return integer|nil winid `nil` when the buffer exists but nothing is showing it.
---@return integer|nil bufnr
local function content_window()
	local buffer = require("spacetime.ui.buffer")
	local bufnr = buffer.find(buffer.CONTENT_NAME)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil, nil
	end
	return buffer.window_showing(bufnr), bufnr
end

---What the cursor in the content window is sitting on.
---@class SpacetimeRowsCursor
---@field view SpacetimeRowsView The view the row belongs to.
---@field result SpacetimeSqlResult The result it was rendered from.
---@field row any[] The raw row, exactly as `lib/sql.parse` decoded it.
---@field index integer Index into `result.rows` — the *data* row, not the line.
---@field column integer 1-based index into `result.columns`.

---The data row and grid column under the cursor, or `nil` when there is none.
---
---`nil` is every case in which a key bound to this must be a no-op: no view, one
---still loading or in error, a result with no columns, a content window nobody
---is showing, and a cursor on the badge, on the header or on the `(no rows)`
---marker. `order` is what turns a line into a data index, so this answers with
---the row the user is *looking at* whatever the grid is currently sorted by.
---@return SpacetimeRowsCursor|nil
local function cell_under_cursor()
	local current = view
	if current == nil or current.status ~= "ready" then
		return nil
	end
	local layout, result = current.layout, current.result
	if layout == nil or type(result) ~= "table" or #result.columns == 0 then
		return nil
	end

	local winid, bufnr = content_window()
	if winid == nil or bufnr == nil then
		return nil
	end

	local cursor = vim.api.nvim_win_get_cursor(winid)
	-- `first_data_line` already counts the badge, so this is buffer lines
	-- throughout. A line above the grid indexes `order` at zero or below and a
	-- line past it indexes past the end; both are `nil`, which is the answer.
	local index = current.order[cursor[1] - layout.first_data_line + 1]
	local row = index ~= nil and result.rows[index] or nil
	if index == nil or type(row) ~= "table" then
		return nil
	end

	local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
	local column = require("spacetime.ui.grid").column_at(line, cursor[2], layout.widths)
	return { view = current, result = result, row = row, index = index, column = column }
end

--------------------------------------------------------------------------------
-- Sorting
--------------------------------------------------------------------------------

---Sort the grid by the column under the cursor; press again to reverse it.
---
---What `s` in the content window does. Only the `order`/`rank` mapping is
---rebuilt — `result.rows` is never touched — and the comparator works on the
---**raw** values through `lib/sort`, not on the display strings: `9` sorts
---before `10`, and a Timestamp column sorts by micros rather than by the text it
---renders as. NULLs sort last whichever way round the column is.
---
---The cursor follows the row it was on, not the line it was on: the data index
---under it is read from `order` before the sort and looked back up in `rank`
---after it, and it stays in the column it was in.
---
---A no-op unless a grid is actually on screen.
function M.sort()
	local current = view
	if current == nil or current.status ~= "ready" then
		return
	end
	-- No layout means no grid: `loading…`, an error, or a result with no columns.
	local layout = current.layout
	local result = current.result
	if layout == nil or type(result) ~= "table" or #result.columns == 0 then
		return
	end

	local winid, bufnr = content_window()
	if winid == nil or bufnr == nil then
		return
	end

	local cursor = vim.api.nvim_win_get_cursor(winid)
	local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
	local column = require("spacetime.ui.grid").column_at(line, cursor[2], layout.widths)
	-- The data row under the cursor, read *before* the mapping changes under it.
	-- `nil` on the header and on the `(no rows)` marker, neither of which moves.
	local anchor = current.order[cursor[1] - layout.first_data_line + 1]

	-- Same column again reverses; a different column starts ascending, which is
	-- the direction a column the user has just picked is asked for.
	local descending = current.sort ~= nil and current.sort.column == column and not current.sort.descending
	current.sort = { column = column, descending = descending }

	local sorting = require("spacetime.lib.sort")
	local schema_column = result.columns[column]
	current.order = sorting.order(result.rows, column, {
		algebraic_type = type(schema_column) == "table" and schema_column.algebraic_type or nil,
		types = current.schema,
		descending = descending,
	})
	current.rank = sorting.rank(current.order)

	M.render()

	local painted = current.layout or layout
	local position = anchor ~= nil and current.rank[anchor] or nil
	if position == nil then
		return
	end
	local range = painted.ranges[position] and painted.ranges[position][column]
	-- `pcall`: a window the user closed between the two halves of this function
	-- is not an error worth reporting, and the sort itself has already landed.
	pcall(vim.api.nvim_win_set_cursor, winid, {
		painted.first_data_line + position - 1,
		range and range.start_col or 0,
	})
end

--------------------------------------------------------------------------------
-- Yanking
--------------------------------------------------------------------------------

---Put `text` in the register the user asked for.
---
---`vim.v.register` is the register the keystroke selected: `"` normally, the one
---a `"x` prefix named, and `+` or `*` when 'clipboard' is `unnamedplus` or
---`unnamed` — which is how a yank here honours that option without reading it.
---
---The confirmation reports a *size* rather than the text, unlike the sidebar's:
---a cell can be a whole JSON document, and the message area is not the place to
---print one.
---@param text any Anything but a non-empty string is nothing to yank.
---@param what string What is being yanked, for the confirmation message.
local function yank(text, what)
	local logger = require("spacetime.logger")
	if type(text) ~= "string" or text == "" then
		logger.warn("there is nothing to yank here")
		return
	end

	local register = vim.v.register
	if type(register) ~= "string" or register == "" then
		register = '"'
	end
	vim.fn.setreg(register, text)
	logger.info(("yanked %s (%d bytes) to register %s"):format(what, #text, register))
end

---The whole value of one cell, as `lib/value` renders it before the grid cuts it.
---@param at SpacetimeRowsCursor
---@param column integer 1-based index into `result.columns`.
---@return string text
---@return string|nil hl
local function cell_text(at, column)
	local schema_column = at.result.columns[column]
	return require("spacetime.lib.value").format(
		at.row[column],
		type(schema_column) == "table" and schema_column.algebraic_type or nil,
		at.view.schema
	)
end

---Yank the cell under the cursor — the value, not the grid's rendering of it.
---
---What `y` in the content window does. The text is what `lib/value.format`
---produced *before* `ui/grid.lua` cut it to fit the column, so a truncated cell
---still yanks in full and a 39-digit integer yanks to its last digit. A String
---column yanks the string itself, unquoted, byte for byte.
function M.yank_cell()
	local at = cell_under_cursor()
	if at == nil then
		require("spacetime.logger").warn("there is no cell under the cursor")
		return
	end
	yank((cell_text(at, at.column)), "cell")
end

---Yank the whole row under the cursor as a JSON object.
---
---What `Y` in the content window does. Keyed by column name, valued by the
---**raw** decoded values rather than by their display text, so it round-trips
---through any JSON parser. Two consequences worth knowing: a `null` stays
---`null`, and an integer too big for a double is a JSON *string*, because that
---is how `lib/json.lua` preserved its digits and rounding them into a number
---here would undo the whole point of it.
function M.yank_row()
	local at = cell_under_cursor()
	if at == nil then
		require("spacetime.logger").warn("there is no row under the cursor")
		return
	end

	local object = {}
	for c, column in ipairs(at.result.columns) do
		local raw = at.row[c]
		-- `vim.NIL` is what a JSON `null` decoded to, and what it encodes back to.
		object[column.name] = raw == nil and vim.NIL or raw
	end

	local ok, encoded = pcall(vim.json.encode, object)
	if not ok or type(encoded) ~= "string" then
		require("spacetime.logger").warn("this row cannot be encoded as JSON")
		return
	end
	yank(encoded, "row")
end

--------------------------------------------------------------------------------
-- The row-detail float
--------------------------------------------------------------------------------

-- At most one is open at a time; opening a second closes the first. Tracked
-- rather than looked up, because the float has no buffer name to find it by.
local detail_win = nil ---@type integer|nil

---Close the row-detail float, if one is open.
---
---`pcall`: a window the user has already closed by other means is not an error,
---and a stale handle must not raise out of a keymap.
local function close_detail()
	if detail_win ~= nil and vim.api.nvim_win_is_valid(detail_win) then
		pcall(vim.api.nvim_win_close, detail_win, true)
	end
	detail_win = nil
end

---Show every column of the row under the cursor, untruncated, in a float.
---
---What `K` in the content window does, and the reason a 40-column grid is not
---lossy: this is where the whole value lives. Values are still folded onto one
---line each — a newline in a String would otherwise break the column-per-line
---correspondence — but nothing is cut, and 'wrap' is on so a long one is all
---there.
---
---Focus moves into the float; `q` or `<Esc>` closes it.
function M.detail()
	local at = cell_under_cursor()
	if at == nil then
		require("spacetime.logger").warn("there is no row under the cursor")
		return
	end

	local buffer = require("spacetime.ui.buffer")
	local grid = require("spacetime.ui.grid")

	local names, name_width = {}, 0
	for c, column in ipairs(at.result.columns) do
		names[c] = grid.sanitise(column.name)
		name_width = math.max(name_width, grid.display_width(names[c]))
	end

	local lines, spans, width = {}, {}, 0
	for c = 1, #at.result.columns do
		local text, hl = cell_text(at, c)
		text = grid.sanitise(text)
		local gap = string.rep(" ", name_width - grid.display_width(names[c]) + 2)
		lines[c] = names[c] .. gap .. text
		width = math.max(width, grid.display_width(lines[c]))

		local start_col = #names[c] + #gap
		spans[#spans + 1] = { line = c - 1, start_col = 0, end_col = #names[c], hl_group = "SpacetimeHeader" }
		if hl then
			spans[#spans + 1] = { line = c - 1, start_col = start_col, end_col = #lines[c], hl_group = hl }
		end
	end

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].filetype = buffer.CONTENT_FILETYPE
	buffer.set_lines(bufnr, lines)
	vim.bo[bufnr].modifiable = false
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(bufnr, buffer.namespace(), span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	close_detail()
	local winid = vim.api.nvim_open_win(bufnr, true, {
		relative = "cursor",
		row = 1,
		col = 0,
		width = math.max(20, math.min(width + 1, math.max(20, vim.o.columns - 8))),
		height = math.max(1, math.min(#lines, math.max(1, vim.o.lines - 6))),
		style = "minimal",
		border = "rounded",
		title = " " .. (at.view.label or at.view.table_name) .. " ",
	})
	detail_win = winid
	vim.wo[winid].wrap = true

	-- Set directly rather than through a table-driven loop: two keys, both
	-- closing the same window, are not a key map worth documenting twice.
	for _, lhs in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", lhs, close_detail, {
			buffer = bufnr,
			nowait = true,
			silent = true,
			desc = "spacetime: close the row detail",
		})
	end
end

--------------------------------------------------------------------------------
-- Keymaps
--------------------------------------------------------------------------------

---@class SpacetimeRowsKeymap
---@field keys string[]
---@field desc string
---@field action fun()

---Every key the content window binds while it is showing a grid. One table, as
---in `ui/sidebar.lua`, so the mappings and the documentation cannot drift apart.
---@type SpacetimeRowsKeymap[]
M.KEYMAPS = {
	{
		keys = { "s" },
		desc = "sort by the column under the cursor (again to reverse)",
		action = function()
			M.sort()
		end,
	},
	{
		keys = { "]p" },
		desc = "next page",
		action = function()
			M.page(1)
		end,
	},
	{
		keys = { "[p" },
		desc = "previous page",
		action = function()
			M.page(-1)
		end,
	},
	{
		keys = { "y" },
		desc = "yank the cell under the cursor, untruncated",
		action = function()
			M.yank_cell()
		end,
	},
	{
		keys = { "Y" },
		desc = "yank the row as JSON",
		action = function()
			M.yank_row()
		end,
	},
	{
		keys = { "K" },
		desc = "show the whole row, every column untruncated",
		action = function()
			M.detail()
		end,
	},
}

---Bind every content-window key, buffer-locally.
---
---Re-applied on every render: `vim.keymap.set` overwrites, so this is idempotent.
---@param bufnr integer The content buffer.
function M.apply_keymaps(bufnr)
	for _, map in ipairs(M.KEYMAPS) do
		for _, lhs in ipairs(map.keys) do
			vim.keymap.set("n", lhs, map.action, {
				buffer = bufnr,
				nowait = true,
				silent = true,
				desc = "spacetime: " .. map.desc,
			})
		end
	end
end

--------------------------------------------------------------------------------
-- Fetching
--------------------------------------------------------------------------------

---Run the view's query and repaint when it lands.
---
---The handle is registered with `state.start` *before* the request goes out: a
---stubbed transport completes inside the call, and a callback that ran before
---`start` returned would have no token to present.
---@param current SpacetimeRowsView
local function fetch(current)
	local state = require("spacetime.state")
	local key = state.key("rows", current.database, current.table_name)
	local query = require("spacetime.lib.sql").select_all(current.table_name, current.limit, current.offset)
	local client = require("spacetime.lib.client").new(current.connection)

	local handle = nil ---@type SpacetimeHttpHandle|nil
	local seq = state.start(key, {
		kill = function()
			if handle then
				handle.kill()
			end
		end,
	})

	handle = client:sql(current.database, query, function(err, result)
		-- A response that lost its token belongs to a table the user has switched
		-- away from; painting it now would undo what they did.
		if not state.finish(key, seq) then
			return
		end
		-- Belt and braces: the token check already covers this, but a response
		-- must never be able to mutate a view it does not belong to.
		if current ~= view then
			return
		end

		if err then
			current.status = "error"
			current.error = err.message
		elseif result then
			current.status = "ready"
			current.result = result
			reset_order(current)
			-- Only page one. The cache key *is* the request key — no offset in it,
			-- which is what lets a held-down `]p` supersede itself — so caching a
			-- later page under it would hand those rows to the next `<CR>` on the
			-- table. See point 6 of the module header.
			if current.offset == 0 then
				state.cache_set(key, result)
			end
		else
			current.status = "error"
			current.error = "no result"
		end
		M.render()
	end)
end

---Turn one page, forwards or backwards, and refetch.
---
---What `]p` and `[p` in the content window do. A page is a `LIMIT`/`OFFSET`
---window of `M.PAGE_SIZE` rows, so turning one is an offset change and a
---refetch; the request goes out under the same key as every other page of this
---table, so holding `]p` down leaves one live request and drops the responses it
---overtook (point 6 of the module header).
---
---Two no-ops, both silent, because a key that beeps at the ends of a table is
---worse than one that stops: `[p` on page one would be a negative offset, and
---`]p` on a page the server returned short is a page that cannot exist.
---
---The new page arrives in the order the server sent it: the sort is a reading of
---the rows in hand, and those rows are about to be replaced.
---@param direction integer Negative for the previous page, positive for the next.
function M.page(direction)
	local current = view
	if current == nil or type(direction) ~= "number" or direction == 0 then
		return
	end

	local step = direction < 0 and -current.limit or current.limit
	local offset = current.offset + step
	if offset < 0 then
		return
	end

	local result = current.result
	local short = current.status == "ready" and type(result) == "table" and #result.rows < current.limit
	if step > 0 and short then
		return
	end

	current.offset = offset
	current.status = "loading"
	current.error = nil
	current.result = nil
	reset_order(current)

	M.render()
	fetch(current)
end

---Fetch and render a table's — or a view's — rows in the content window.
---
---What `<CR>` on a table node does. Idempotent in the useful sense: opening the
---same table twice serves the second one from the session cache, and `r` on the
---sidebar is the only thing that expires it.
---@param request SpacetimeRowsRequest
function M.open(request)
	vim.validate("request", request, "table")
	vim.validate("connection", request.connection, "table")
	vim.validate("database", request.database, "string")
	vim.validate("table_name", request.table_name, "string")

	if request.database == "" or request.table_name == "" then
		-- A node with no name is data we cannot query, not a programming error.
		require("spacetime.logger").warn("there is no table to open here")
		return
	end

	local state = require("spacetime.state")
	local key = state.key("rows", request.database, request.table_name)

	-- Point 2 of the module header: a different table is a different key, so
	-- `state.start` below would leave the previous fetch running and its token
	-- live. Cancel it by hand.
	if view ~= nil then
		local previous = state.key("rows", view.database, view.table_name)
		if previous ~= key then
			state.cancel(previous)
		end
	end

	view = {
		connection = request.connection,
		database = request.database,
		table_name = request.table_name,
		label = request.label,
		entry = request.entry,
		schema = request.schema,
		limit = M.PAGE_SIZE,
		offset = 0,
		status = "loading",
		order = {},
		rank = {},
	}

	local cached = state.cache_get(key)
	if type(cached) == "table" then
		-- Nothing below this fetches, so nothing below it would supersede a page of
		-- *this* table still on the wire — a `]p` the user pressed before going back
		-- to the sidebar. Burn its token by hand, or it repaints page one with page
		-- two's rows.
		state.cancel(key)
		view.status = "ready"
		view.result = cached
		-- A cached result is a *new* view of it: re-opening a table you had sorted
		-- shows it in data order again, which is what "open this table" means.
		reset_order(view)
		M.render()
		return
	end

	M.render()
	fetch(view)
end

return M
