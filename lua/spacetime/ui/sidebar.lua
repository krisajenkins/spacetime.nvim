-- The sidebar controller: everything `:Spacetime` does once the windows exist.
--
-- `ui/buffer.lua` owns the windows and `ui/tree.lua` owns the layout of the
-- text; this module is the part in between — it holds the model, fetches the
-- database list, paints the result, and binds the keys that drive it. It lives
-- under `ui/` and may therefore touch `vim.api`; `lib/` may not.
--
-- Seven things this file exists to get right:
--
-- 1. **The connection is resolved before the layout is opened.** `open_layout()`
--    displaces the current window's buffer, and `config.current()` reads the
--    project config governing *that* buffer — so resolving afterwards would ask
--    our own `spacetime://sidebar` scratch buffer which repository it belongs
--    to, and get the working directory as the answer. Resolving first is what
--    makes "run `:Spacetime` in a module repo and land on its database" work.
-- 2. **One request key, and a sequence token round every response.** The list
--    goes out under `commands.DATABASES_KEY`, so a second `:Spacetime` kills the
--    first fetch, and a response that arrives after its token was burned is
--    dropped rather than painted over the newer one. The handle is registered
--    with `state.request` *before* the request is made: a stubbed transport (and,
--    one day, a synchronous cache path) can complete inside the call, and a
--    callback that ran before `start` returned would have no token to present.
-- 3. **`list_databases` may answer with an error *and* a list.** It is the one
--    client method that does (see its header): when some `/names` requests fail
--    the rest are still good. Both halves are kept — the databases are rendered,
--    and the ones that failed carry their message and are expanded so it is
--    visible — because dropping either would be a lie about what we know.
-- 4. **Errors are buffer text.** Every failure path here ends in
--    `tree.build_lines` rendering an `error:` line into the sidebar, never in a
--    raise and never in a stack trace under the cursor.
-- 5. **Expansion state lives here, not in the tree.** `ui/tree.lua` is pure and
--    holds nothing; the set of expanded database names is this module's, and it
--    survives a refetch, so pressing `r` does not collapse the tree.
-- 6. **A schema is fetched once per database, and a pause is never retried.**
--    Expanding fetches into `state`'s `schema:<db>` cache, so a second expand is
--    a table lookup. A `paused` answer is recorded and stops any further asking
--    until `r` clears it: a paused database answers 503 on *every* endpoint, so
--    a node that refetched on each expand would hammer it. Nothing here probes
--    for pauses — the status is only ever learnt from a request the user asked
--    for.
-- 7. **The project database is focused exactly once.** A fresh layout arms a
--    one-shot flag, and the first settled render puts the cursor on the database
--    the project config named rather than on the alphabetically first one. It has
--    to be one-shot: every later paint — `r`, a schema landing, a second
--    `:Spacetime` — restores the row the cursor was already on, and yanking it
--    back to the project database each time would fight the user for the cursor.
--
-- Every `require` is inside a function body, matching `commands.lua`: this
-- module is only reached by running a command, and `spacetime.commands` requires
-- it back. The one exception is `ui/keys` in `M.KEYMAPS`, which is evaluated when
-- that table is constructed — safe because `ui/keys.lua` requires nothing at
-- load time, so it cannot cycle back here.

local M = {}

---The model `ui/tree.lua` renders, rebuilt from the fetched entries.
---@type SpacetimeTreeModel
local model = { status = "idle" }

---The nodes of the last render, parallel to the sidebar's lines. `<CR>` on line
---N is `nodes[N]`; see the invariant in `ui/tree.lua`'s header.
---@type SpacetimeTreeNode[]
local nodes = {}

---Which databases are expanded, by display name. Survives a refetch.
---@type table<string, boolean>
local expanded = {}

---What a schema fetch concluded, by display name.
---
---Nothing is recorded while a request is in flight — that is read back from
---`state.data.inflight`, so cancelling (collapsing, `q`, a second fetch) clears
---the loading state without this module having to sweep up after it. A success
---leaves no entry either: the schema itself is the record, in the cache. What
---lands here is a pause or a failure, and either one stops the node asking
---again until `r` drops it.
---@type table<string, { paused: boolean|nil, error: string|nil }>
local schema_results = {}

-- The connection this browsing session talks to, resolved from the buffer the
-- user ran `:Spacetime` from rather than from our own scratch buffer.
local connection = nil ---@type SpacetimeConnection|nil
local connection_error = nil ---@type string|nil

-- The database the project config named, if any: what to expand straight to.
local project_database = nil ---@type string|nil

-- Set when a fresh layout opens; the next settled render puts the cursor on the
-- project database and clears it. One-shot, so `r` and every later repaint keep
-- the cursor where the user left it. See point 7 of the module header.
local focus_project = false ---@type boolean

-- The buffer the content window displaced when the layout opened, so `q` can
-- put it back rather than leaving a `spacetime://content` scratch behind.
local displaced = nil ---@type integer|nil

---The name the placeholder claims the content buffer under, so a view that
---painted before a reconnect cannot repaint over it afterwards.
M.PLACEHOLDER_OWNER = "placeholder"

---What the content window says until something is selected.
M.PLACEHOLDER = {
	"spacetime.nvim",
	"",
	"Expand a database in the sidebar with <CR>.",
	"Press ? there for the full key map.",
}

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

---The cache and in-flight key the database list lives under.
---
---Read from `commands.lua` rather than re-spelt here: one name, one owner.
---@return string
local function databases_key()
	return require("spacetime.commands").DATABASES_KEY
end

---Re-derive the per-database view state from this module's own tables.
---
---Expanding, collapsing, a schema landing in the cache and a fetch going out
---all take effect through this one path: the model handed to `ui/tree.lua` is
---derived on every render rather than mutated in place, so there is one answer
---to "what does this node say", and it survives the list being refetched
---underneath it.
---
---An expanded database with nothing known about it renders no children at all,
---which is the honest thing to show for data nobody has fetched.
local function sync_databases()
	local state = require("spacetime.state")
	for _, db in ipairs(model.databases or {}) do
		-- A database whose `/names` request failed is expanded regardless, so its
		-- error is on screen rather than hidden behind a collapsed marker.
		db.expanded = expanded[db.name] == true or db.status == "error"

		local name = type(db.name) == "string" and db.name or ""
		-- A `/names` failure is the more fundamental one: a database we could not
		-- even name keeps its own error rather than gaining a schema's.
		if name ~= "" and db.status ~= "error" then
			local key = state.key("schema", name)
			if db.schema == nil then
				db.schema = state.cache_get(key)
			end
			local result = schema_results[name]
			if state.data.inflight[key] ~= nil then
				db.status = "loading"
			elseif result ~= nil and result.paused then
				db.status = "paused"
			elseif result ~= nil and result.error then
				db.status = "error"
				db.error = result.error
			else
				-- Nothing in flight and nothing recorded: whatever the node last said
				-- is over. Said explicitly, because the state is *derived* — a node
				-- left reading `loading…` after its request was taken over by
				-- `ui/schema.lua` (one key, one request) would be showing a request
				-- that no longer exists.
				db.status = "idle"
				db.error = nil
			end
		end
	end
end

---The window in the current tabpage showing the sidebar, if any.
---@return integer|nil winid
---@return integer|nil bufnr
local function sidebar_window()
	local buffer = require("spacetime.ui.buffer")
	local bufnr = buffer.find(buffer.SIDEBAR_NAME)
	if not bufnr then
		return nil, nil
	end
	return buffer.window_showing(bufnr), bufnr
end

---Is this the database the project config named?
---
---Matched on either spelling: the config may name a database by its display name
---or by its hex identity, and both a `SpacetimeDatabaseEntry` and a tree node
---carry the pair. One predicate for both callers — the expansion and the cursor
---have to agree on which node is the project's, or `:Spacetime` would expand one
---database and land on another.
---@param name string|nil Display name.
---@param identity string|nil Hex identity.
---@return boolean
local function is_project_database(name, identity)
	if type(project_database) ~= "string" or project_database == "" then
		return false
	end
	return name == project_database or identity == project_database
end

---Paint the model into the sidebar buffer.
---
---A no-op when the sidebar buffer does not exist yet: the model is still there
---and the next `open()` renders it.
function M.render()
	local buffer = require("spacetime.ui.buffer")
	local bufnr = buffer.find(buffer.SIDEBAR_NAME)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	sync_databases()
	-- The icon mode is configuration rather than model state, so it is read per
	-- render: a `setup()` that lands after the first paint takes effect on the
	-- next one instead of needing the layout reopened.
	model.icons = require("spacetime").config.icons
	local rendered = require("spacetime.ui.tree").build_lines(model)
	nodes = rendered.nodes

	-- Read before the write and put back after it: a refetch that keeps the same
	-- databases must not throw the cursor back to the top of the tree. The project
	-- database overrides the preserved row exactly once — on the first settled
	-- render after a fresh layout opened, and never again.
	local winid = buffer.window_showing(bufnr)
	local row = winid and vim.api.nvim_win_get_cursor(winid)[1] or nil
	if winid and focus_project then
		for _, node in ipairs(nodes) do
			if node.kind == "database" and is_project_database(node.database, node.db and node.db.identity) then
				row = node.line
				break
			end
		end
		-- Disarmed whether or not it was found: a project file naming a database
		-- this identity does not own must not leave the flag waiting to pounce on
		-- some later refresh.
		if model.status ~= "loading" then
			focus_project = false
		end
	end

	buffer.paint(bufnr, rendered.lines, rendered.spans)

	if winid and row then
		vim.api.nvim_win_set_cursor(winid, { math.min(row, math.max(#rendered.lines, 1)), 0 })
	end
end

---Write the placeholder into the content buffer, unless it already says
---something. `ui/rows.lua` writes real content there, and reopening the layout
---must never clobber it — neither its lines nor the key map that goes with them.
---
---The placeholder gets the two shared keys and nothing else: `q` and `<Tab>` must
---work in the content window from the moment the layout opens, not only once a
---view has painted into it. Every view re-applies its own map on render, which
---puts these back among the rest.
---@param bufnr integer
local function place_placeholder(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if #lines > 1 or (lines[1] or "") ~= "" then
		return
	end
	local keys = require("spacetime.ui.keys")
	require("spacetime.ui.buffer").set_lines(bufnr, M.PLACEHOLDER)
	keys.apply(bufnr, { keys.CLOSE, keys.FOCUS })
end

--------------------------------------------------------------------------------
-- Expansion
--------------------------------------------------------------------------------

---Fetch one database's schema into the cache and repaint when it lands.
---
---Three guards, and between them they are the whole of "one request per
---database": a cached schema, a request already in flight, and a recorded
---outcome each mean there is nothing left to ask. The last of those is what
---makes a paused database cost exactly one request however many times it is
---expanded, and `r` is what clears it (see |spacetime.ui.sidebar.refresh()|).
---
---The version negotiation and the no-retry rule belong to `lib/client.lua`: it
---falls back v10 -> v9 only on `schema.should_fallback`, which is 4xx-only, so
---a paused database's 503 produces one request and one `paused` error without a
---second guard here.
---@param name string Display name of the database.
local function fetch_schema(name)
	if type(name) ~= "string" or name == "" or not connection then
		return
	end

	local state = require("spacetime.state")
	local key = state.key("schema", name)
	if state.cache_get(key) ~= nil or state.data.inflight[key] ~= nil or schema_results[name] ~= nil then
		return
	end

	local client = require("spacetime.lib.client").new(connection)

	-- `state.request` registers the key before the request goes out; see point 2
	-- of the module header.
	state.request(key, function(seq)
		return client:schema(name, nil, function(err, schema)
			-- A schema that lost its token belongs to a node the user has collapsed,
			-- closed or refreshed past; painting it now would undo what they did.
			if not state.finish(key, seq) then
				return
			end
			if err then
				schema_results[name] = err.kind == "paused" and { paused = true } or { error = err.message }
			elseif schema then
				state.cache_set(key, schema)
			end
			M.render()
		end)
	end)
end

---Ask for the schema of every database the user has expanded.
---
---Called after a list arrives and after a cached one renders, so an expanded
---node ends up showing what it claims to even though the list it hangs off was
---replaced underneath it. Cheap by construction: `fetch_schema` is guarded, so
---the already-cached databases put nothing on the wire.
local function fetch_expanded_schemas()
	for _, db in ipairs(model.databases or {}) do
		if type(db.name) == "string" and expanded[db.name] then
			fetch_schema(db.name)
		end
	end
end

---Expand a database node, fetching its schema if we do not already have it.
---@param name string Display name, as `node.database` reports it.
function M.expand(name)
	if type(name) ~= "string" or name == "" then
		return
	end
	expanded[name] = true
	fetch_schema(name)
end

---Collapse a database node, cancelling a schema fetch nobody is waiting for.
---
---`state.cancel` kills the handle *and* burns the key's token, so a response
---already on the wire is dropped rather than painted under a node the user has
---just closed.
---@param name string
function M.collapse(name)
	if type(name) ~= "string" or name == "" then
		return
	end
	expanded[name] = nil

	local state = require("spacetime.state")
	state.cancel(state.key("schema", name))
end

---Expand the database the project config named, if the list contains it.
---
---Which entry that is comes from `is_project_database`, shared with the cursor
---placement in `M.render()`.
---@param entries SpacetimeDatabaseEntry[]
local function expand_project_database(entries)
	for _, entry in ipairs(entries) do
		if is_project_database(entry.name, entry.identity) then
			M.expand(entry.name)
		end
	end
end

--------------------------------------------------------------------------------
-- Fetching
--------------------------------------------------------------------------------

---Turn the client's entries into the tree's databases, sorted by display name.
---
---The client preserves the server's order; the sidebar sorts, because the wire
---order is arbitrary and a list that reshuffles between refreshes is one the
---user cannot navigate by muscle memory. The identity breaks a name tie, so the
---sort is total even when two databases answer to the same name.
---@param entries SpacetimeDatabaseEntry[]
local function set_databases(entries)
	local databases = {} ---@type SpacetimeTreeDatabase[]
	for _, entry in ipairs(entries) do
		databases[#databases + 1] = {
			name = entry.name,
			identity = entry.identity,
			status = entry.error and "error" or "idle",
			error = entry.error,
		}
	end

	table.sort(databases, function(a, b)
		if a.name == b.name then
			return (a.identity or "") < (b.identity or "")
		end
		return a.name < b.name
	end)

	model.status = "idle"
	model.error = nil
	model.databases = databases
end

---Put the sidebar into its error state and paint it.
---@param message string
local function fail(message)
	model.status = "error"
	model.error = message
	model.databases = nil
	M.render()
end

---Fetch the database list and render it.
---
---Cancels whatever was already in flight under the key, by virtue of
---`state.request`, which registers under it.
local function fetch()
	local state = require("spacetime.state")
	local key = databases_key()

	if not connection then
		fail(connection_error or "no connection could be resolved")
		return
	end

	local identity, identity_error =
		require("spacetime.lib.identity").resolve(connection.token, require("spacetime").config.identity)
	if not identity then
		fail(identity_error or "no identity could be resolved")
		return
	end

	model.status = "loading"
	model.error = nil
	M.render()

	local client = require("spacetime.lib.client").new(connection)

	-- `state.request` registers the key before the request goes out; see point 2
	-- of the module header.
	state.request(key, function(seq)
		return client:list_databases(identity, function(err, databases)
			if not state.finish(key, seq) then
				return
			end
			if databases then
				-- Both arguments may be set: partial data plus the first `/names`
				-- failure. Keep both — the failed entries carry their own message.
				state.cache_set(key, databases)
				expand_project_database(databases)
				set_databases(databases)
				fetch_expanded_schemas()
			else
				model.status = "error"
				model.error = err and err.message or "could not list databases"
				model.databases = nil
			end
			M.render()
		end)
	end)
end

--------------------------------------------------------------------------------
-- Opening and closing
--------------------------------------------------------------------------------

---Resolve the connection, and remember the buffer we are about to displace.
---
---Called while the user's own buffer is still current — see point 1 of the
---module header.
local function capture_context()
	local buffer = require("spacetime.ui.buffer")

	local bufnr = vim.api.nvim_get_current_buf()
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name ~= buffer.SIDEBAR_NAME and name ~= buffer.CONTENT_NAME then
		displaced = bufnr
	end

	connection, connection_error = require("spacetime.config").current(bufnr)
	project_database = connection and connection.database or nil
end

---Options for |spacetime.ui.sidebar.open()|.
---@class SpacetimeSidebarOpenOpts
---@field refresh? boolean Drop the cached list and fetch it again.

---Open — or re-focus — the browser, and fill the sidebar in.
---
---Idempotent: `open_layout()` reuses the windows, the keymaps are re-set over
---themselves, and a cached database list renders without a request. Focus is
---left on the sidebar.
---@param opts? SpacetimeSidebarOpenOpts
---@return integer sidebar_win
---@return integer content_win
function M.open(opts)
	opts = opts or {}
	local buffer = require("spacetime.ui.buffer")
	local state = require("spacetime.state")

	capture_context()

	-- Armed only when the layout was not already open, and read before it opens.
	-- Two things depend on that: a second `:Spacetime` re-focuses without yanking
	-- the cursor away from wherever the user has got to, and `:SpacetimeRows` and
	-- friends — which call this to guarantee the layout exists — leave an open
	-- sidebar's cursor alone while still landing sensibly on a cold start.
	focus_project = focus_project or (not M.is_open() and type(project_database) == "string" and project_database ~= "")

	local sidebar_win, content_win = buffer.open_layout()
	M.apply_keymaps(vim.api.nvim_win_get_buf(sidebar_win))
	place_placeholder(vim.api.nvim_win_get_buf(content_win))

	local key = databases_key()
	if opts.refresh then
		state.cache_invalidate(key)
	end

	local cached = state.cache_get(key)
	if type(cached) == "table" then
		expand_project_database(cached)
		set_databases(cached)
		fetch_expanded_schemas()
		M.render()
	else
		fetch()
	end

	return sidebar_win, content_win
end

---Re-resolve the connection and start again. What |:SpacetimeConnect| does once
---the switch itself has been accepted.
---
---A no-op when the layout is not open: there is nothing on screen to be stale,
---and the next `:Spacetime` resolves from scratch anyway.
---
---The re-resolution reads the buffer the content window displaced — the user's
---own, whose project config governed the first resolution — rather than whatever
---is current now, which is usually one of our own scratch buffers. That is point
---1 of the module header, one step removed: the rule outlives the moment the
---layout opened.
---
---The caller is expected to have dropped the cache and cancelled what was in
---flight, both of which belong to the server being left behind. What this adds is
---the state that is *not* in `state.lua`: what the old server said about each
---database, and whatever the content window was showing.
function M.reconnect()
	if not M.is_open() then
		return
	end

	local bufnr = (type(displaced) == "number" and vim.api.nvim_buf_is_valid(displaced)) and displaced or 0
	connection, connection_error = require("spacetime.config").current(bufnr)
	project_database = connection and connection.database or nil

	-- A pause and a failed schema are facts about the old server, and holding on
	-- to them would stop the new one being asked at all. Expansion is kept: it is
	-- the user's arrangement of the tree rather than anything a server said, and a
	-- database the new server also has is refetched by `fetch_expanded_schemas`.
	schema_results = {}

	-- Whatever the content window is showing came from the old server, so it goes
	-- back to the placeholder rather than sitting there looking current.
	local buffer = require("spacetime.ui.buffer")
	local content = buffer.find(buffer.CONTENT_NAME)
	if content and vim.api.nvim_buf_is_valid(content) then
		buffer.claim_content(M.PLACEHOLDER_OWNER)
		local keys = require("spacetime.ui.keys")
		buffer.set_lines(content, M.PLACEHOLDER)
		keys.apply(content, { keys.CLOSE, keys.FOCUS })
	end

	fetch()
end

---Refetch the database list, cache and all. What `r` does.
---
---On a database node the database's own cache goes too — a `rows:` key embeds
---its database, so refreshing it has to drop its dependents — and so does what
---the last schema request concluded. That is the whole of the retry story for a
---paused database: it is never asked again on its own, and `r` is how you ask
---once it has woken up. The list fetch that follows re-requests the schema of
---everything still expanded.
function M.refresh()
	local state = require("spacetime.state")

	local node = M.node_under_cursor()
	if node and node.database then
		state.cancel(state.key("schema", node.database))
		schema_results[node.database] = nil
		state.cache_invalidate_db(node.database)
	end
	state.cache_invalidate(databases_key())

	fetch()
end

---Is the layout open in the current tabpage?
---@return boolean
function M.is_open()
	return sidebar_window() ~= nil
end

---A buffer for the last window standing: something of the user's, never ours.
---
---Three candidates, in order, and the order is the point:
---
--- 1. the buffer this window was showing when the layout displaced it, which is
---    what "give me my window back" means;
--- 2. the window's own alternate — `#`, what `:b#` and `<C-^>` go to — for a
---    window we never displaced anything out of (the sidebar, when it is all
---    that is left, or a `:split` of the content window);
--- 3. a fresh listed, empty buffer, for a session that has nothing else in it.
---
---A candidate that is one of ours is skipped: handing `spacetime://content` back
---to the window is exactly the thing this exists to avoid.
---@param winid integer The window about to be restored.
---@return integer bufnr
local function restore_buffer(winid)
	local buffer = require("spacetime.ui.buffer")

	---@param bufnr integer|nil
	---@return boolean
	local function usable(bufnr)
		return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) and not buffer.is_ours(bufnr)
	end

	if usable(displaced) then
		return displaced --[[@as integer]]
	end

	-- `bufnr('#')` is per window, so it is read from inside the window it is
	-- being read for. Unlisted alternates (a help buffer, another plugin's
	-- scratch) are refused: the point is to land the user somewhere they can work.
	local alternate = vim.api.nvim_win_call(winid, function()
		return vim.fn.bufnr("#")
	end)
	if usable(alternate) and vim.bo[alternate].buflisted then
		return alternate
	end

	return vim.api.nvim_create_buf(true, false)
end

---Close the layout, cancelling everything in flight.
---
---The cancel comes first and is unconditional: a response landing after the
---windows have gone would repaint a buffer nobody is looking at, and one that
---landed after a wipe would raise.
---
---A log follow needs one more word than that. `cancel_all` kills its `curl`, but
---the repeating flush timer is the log view's own handle and only its teardown
---closes it — and closing the layout does not wipe the content buffer, so the
---`BufWipeout` that would otherwise do it never fires. Left alone the timer would
---tick for the rest of the session; `logs.teardown` is silent and idempotent, so
---it is safe to call whether or not anything was being followed.
---
---Neither window is ever the one that closes Neovim, and no window is left
---showing a `spacetime://` buffer. The last window standing is handed a normal
---buffer back — see `restore_buffer` above — instead of being closed.
---
---The count that decides is `buffer.normal_windows()`, not the length of
---`nvim_tabpage_list_wins`: floats are in that list but cannot be what Neovim is
---left with, so a single notification popup on screen was enough to make the old
---count say "two windows" and the close raise `E444: Cannot close last window`.
---Floats are closed unconditionally for the same reason — one can never be the
---window that survives.
function M.close()
	require("spacetime.state").cancel_all()
	require("spacetime.ui.logs").teardown()

	local buffer = require("spacetime.ui.buffer")

	-- Sidebar windows first, so the one left standing is a content window: that
	-- is the user's own window, the one whose buffer we displaced. Every window
	-- showing either buffer is collected, not just the first — `:split` in the
	-- content window makes two, and one left behind is a scratch buffer the user
	-- has to clear by hand.
	local windows = {} ---@type { win: integer, sidebar: boolean }[]
	for _, name in ipairs({ buffer.SIDEBAR_NAME, buffer.CONTENT_NAME }) do
		local bufnr = buffer.find(name)
		for _, winid in ipairs(bufnr and buffer.windows_showing(bufnr) or {}) do
			windows[#windows + 1] = { win = winid, sidebar = name == buffer.SIDEBAR_NAME }
		end
	end

	for _, entry in ipairs(windows) do
		-- Re-checked per window: closing one of ours can take another with it (an
		-- `autocmd`, a `WinClosed` handler), and the count changes under the loop
		-- by construction.
		local winid = entry.win
		if vim.api.nvim_win_is_valid(winid) then
			if buffer.is_floating(winid) or buffer.normal_windows() > 1 then
				vim.api.nvim_win_close(winid, true)
			else
				vim.api.nvim_win_set_buf(winid, restore_buffer(winid))
				if entry.sidebar then
					-- A sidebar window that survives is a window the user keeps, so
					-- it gives back the chrome the layout put on it.
					buffer.unstyle_sidebar(winid)
				end
			end
		end
	end
end

---Close the layout if it is open, open it otherwise.
function M.toggle()
	if M.is_open() then
		M.close()
	else
		M.open()
	end
end

--------------------------------------------------------------------------------
-- Keymaps
--------------------------------------------------------------------------------

---The node under the cursor, or `nil` when the sidebar is not on screen.
---@return SpacetimeTreeNode|nil
function M.node_under_cursor()
	local winid = sidebar_window()
	if not winid then
		return nil
	end
	return nodes[vim.api.nvim_win_get_cursor(winid)[1]]
end

---Expand, collapse, or open whatever is under the cursor.
function M.select()
	local node = M.node_under_cursor()
	if not node then
		return
	end

	if node.kind == "database" then
		local name = node.database
		if not name then
			return
		end
		if expanded[name] then
			M.collapse(name)
		else
			M.expand(name)
		end
		M.render()
		return
	end

	if node.kind == "table" or node.kind == "view" or node.kind == "system_table" then
		-- The *canonical* name is what SQL takes; `node.label` is the source
		-- spelling the developer wrote, and is only ever displayed.
		local table_name = node.canonical or node.name
		if not connection or not node.database or type(table_name) ~= "string" or table_name == "" then
			require("spacetime.logger").warn("there is no table to open here")
			return
		end

		require("spacetime.ui.rows").open({
			connection = connection,
			database = node.database,
			table_name = table_name,
			label = node.label,
			-- The entry carries the primary key; the schema resolves a `Ref` in a
			-- column's type. Both are already in hand, so neither costs a request.
			entry = node.entry,
			schema = node.db and node.db.schema or nil,
		})
	end
end

---Show the schema of the table or view under the cursor. What `s` does.
---
---The keystroke form of |:SpacetimeSchema|, and deliberately nothing more: a
---database node has no schema *view* to paint (what a database should paint is
---still an open question), so it says so and does nothing rather than guessing.
---
---No layout call: the cursor is in the sidebar, so the content window is already
---there. The schema itself is the one the tree cached when the database was
---expanded, so this normally costs no request at all.
function M.describe()
	local node = M.node_under_cursor()
	local kind = node ~= nil and node.kind or nil
	if node == nil or (kind ~= "table" and kind ~= "view" and kind ~= "system_table") then
		require("spacetime.logger").warn("there is no table to describe here")
		return
	end

	-- The *canonical* name is what the schema view resolves by; `node.label` is
	-- the source spelling, and is only ever displayed.
	local table_name = node.canonical or node.name
	local database = node.database
	if not connection or type(database) ~= "string" or type(table_name) ~= "string" or table_name == "" then
		require("spacetime.logger").warn("there is no table to describe here")
		return
	end

	require("spacetime.ui.schema").open({
		connection = connection,
		database = database,
		table_name = table_name,
	})
end

---Show the reducers of the database the cursor is inside. What `R` does.
---
---The keystroke form of |:SpacetimeReducers|. Reducers belong to the module
---rather than to any one of its tables, so — exactly like `gl` — this answers
---with the database the cursor is *inside*: pressed on a table or a view it shows
---that node's database's reducers. A top-level message line belongs to no
---database and says so.
---
---No layout call: the cursor is in the sidebar, so the content window is already
---there. The schema itself is the one the tree cached when the database was
---expanded, so this normally costs no request at all.
function M.reducers()
	local node = M.node_under_cursor()
	local database = node and node.database
	if not connection or type(database) ~= "string" or database == "" then
		require("spacetime.logger").warn("there are no reducers to show here")
		return
	end

	require("spacetime.ui.reducers").open({ connection = connection, database = database })
end

---Show the logs of the database the cursor is inside. What `gl` and `gL` do.
---
---The keystroke form of |:SpacetimeLogs| and |:SpacetimeLogs!|. Every node
---inside a database carries its name, so this works on a table as well as on the
---database itself — the logs are the module's, whichever of its tables the
---cursor happens to be on. A top-level message line belongs to no database and
---says so.
---@param follow boolean Keep the connection open and stream. What `!` means.
function M.logs(follow)
	local node = M.node_under_cursor()
	local database = node and node.database
	if not connection or type(database) ~= "string" or database == "" then
		require("spacetime.logger").warn("there is no database to show logs for here")
		return
	end

	require("spacetime.ui.logs").open({ connection = connection, database = database, follow = follow })
end

---Put `text` in the register the user asked for — `"` unless they prefixed one,
---so `"+y` copies to the system clipboard.
---@param text any Anything but a non-empty string is nothing to yank.
---@param what string What is being yanked, for the confirmation message.
local function yank(text, what)
	local logger = require("spacetime.logger")
	if type(text) ~= "string" or text == "" then
		logger.warn("nothing to yank here")
		return
	end

	local register = vim.v.register
	if type(register) ~= "string" or register == "" then
		register = '"'
	end
	vim.fn.setreg(register, text)
	logger.info(("yanked %s: %s"):format(what, text))
end

---Yank the name of the node under the cursor.
function M.yank_name()
	local node = M.node_under_cursor()
	yank(node and node.label, "name")
end

---Yank the identity of the database the cursor is inside.
function M.yank_identity()
	local node = M.node_under_cursor()
	yank(node and node.db and node.db.identity, "identity")
end

---Every key the sidebar binds, and the help text `?` prints. One table, so the
---mappings and the help cannot drift apart.
---
---The four view keys — `s`, `R`, `gl`, `gL` — are the keystroke forms of the
---commands that would otherwise be the only way in, and each is answered by the
---node under the cursor rather than by an argument. Two rules hold them
---together: a key that does not apply to the node under the cursor says so and
---does nothing, and no key here shadows a motion. `s` is free because the
---sidebar has no `s` of its own to lose (the grid's `s` sorts, but that is a
---mapping in the *content* buffer, and the two never both apply); `R` is
---deliberately the capital, because the lower-case `r` refreshes and must keep
---doing exactly that; `gl` and `gL` are `g`-prefixed, as `gi` already is, so `l`
---and `L` still move the cursor.
---
---The shared `<Tab>` shadows nothing in the tree either: the tree has no key of
---its own on it, and buffer-local is as far as it reaches — the `<C-i>` most
---terminals send `<Tab>` as still jumps forward everywhere but these two buffers.
---@type SpacetimeKeymap[]
M.KEYMAPS = {
	{
		keys = { "<CR>", "o" },
		desc = "expand or open the node under the cursor",
		action = function()
			M.select()
		end,
	},
	{
		keys = { "s" },
		desc = "show the schema of the table under the cursor",
		action = function()
			M.describe()
		end,
	},
	{
		keys = { "R" },
		desc = "show the reducers of the database the cursor is in",
		action = function()
			M.reducers()
		end,
	},
	{
		keys = { "gl" },
		desc = "show the logs of the database the cursor is in",
		action = function()
			M.logs(false)
		end,
	},
	{
		keys = { "gL" },
		desc = "follow those logs live",
		action = function()
			M.logs(true)
		end,
	},
	{
		keys = { "r" },
		desc = "refresh: drop the cache and fetch again",
		action = function()
			M.refresh()
		end,
	},
	-- Shared with the content window, so `q` and `<Tab>` mean the same thing from
	-- either half of the layout.
	require("spacetime.ui.keys").CLOSE,
	require("spacetime.ui.keys").FOCUS,
	{
		keys = { "y" },
		desc = "yank the node's name",
		action = function()
			M.yank_name()
		end,
	},
	{
		keys = { "gi" },
		desc = "yank the database identity",
		action = function()
			M.yank_identity()
		end,
	},
	{
		keys = { "?" },
		desc = "show this help",
		action = function()
			M.help()
		end,
	},
}

---Print the key map.
---
---`nvim_echo` with `history = true`, as `:SpacetimeStatus` does: help is command
---output that belongs in |:messages|, not a notification a plugin may collapse.
function M.help()
	local lines = { "spacetime.nvim sidebar" }
	for _, map in ipairs(M.KEYMAPS) do
		lines[#lines + 1] = ("  %-10s %s"):format(table.concat(map.keys, " / "), map.desc)
	end
	vim.api.nvim_echo({ { table.concat(lines, "\n") } }, true, {})
end

---Bind every sidebar key, buffer-locally.
---
---Re-applied on every `open()` and idempotent, so a buffer that somehow lost its
---mappings gets them back. The sidebar buffer is its own — nothing else paints
---into it — so the unbinding `ui/keys` does first is a no-op here.
---@param bufnr integer The sidebar buffer.
function M.apply_keymaps(bufnr)
	require("spacetime.ui.keys").apply(bufnr, M.KEYMAPS)
end

return M
