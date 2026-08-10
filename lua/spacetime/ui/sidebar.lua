-- The sidebar controller: everything `:Spacetime` does once the windows exist.
--
-- `ui/buffer.lua` owns the windows and `ui/tree.lua` owns the layout of the
-- text; this module is the part in between — it holds the model, fetches the
-- database list, paints the result, and binds the keys that drive it. It lives
-- under `ui/` and may therefore touch `vim.api`; `lib/` may not.
--
-- Five things this file exists to get right:
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
--    with `state.start` *before* the request is made: a stubbed transport (and,
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
--
-- Every `require` is inside a function body, matching `commands.lua`: this
-- module is only reached by running a command, and `spacetime.commands` requires
-- it back.

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

-- The buffer the content window displaced when the layout opened, so `q` can
-- put it back rather than leaving a `spacetime://content` scratch behind.
local displaced = nil ---@type integer|nil

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
	local rendered = require("spacetime.ui.tree").build_lines(model)
	nodes = rendered.nodes

	-- Read before the write and put back after it: a refetch that keeps the same
	-- databases must not throw the cursor back to the top of the tree.
	local winid = buffer.window_showing(bufnr)
	local row = winid and vim.api.nvim_win_get_cursor(winid)[1] or nil

	buffer.set_lines(bufnr, rendered.lines)

	local namespace = buffer.namespace()
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
	for _, span in ipairs(rendered.spans) do
		vim.api.nvim_buf_set_extmark(bufnr, namespace, span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	if winid and row then
		vim.api.nvim_win_set_cursor(winid, { math.min(row, math.max(#rendered.lines, 1)), 0 })
	end
end

---Write the placeholder into the content buffer, unless it already says
---something. `ui/rows.lua` writes real content there, and reopening the layout
---must never clobber it.
---@param bufnr integer
local function place_placeholder(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if #lines > 1 or (lines[1] or "") ~= "" then
		return
	end
	require("spacetime.ui.buffer").set_lines(bufnr, M.PLACEHOLDER)
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

	-- Registered before the request goes out; see point 2 of the module header.
	local handle = nil ---@type SpacetimeHttpHandle|nil
	local seq = state.start(key, {
		kill = function()
			if handle then
				handle.kill()
			end
		end,
	})

	handle = client:schema(name, nil, function(err, schema)
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
---Matched on either spelling: the config may name a database by its display
---name or by its hex identity, and `SpacetimeDatabaseEntry` carries both.
---@param entries SpacetimeDatabaseEntry[]
local function expand_project_database(entries)
	if type(project_database) ~= "string" or project_database == "" then
		return
	end
	for _, entry in ipairs(entries) do
		if entry.name == project_database or entry.identity == project_database then
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
---`state.start`.
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

	-- Registered before the request goes out; see point 2 of the module header.
	local handle = nil ---@type SpacetimeHttpHandle|nil
	local seq = state.start(key, {
		kill = function()
			if handle then
				handle.kill()
			end
		end,
	})

	handle = client:list_databases(identity, function(err, databases)
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

---Close the layout, cancelling everything in flight.
---
---The cancel comes first and is unconditional: a response landing after the
---windows have gone would repaint a buffer nobody is looking at, and one that
---landed after a wipe would raise.
---
---Neither window is ever the one that closes Neovim. When the content window is
---the last one standing it is handed back the buffer it displaced (or a fresh
---empty one) rather than being closed.
function M.close()
	require("spacetime.state").cancel_all()

	local buffer = require("spacetime.ui.buffer")

	local sidebar_win = sidebar_window()
	if sidebar_win and #vim.api.nvim_tabpage_list_wins(0) > 1 then
		vim.api.nvim_win_close(sidebar_win, true)
	end

	local content_buf = buffer.find(buffer.CONTENT_NAME)
	local content_win = content_buf and buffer.window_showing(content_buf)
	if not content_win then
		return
	end

	if #vim.api.nvim_tabpage_list_wins(0) > 1 then
		vim.api.nvim_win_close(content_win, true)
		return
	end

	local restore = displaced
	if not (restore and vim.api.nvim_buf_is_valid(restore)) then
		restore = vim.api.nvim_create_buf(true, false)
	end
	vim.api.nvim_win_set_buf(content_win, restore)
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

---One sidebar mapping. `keys` is a list because `<CR>` and `o` are the same
---action, and because |:help| renders them as one line.
---@class SpacetimeSidebarKeymap
---@field keys string[]
---@field desc string
---@field action fun()

---Every key the sidebar binds, and the help text `?` prints. One table, so the
---mappings and the help cannot drift apart.
---@type SpacetimeSidebarKeymap[]
M.KEYMAPS = {
	{
		keys = { "<CR>", "o" },
		desc = "expand or open the node under the cursor",
		action = function()
			M.select()
		end,
	},
	{
		keys = { "r" },
		desc = "refresh: drop the cache and fetch again",
		action = function()
			M.refresh()
		end,
	},
	{
		keys = { "q" },
		desc = "close the layout",
		action = function()
			M.close()
		end,
	},
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
---Re-applied on every `open()`: `vim.keymap.set` overwrites, so this is
---idempotent, and a buffer that somehow lost its mappings gets them back.
---@param bufnr integer The sidebar buffer.
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

return M
