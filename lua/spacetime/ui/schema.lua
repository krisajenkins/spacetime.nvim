-- The schema detail view: what `:SpacetimeSchema [db.]tbl` paints into the
-- content window.
--
-- One table's shape — its columns with their resolved types, its indexes and its
-- constraints — followed by the whole database's reducers. It lives under `ui/`
-- and may therefore touch `vim.api`; everything it reads under `lib/` may not.
-- `lib/schema.lua` has already normalised both wire versions into one model and
-- `lib/value.label` already turns an `AlgebraicType` into a name, so this file
-- is layout and nothing else.
--
-- Five things this file exists to get right:
--
-- 1. **Both spellings, wherever they differ.** The module was written as
--    `ledgerEntry` and SQL knows it as `ledger_entry`; the same goes for
--    `onConnect` / `on_connect`. Both are shown — `ledgerEntry (ledger_entry)` —
--    because the SQL endpoint accepts either, so the source spelling is a
--    readability win rather than a trap. Where the two coincide (every v9
--    schema, and most v10 names) only the one name is printed.
-- 2. **Unknown visibility means callable, and renders no marker.** `visibility`
--    is a v10 field; on a v9 fallback it is `nil` for every reducer. Marking
--    those `Private` would tell the user their reducers cannot be called when
--    all we actually know is that the server is too old to say. So the access
--    column only exists when at least one reducer carries a visibility, and a v9
--    schema lists its reducers with no marker at all (`lib/schema.is_callable`
--    reads the same field the same way).
-- 3. **Nothing is truncated.** `ui/grid.lua` cuts a cell to 40 columns because
--    the row grid has `y` and `K` to recover the rest with; this view has
--    neither, and a type signature cut mid-generic is worse than a long line.
--    The grid is used for its alignment and its byte offsets only, with the
--    width budget effectively lifted.
-- 4. **Errors are buffer text.** A failed schema request, a table the module
--    does not have, a raise from the layout itself: all three are rendered as
--    lines, never as a stack trace under the cursor.
-- 5. **The content buffer is shared with the row grid.** `open` claims it
--    through `ui/buffer.claim_content`, so a rows response still on the wire
--    does not paint over the schema when it lands, and the render applies this
--    view's (empty) key map through `ui/keys`, which takes the grid's `s`, `]p`,
--    `y`, `Y` and `K` back off the buffer. A stale `]p` must not page a grid
--    that is no longer displayed.

local M = {}

---The name this view claims the content buffer under.
M.OWNER = "schema"

---Every key the content window binds while it is showing a schema.
---
---Deliberately none: the schema view is text, with nothing to page, sort or
---filter. (The sidebar's `s` is what opens it; that is a mapping in the sidebar
---buffer, not in this one.) The table is still here, and still applied on every
---render, because applying it is what *unbinds* the row grid's keys — see point
---5 of the module header.
---@type SpacetimeKeymap[]
M.KEYMAPS = {}

local LOADING = "loading…"
local UNKNOWN_ERROR = "unknown error"
local NONE = "(none)"
local INDENT = "  "

-- Wide enough that nothing real is ever cut, and a backstop against a
-- pathological generated type name rather than a layout decision. See point 3 of
-- the module header.
local MAX_WIDTH = 400

---What |spacetime.ui.schema.open()| needs.
---
---The connection is passed in rather than resolved here, for the same reason as
---the row grid's: `config.current()` reads the project config governing the
---*current* buffer, and by the time this runs that buffer may be one of our own
---scratch buffers. The caller resolves it before the layout displaces anything.
---@class SpacetimeSchemaRequest
---@field connection SpacetimeConnection Resolved by the caller, not by this module.
---@field database string Database name or identity, as it goes in the URL path.
---@field table_name string Either spelling — `ledgerEntry` or `ledger_entry` both find it.

---The request plus what has become of it.
---@class SpacetimeSchemaDisplay : SpacetimeSchemaRequest
---@field status "loading"|"ready"|"error"
---@field error? string Set when `status == "error"`.
---@field schema? SpacetimeSchema Set when `status == "ready"`.

---What is on screen, or being fetched onto it. `nil` before the first open.
---@type SpacetimeSchemaDisplay|nil
local view = nil

--------------------------------------------------------------------------------
-- Building the lines
--------------------------------------------------------------------------------

---The lines of the view, and the spans to mark on them, as they are assembled.
---@class SpacetimeSchemaSink
---@field lines string[]
---@field spans SpacetimeGridSpan[]

---@return SpacetimeSchemaSink
local function new_sink()
	return { lines = {}, spans = {} }
end

---Append one line, optionally marked in full.
---@param sink SpacetimeSchemaSink
---@param text string
---@param hl? string
local function push(sink, text, hl)
	local line = require("spacetime.ui.grid").sanitise(text)
	sink.lines[#sink.lines + 1] = line
	if hl ~= nil and #line > 0 then
		sink.spans[#sink.spans + 1] = {
			line = #sink.lines - 1,
			start_col = 0,
			end_col = #line,
			hl_group = hl,
		}
	end
end

---Append a section: a blank line, a heading, then a grid of rows indented under
---it — or `(none)` when the section is empty.
---
---The grid's spans are byte offsets into its own lines, so they are moved onto
---the sink's line numbers and along by the indent, which is plain ASCII.
---@param sink SpacetimeSchemaSink
---@param heading string
---@param columns SpacetimeGridColumn[]
---@param cells SpacetimeGridCell[][]
local function section(sink, heading, columns, cells)
	push(sink, "")
	push(sink, heading, "SpacetimeHeader")

	if #cells == 0 then
		push(sink, INDENT .. NONE, "SpacetimeNull")
		return
	end

	local layout = require("spacetime.ui.grid").layout(columns, cells, { header = false, max_width = MAX_WIDTH })
	local offset = #sink.lines
	for _, line in ipairs(layout.lines) do
		sink.lines[#sink.lines + 1] = INDENT .. line
	end
	for _, span in ipairs(layout.spans) do
		sink.spans[#sink.spans + 1] = {
			line = span.line + offset,
			start_col = span.start_col + #INDENT,
			end_col = span.end_col + #INDENT,
			hl_group = span.hl_group,
		}
	end
end

---`name (canonical)`, or just `name` where the two agree.
---
---Point 1 of the module header. Written once and used for the title and for
---every reducer, so the two can never disagree about what a dual name looks
---like.
---@param name any
---@param canonical any
---@return string
local function both_names(name, canonical)
	local display = type(name) == "string" and name or ""
	if type(canonical) == "string" and canonical ~= "" and canonical ~= display then
		return display .. " (" .. canonical .. ")"
	end
	return display
end

---The name of a 0-based column id, for an index or a constraint that names one.
---@param entry table
---@param id any
---@return string
local function column_name(entry, id)
	if type(id) ~= "number" then
		return tostring(id)
	end
	local column = type(entry.columns) == "table" and entry.columns[id + 1] or nil
	if type(column) == "table" and type(column.name) == "string" then
		return column.name
	end
	return "col" .. id
end

---A raw index algorithm or constraint payload as `Tag(col, col)`.
---
---Both arrive tagged, and both spell their column list one of two ways:
---`{BTree = {0, 2}}` for an index, `{Unique = {columns = {0}}}` for a
---constraint. A tag we do not recognise still prints its own name rather than
---nothing, which is the honest rendering of a schema feature this plugin has
---not met yet.
---@param raw any
---@param entry table
---@return string
local function tagged_columns(raw, entry)
	if type(raw) ~= "table" then
		return ""
	end
	local tag = next(raw)
	if type(tag) ~= "string" then
		return ""
	end

	local payload = raw[tag]
	local ids = payload
	if type(payload) == "table" and type(payload.columns) == "table" then
		ids = payload.columns
	end

	local names = {}
	if type(ids) == "table" then
		for _, id in ipairs(ids) do
			names[#names + 1] = column_name(entry, id)
		end
	end
	if #names == 0 then
		return tag
	end
	return tag .. "(" .. table.concat(names, ", ") .. ")"
end

---One reducer's signature: `book (book)(instanceId: U64) -> ok {} / err String`.
---
---The return clause is omitted entirely when the schema carried neither type,
---which is every v9 reducer — an invented `-> ok ?` would be a claim about the
---module rather than a report of what the server said.
---@param reducer SpacetimeSchemaReducer
---@param schema SpacetimeSchema
---@return string
local function signature(reducer, schema)
	local value = require("spacetime.lib.value")

	local params = {}
	for i, param in ipairs(reducer.params or {}) do
		local label = value.label(param.type, schema)
		params[i] = param.name and (param.name .. ": " .. label) or label
	end

	local out = both_names(reducer.name, reducer.canonical) .. "(" .. table.concat(params, ", ") .. ")"

	local returns = {}
	if reducer.ok_return_type ~= nil then
		returns[#returns + 1] = "ok " .. value.label(reducer.ok_return_type, schema)
	end
	if reducer.err_return_type ~= nil then
		returns[#returns + 1] = "err " .. value.label(reducer.err_return_type, schema)
	end
	if #returns > 0 then
		out = out .. " -> " .. table.concat(returns, " / ")
	end
	return out
end

---The title and the badge: what this is, and what the server said about it.
---@param sink SpacetimeSchemaSink
---@param entry table
---@param schema SpacetimeSchema
local function heading(sink, entry, schema)
	push(sink, both_names(entry.name, entry.canonical), "SpacetimeHeader")

	local count = type(entry.columns) == "table" and #entry.columns or 0
	local pieces = { entry.is_view and "view" or (entry.is_system and "system table" or "table") }
	-- A view's access is a boolean of its own; a table's is the raw tag.
	if entry.is_view then
		pieces[#pieces + 1] = entry.is_public and "Public" or "Private"
		if entry.is_anonymous then
			pieces[#pieces + 1] = "anonymous"
		end
	else
		pieces[#pieces + 1] = tostring(entry.access)
	end
	pieces[#pieces + 1] = ("%d column%s"):format(count, count == 1 and "" or "s")
	pieces[#pieces + 1] = "schema v" .. tostring(schema.version)

	push(sink, table.concat(pieces, " · "))
end

---@param sink SpacetimeSchemaSink
---@param entry table
---@param schema SpacetimeSchema
local function columns_section(sink, entry, schema)
	local value = require("spacetime.lib.value")

	local cells = {} ---@type SpacetimeGridCell[][]
	for i, column in ipairs(entry.columns or {}) do
		local flags = {}
		if column.is_primary_key then
			flags[#flags + 1] = "PK"
		end
		if column.is_autoinc then
			flags[#flags + 1] = "autoinc"
		end
		if type(column.default) == "string" then
			flags[#flags + 1] = "default " .. column.default
		end
		cells[i] = {
			{ text = column.name, hl = column.is_primary_key and "SpacetimePrimaryKey" or nil },
			{ text = value.label(column.type, schema) },
			{ text = table.concat(flags, " ") },
		}
	end

	section(sink, "Columns", { { name = "name" }, { name = "type" }, { name = "flags" } }, cells)
end

---@param sink SpacetimeSchemaSink
---@param entry table
local function indexes_section(sink, entry)
	local cells = {} ---@type SpacetimeGridCell[][]
	for i, index in ipairs(entry.indexes or {}) do
		cells[i] = {
			{ text = index.name or "" },
			{ text = tagged_columns(index.algorithm, entry) },
			{ text = index.accessor and ("accessor " .. index.accessor) or "" },
		}
	end
	section(sink, "Indexes", { { name = "name" }, { name = "algorithm" }, { name = "accessor" } }, cells)
end

---@param sink SpacetimeSchemaSink
---@param entry table
local function constraints_section(sink, entry)
	local cells = {} ---@type SpacetimeGridCell[][]
	for i, constraint in ipairs(entry.constraints or {}) do
		cells[i] = {
			{ text = constraint.name or "" },
			{ text = tagged_columns(constraint.data, entry) },
		}
	end
	section(sink, "Constraints", { { name = "name" }, { name = "data" } }, cells)
end

---The database's reducers, whichever table is on screen.
---
---Point 2 of the module header: the access column exists only when the server
---told us something to put in it. A `Private` reducer is greyed out rather than
---hidden — it is part of the module, it is simply not yours to call.
---@param sink SpacetimeSchemaSink
---@param schema SpacetimeSchema
---@param database string
local function reducers_section(sink, schema, database)
	local reducers = schema.reducers or {}

	local known = false
	for _, reducer in ipairs(reducers) do
		if type(reducer.visibility) == "string" then
			known = true
		end
	end

	local columns = { { name = "signature" } } ---@type SpacetimeGridColumn[]
	if known then
		columns = { { name = "access" }, { name = "signature" } }
	end

	local cells = {} ---@type SpacetimeGridCell[][]
	for i, reducer in ipairs(reducers) do
		-- Greyed out, not hidden. `nil` visibility is not `Private`; see point 2.
		local hl = reducer.visibility == "Private" and "SpacetimeNull" or nil
		if known then
			cells[i] = { { text = reducer.visibility or "", hl = hl }, { text = signature(reducer, schema), hl = hl } }
		else
			cells[i] = { { text = signature(reducer, schema), hl = hl } }
		end
	end

	section(sink, ("Reducers (%s)"):format(database), columns, cells)
end

---Message text as buffer lines, each marked in full.
---
---Split on newlines first: a server's error is regularly several lines long, and
---folding it onto one would hide the part that says what went wrong.
---@param message any
---@return string[] lines
---@return SpacetimeGridSpan[] spans
local function error_lines(message)
	local text = (type(message) == "string" and message ~= "") and message or UNKNOWN_ERROR

	local sink = new_sink()
	for _, raw in ipairs(vim.split("error: " .. text, "\n", { plain = true })) do
		push(sink, raw, "SpacetimeError")
	end
	return sink.lines, sink.spans
end

---Every line of the view, and every span to mark on it.
---
---May raise — `ui/grid.layout` treats a ragged row as fatal. `M.render` calls
---this through `pcall` and turns anything that escapes into buffer text.
---@param current SpacetimeSchemaDisplay
---@return string[] lines
---@return SpacetimeGridSpan[] spans
local function build(current)
	if current.status == "loading" then
		return { LOADING }, {}
	end
	if current.status == "error" then
		return error_lines(current.error)
	end

	local schema = current.schema
	if type(schema) ~= "table" then
		return error_lines("no schema")
	end

	local entry = require("spacetime.lib.schema").entry_by_name(schema, current.table_name)
	if entry == nil then
		-- Data we do not have, not a programming error: the user named a table the
		-- module does not define, or one that has since been dropped.
		return error_lines(("%s has no table or view called %s"):format(current.database, current.table_name))
	end

	local sink = new_sink()
	heading(sink, entry, schema)
	columns_section(sink, entry, schema)
	-- A view has neither, and says so rather than dropping the headings: "this
	-- view has no indexes" is a fact worth stating.
	indexes_section(sink, entry)
	constraints_section(sink, entry)
	reducers_section(sink, schema, current.database)

	return sink.lines, sink.spans
end

--------------------------------------------------------------------------------
-- Painting
--------------------------------------------------------------------------------

---Paint the current view into the content buffer.
---
---A no-op when there is nothing to show, when the content buffer does not exist,
---or when another view has claimed it since — a schema response that lands after
---the user has opened a table's rows must not paint over the grid.
function M.render()
	local current = view
	if current == nil then
		return
	end

	local buffer = require("spacetime.ui.buffer")
	if not buffer.owns_content(M.OWNER) then
		return
	end
	local bufnr = buffer.find(buffer.CONTENT_NAME)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	-- Applying an empty key map is how the row grid's keys come off the shared
	-- buffer; see point 5 of the module header.
	require("spacetime.ui.keys").apply(bufnr, M.KEYMAPS)

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

---Fetch the database's schema and repaint when it lands.
---
---The same key and the same cache the sidebar's own schema fetch uses, so
---expanding a database in the sidebar and running `:SpacetimeSchema` on one of
---its tables costs one request between them, whichever order they happen in.
---
---The handle is registered with `state.start` *before* the request goes out: a
---stubbed transport completes inside the call, and a callback that ran before
---`start` returned would have no token to present.
---@param current SpacetimeSchemaDisplay
local function fetch(current)
	local state = require("spacetime.state")
	local key = state.key("schema", current.database)
	local client = require("spacetime.lib.client").new(current.connection)

	local handle = nil ---@type SpacetimeHttpHandle|nil
	local seq = state.start(key, {
		kill = function()
			if handle then
				handle.kill()
			end
		end,
	})

	handle = client:schema(current.database, nil, function(err, schema)
		-- A response that lost its token belongs to a database the user has moved
		-- away from; painting it now would undo what they did.
		if not state.finish(key, seq) then
			return
		end
		if current ~= view then
			return
		end

		if err then
			current.status = "error"
			current.error = err.message
		elseif schema then
			current.status = "ready"
			current.schema = schema
			state.cache_set(key, schema)
			-- One key means one request, so this fetch may have superseded the
			-- sidebar's own — expand a database and describe one of its tables in
			-- the same breath and that is exactly what happens. The answer is in the
			-- cache either way, so repainting the tree fills the node in rather than
			-- leaving it reading `loading…` for a request that was taken over.
			require("spacetime.ui.sidebar").render()
		else
			current.status = "error"
			current.error = "no schema"
		end
		M.render()
	end)
end

---Show a table's — or a view's — schema in the content window.
---
---What `:SpacetimeSchema` does. The schema is cached per database for the
---session, so a database already expanded in the sidebar renders without a
---request; `r` on the sidebar is the only thing that expires it.
---@param request SpacetimeSchemaRequest
function M.open(request)
	vim.validate("request", request, "table")
	vim.validate("connection", request.connection, "table")
	vim.validate("database", request.database, "string")
	vim.validate("table_name", request.table_name, "string")

	if request.database == "" or request.table_name == "" then
		-- A name we cannot look anything up by is data, not a programming error.
		require("spacetime.logger").warn("there is no table to describe here")
		return
	end

	local state = require("spacetime.state")
	local key = state.key("schema", request.database)

	-- A different database is a different key, so `state.start` below would leave
	-- the previous fetch running and its token live. Cancel it by hand.
	if view ~= nil then
		local previous = state.key("schema", view.database)
		if previous ~= key then
			state.cancel(previous)
		end
	end

	view = {
		connection = request.connection,
		database = request.database,
		table_name = request.table_name,
		status = "loading",
	}

	require("spacetime.ui.buffer").claim_content(M.OWNER)

	local cached = state.cache_get(key)
	if type(cached) == "table" then
		view.status = "ready"
		view.schema = cached
		M.render()
		return
	end

	M.render()
	fetch(view)
end

return M
