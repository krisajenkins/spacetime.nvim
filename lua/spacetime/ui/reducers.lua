-- The reducers view: what `:SpacetimeReducers [db]` paints into the content
-- window.
--
-- A module's reducers belong to the *database*, not to any one of its tables, so
-- they are a view of their own rather than a section under a table's schema.
-- `lib/reducers.lua` turns the normalised schema into the rows to show — the
-- signatures, and whether the server told us anything about visibility — and
-- `ui/sections.lua` lays them out; this file owns the buffer. It lives under
-- `ui/` and may therefore touch `vim.api`; everything it reads under `lib/` may
-- not.
--
-- Four things this file exists to get right:
--
-- 1. **A `Private` reducer is greyed out, never hidden.** It is part of the
--    module, it is simply not yours to call — and `:SpacetimeCall` (ROADMAP.md,
--    "Deferred past v1") will need to say which of the two a reducer is. The
--    access column exists at all only when the server sent a visibility, which v9
--    does not; see point 1 of `lib/reducers.lua`'s header.
-- 2. **The schema is the one everything else shares.** The same
--    `state.key("schema", db)` and the same cache as the sidebar's expansion and
--    the schema view, so opening the reducers of a database already expanded in
--    the tree costs no request, whichever order the two happen in.
-- 3. **Errors are buffer text.** A failed schema request, a raise from the layout
--    itself: both are rendered as lines, never as a stack trace under the cursor.
-- 4. **The content buffer is shared.** `open` claims it through
--    `ui/buffer.claim_content`, so a rows response still on the wire does not
--    paint over the reducers when it lands, and the render applies this view's key
--    map — the shared `q` and nothing else — through `ui/keys`, which takes the
--    grid's `s`, `]p`, `y`, `Y` and `K` back off the buffer. A stale `]p` must not
--    page a grid that is no longer displayed.

local M = {}

-- The title/badge/sections sink, shared with `ui/schema.lua`. Required at load
-- time like `ui/keys` below, and safe for the same reason: `ui/sections.lua`
-- requires nothing at load time, so it cannot cycle back here.
local sections = require("spacetime.ui.sections")

---The name this view claims the content buffer under.
M.OWNER = "reducers"

---Every key the content window binds while it is showing reducers.
---
---Only the shared `q` and `<Tab>`: like the schema view this is text, with
---nothing to page, sort or filter. (The sidebar's `R` is what opens it; that is a
---mapping in the sidebar buffer, not in this one.) Applying them on every render
---is also what *unbinds* the row grid's keys — see point 4 of the module header.
---@type SpacetimeKeymap[]
M.KEYMAPS = { require("spacetime.ui.keys").CLOSE, require("spacetime.ui.keys").FOCUS }

local LOADING = "loading…"

---What |spacetime.ui.reducers.open()| needs.
---
---The connection is passed in rather than resolved here, for the same reason as
---the schema view's: `config.current()` reads the project config governing the
---*current* buffer, and by the time this runs that buffer may be one of our own
---scratch buffers. The caller resolves it before the layout displaces anything.
---@class SpacetimeReducersRequest
---@field connection SpacetimeConnection Resolved by the caller, not by this module.
---@field database string Database name or identity, as it goes in the URL path.

---The request plus what has become of it.
---
---`status`, `error` and `schema` come from `SpacetimeDetailDisplay`, which is
---what `ui/detail.fetch_schema` fills in — the same three fields the schema view
---gets back from the same request.
---@class SpacetimeReducersDisplay : SpacetimeReducersRequest, SpacetimeDetailDisplay

---What is on screen, or being fetched onto it. `nil` before the first open.
---@type SpacetimeReducersDisplay|nil
local view = nil

--------------------------------------------------------------------------------
-- Building the lines
--------------------------------------------------------------------------------

---Every line of the view, and every span to mark on it.
---
---May raise — `ui/grid.layout` treats a ragged row as fatal. `M.render` calls
---this through `pcall` and turns anything that escapes into buffer text.
---@param current SpacetimeReducersDisplay
---@return string[] lines
---@return SpacetimeGridSpan[] spans
local function build(current)
	if current.status == "loading" then
		return { LOADING }, {}
	end
	if current.status == "error" then
		return sections.error_lines(current.error)
	end

	local schema = current.schema
	if type(schema) ~= "table" then
		return sections.error_lines("no schema")
	end

	local list = require("spacetime.lib.reducers").list(schema)

	local columns = { { name = "signature" } } ---@type SpacetimeGridColumn[]
	if list.show_access then
		columns = { { name = "access" }, { name = "signature" } }
	end

	local cells = {} ---@type SpacetimeGridCell[][]
	for i, row in ipairs(list.rows) do
		-- Greyed out, not hidden; see point 1 of the module header.
		local hl = row.is_private and "SpacetimeNull" or nil
		if list.show_access then
			cells[i] = { { text = row.access, hl = hl }, { text = row.signature, hl = hl } }
		else
			cells[i] = { { text = row.signature, hl = hl } }
		end
	end

	local sink = sections.new()
	-- The title is the database, because that is what a reducer belongs to. The
	-- badge says how many there are and which schema version said so — the same
	-- two facts the schema view's badge ends with.
	sections.push(sink, current.database, "SpacetimeHeader")
	sections.push(
		sink,
		("%d reducer%s · schema v%s"):format(#cells, #cells == 1 and "" or "s", tostring(schema.version))
	)
	sections.section(sink, "Reducers", columns, cells)

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
	local bufnr = buffer.content_target(M.OWNER)
	if not bufnr then
		return
	end
	-- Applying this view's one-key map is how the row grid's keys come off the
	-- shared buffer; see point 4 of the module header.
	require("spacetime.ui.keys").apply(bufnr, M.KEYMAPS)

	local lines, spans
	local ok, built_lines, built_spans = pcall(build, current)
	if ok then
		lines, spans = built_lines, built_spans
	else
		-- Strip the "file:line: " a raise carries: the message is for a user, not
		-- for whoever is reading this file.
		lines, spans = sections.error_lines((tostring(built_lines):gsub("^.-:%d+: ", "")))
	end

	-- The one write. Everything above assembles; nothing below adds a line.
	buffer.paint(bufnr, lines, spans)
end

--------------------------------------------------------------------------------
-- Fetching
--------------------------------------------------------------------------------

---Fetch the database's schema and repaint when it lands.
---
---`ui/detail.lua` owns the request itself, because the schema view wants exactly
---the same one: the same key and the same cache the sidebar's own fetch uses —
---see point 2 of the module header — so this and the schema view supersede each
---other rather than both asking.
---@param current SpacetimeReducersDisplay
local function fetch(current)
	require("spacetime.ui.detail").fetch_schema(current, function()
		return current == view
	end, M.render)
end

---Show a database's reducers in the content window.
---
---What `:SpacetimeReducers` does. The schema is cached per database for the
---session, so a database already expanded in the sidebar renders without a
---request; `r` on the sidebar is the only thing that expires it.
---@param request SpacetimeReducersRequest
function M.open(request)
	vim.validate("request", request, "table")
	vim.validate("connection", request.connection, "table")
	vim.validate("database", request.database, "string")

	if request.database == "" then
		-- A name we cannot look anything up by is data, not a programming error.
		require("spacetime.logger").warn("there are no reducers to show: no database was named")
		return
	end

	local state = require("spacetime.state")
	local key = state.key("schema", request.database)

	-- A different database is a different key, so `state.request` below would leave
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
