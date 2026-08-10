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
--    (task 28) and paging (task 29) change `view` and call `M.render()`; neither
--    needs to know anything about buffers. `view.limit` and `view.offset` are
--    already what `lib/sql.select_all` is given, so paging is an offset change
--    and a refetch rather than a new code path.

local M = {}

---How many rows one `<CR>` asks for.
---
---There is no server-side cursor, so a page is a `LIMIT`/`OFFSET` window and
---this is its size. Task 29 puts `]p`/`[p` on `view.offset`; until then the
---first page is the whole story, and a table with more rows than this shows its
---first `PAGE_SIZE`. Exported rather than inlined so that task, and a user
---reading `:help`, both have one number to point at.
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

---The request plus everything the render needs. Tasks 28 and 29 mutate this and
---call `M.render()`.
---@class SpacetimeRowsView : SpacetimeRowsRequest
---@field limit integer Rows asked for, i.e. `M.PAGE_SIZE`.
---@field offset integer Rows skipped. Always 0 until task 29.
---@field status "loading"|"ready"|"error"
---@field error? string Set when `status == "error"`.
---@field result? SpacetimeSqlResult Set when `status == "ready"`.

---What is on screen, or being fetched onto it. `nil` before the first open.
---@type SpacetimeRowsView|nil
local view = nil

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

---Every line of the view, and every span to mark on it.
---
---May raise — on a ragged row, which `ui/grid.layout` treats as fatal because it
---means a decode bug rather than odd data. `M.render` calls this through `pcall`
---and turns anything that escapes into buffer text.
---@param current SpacetimeRowsView
---@return string[] lines
---@return SpacetimeGridSpan[] spans
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

	local value = require("spacetime.lib.value")
	local cells = {} ---@type SpacetimeGridCell[][]
	for r, row in ipairs(result.rows) do
		-- A row whose length disagrees with the schema is a decode bug, and one
		-- column out is worse than no grid: `lib/json.lua` keeps a JSON `null` as
		-- `vim.NIL` precisely so the lengths line up. Said plainly here rather than
		-- padded over, and caught by `M.render` so it reads as a line of text.
		if type(row) ~= "table" or #row ~= #columns then
			local count = type(row) == "table" and #row or 0
			error(("row %d has %d values, expected %d"):format(r, count, #columns), 0)
		end

		local out = {}
		for c, column in ipairs(result.columns) do
			-- Positional, and `vim.NIL` is left in place by `lib/json.lua`, so
			-- column `c` of the row really is column `c` of the schema.
			out[c] = value.cell(row[c], column.algebraic_type, current.schema)
		end
		cells[r] = out
	end

	local layout = require("spacetime.ui.grid").layout(columns, cells)
	local lines = layout.lines
	if #cells == 0 then
		-- The header alone reads as a rendering failure; say so instead.
		lines[#lines + 1] = NO_ROWS
	end
	return lines, layout.spans
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

	local lines, spans
	local ok, built_lines, built_spans = pcall(build, current)
	if ok then
		lines, spans = built_lines, built_spans
	else
		-- Strip the "file:line: " a raise carries: the message is for a user, not
		-- for whoever is reading this file.
		lines, spans = error_lines((tostring(built_lines):gsub("^.-:%d+: ", "")))
	end

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
			state.cache_set(key, result)
		else
			current.status = "error"
			current.error = "no result"
		end
		M.render()
	end)
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
	}

	local cached = state.cache_get(key)
	if type(cached) == "table" then
		view.status = "ready"
		view.result = cached
		M.render()
		return
	end

	M.render()
	fetch(view)
end

return M
