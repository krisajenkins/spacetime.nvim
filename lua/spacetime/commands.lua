-- Every `:Spacetime*` command: one table of specs, one registration loop.
--
-- The module sits in `lua/spacetime/` rather than `lib/` because it calls
-- `nvim_create_user_command` and reads `vim.env`; `lib/` is pure logic and may
-- not touch `vim.api`/`vim.fn`/`vim.ui`/`vim.notify` at all.
--
-- **Require-on-invoke.** `plugin/spacetime.lua` requires this file at startup so
-- the commands exist before `setup()` is called, which means this file must stay
-- as cheap as the plugin file itself: nothing above the fold pulls in
-- `config.lua`, `clitoml.lua`, `state.lua` or a UI module. Every `require` is
-- inside a function body, so a session that never runs a `:Spacetime*` command
-- never loads any of it.
--
-- **Completion reads the cache and nothing else.** No completion function here
-- may start a request — pressing `<Tab>` at a command line must not put traffic
-- on the wire, because completion fires on every keystroke and the user has not
-- asked for anything yet. The consequence is deliberate: a name the plugin has
-- never fetched does not complete. `:SpacetimeConnect` is the one that touches
-- the filesystem, reading `cli.toml` for its nicknames — a local file read, not
-- a request, and only the `nickname` field is ever looked at, never a token.
-- Every completion is wrapped in `pcall` and falls back to an empty list: an
-- error raised out of a completion function is printed under the user's cursor
-- mid-keystroke, which is worse than completing nothing.
--
-- **Switching server is a session fact, not a configuration change.**
-- `:SpacetimeConnect` writes nothing back into `require("spacetime").config` —
-- `spacetime.config` holds the selection for the session and puts it at the top
-- of the resolution chain, and `:SpacetimeConnect!` drops it again. What this
-- file owns is the consequences: everything cached and everything in flight
-- belongs to the server being left, so both go before the sidebar re-resolves.

local M = {}

---The flat cache key the database list lives under, once something fetches it
---(roadmap task 24). Not built from `state.key`, whose key space is per-database
---(`schema:`/`rows:`/`logs:`) and has no room for a session-wide list.
M.DATABASES_KEY = "databases"

--------------------------------------------------------------------------------
-- Completion
--------------------------------------------------------------------------------

---The response cache, or an empty table when `state` has not been touched yet.
---@return table<string,any>
local function cache()
	return require("spacetime.state").data.cache
end

---Keys of `set`, sorted. Completion is offered in a stable order so the same
---cache always produces the same menu.
---@param set table<string,boolean>
---@return string[]
local function sorted_keys(set)
	local out = {}
	for name in pairs(set) do
		out[#out + 1] = name
	end
	table.sort(out)
	return out
end

---Keep the candidates `arg_lead` is a prefix of.
---
---Neovim does no filtering of its own for a `complete=` function, so a command
---that returned everything would show the full list however much was typed.
---@param candidates string[]
---@param arg_lead any The `ArgLead` Neovim passes; anything but a string reads as `""`.
---@return string[]
local function matching(candidates, arg_lead)
	local lead = type(arg_lead) == "string" and arg_lead or ""
	local out = {}
	for _, candidate in ipairs(candidates) do
		if candidate:sub(1, #lead) == lead then
			out[#out + 1] = candidate
		end
	end
	return out
end

---Wrap a candidate-producing function so it can never raise into the cmdline.
---@param produce fun(): string[]
---@param arg_lead any
---@return string[]
local function complete(produce, arg_lead)
	local ok, candidates = pcall(produce)
	if not ok or type(candidates) ~= "table" then
		return {}
	end
	return matching(candidates, arg_lead)
end

---The `nickname` of every `[[server_configs]]` block in the CLI's `cli.toml`.
---
---A local file read, not a request. `clitoml.read` is total — a missing or
---malformed file yields an empty config — so a machine that has never run
---`spacetime login` completes nothing rather than complaining. Only `nickname`
---is read; the tokens in that file are never touched here.
---@return string[]
local function cli_nicknames()
	local path = require("spacetime.config").cli_config_path(vim.env)
	if not path then
		return {}
	end

	local seen = {}
	for _, server in ipairs(require("spacetime.lib.clitoml").read(path).server_configs) do
		if type(server.nickname) == "string" and server.nickname ~= "" then
			seen[server.nickname] = true
		end
	end
	return sorted_keys(seen)
end

---Every database name the cache knows of.
---
---Two sources, unioned: the database list itself (`M.DATABASES_KEY`), and the
---names embedded in the per-database cache keys — anything already fetched
---*about* a database names it in its own key, so a session that expanded one
---database can complete it even before the list lands.
---@return string[]
local function cached_databases()
	local seen = {}

	local entries = cache()[M.DATABASES_KEY]
	if type(entries) == "table" then
		-- Tolerant of both shapes: a `SpacetimeDatabaseEntry[]` from
		-- `client.list_databases`, or a plain list of names.
		for _, entry in ipairs(entries) do
			local name = entry
			if type(entry) == "table" then
				name = entry.name
			end
			if type(name) == "string" and name ~= "" then
				seen[name] = true
			end
		end
	end

	for key in pairs(cache()) do
		-- Non-greedy up to the *first* dot, matching how `cache_invalidate_db`
		-- reads a `rows:` key: `state.key` joins database and table with one.
		local db = key:match("^schema:(.+)$") or key:match("^logs:(.+)$") or key:match("^rows:(.-)%.")
		if db and db ~= "" then
			seen[db] = true
		end
	end

	return sorted_keys(seen)
end

---Every `db.table` the cache can name.
---
---Both spellings of a table are offered where they differ — the SQL layer takes
---`ledgerEntry` and `ledger_entry` alike, and so should the completion — plus
---views, which `:SpacetimeRows` and `:SpacetimeSchema` treat as tables.
---
---Only the qualified form is produced. `[db.]tbl` accepts a bare table name too,
---but which database a bare name means is a runtime decision (the project config,
---the sidebar's selection) that completion has no business guessing at.
---@return string[]
local function cached_qualified_tables()
	local seen = {}

	---@param db string
	---@param entries any
	local function add_all(db, entries)
		if type(entries) ~= "table" then
			return
		end
		for _, entry in ipairs(entries) do
			if type(entry) == "table" then
				-- Written out rather than looped over `{entry.canonical, entry.name}`:
				-- `ipairs` stops at the first `nil`, so a table with no `canonical`
				-- would silently lose its display name too (tests/CLAUDE.md).
				if type(entry.canonical) == "string" and entry.canonical ~= "" then
					seen[db .. "." .. entry.canonical] = true
				end
				if type(entry.name) == "string" and entry.name ~= "" then
					seen[db .. "." .. entry.name] = true
				end
			end
		end
	end

	for key, value in pairs(cache()) do
		local schema_db = key:match("^schema:(.+)$")
		if schema_db and type(value) == "table" then
			add_all(schema_db, value.tables)
			add_all(schema_db, value.views)
		end

		-- A `rows:` key names a table that was queried at least once, which is a
		-- good candidate whether or not its schema is still cached.
		local rows_db, rows_table = key:match("^rows:(.-)%.(.+)$")
		if rows_db and rows_db ~= "" then
			seen[rows_db .. "." .. rows_table] = true
		end
	end

	return sorted_keys(seen)
end

---Complete a `cli.toml` server nickname. For `:SpacetimeConnect`.
---@param arg_lead string
---@return string[]
function M.complete_server(arg_lead)
	return complete(cli_nicknames, arg_lead)
end

---Complete a cached database name. For `:SpacetimeReducers` and
---`:SpacetimeLogs`.
---@param arg_lead string
---@return string[]
function M.complete_database(arg_lead)
	return complete(cached_databases, arg_lead)
end

---Complete a cached `db.table`. For `:SpacetimeRows` and `:SpacetimeSchema`.
---@param arg_lead string
---@return string[]
function M.complete_table(arg_lead)
	return complete(cached_qualified_tables, arg_lead)
end

--------------------------------------------------------------------------------
-- Command bodies
--------------------------------------------------------------------------------

---Everything a server switch invalidates, dropped in one place.
---
---The cache is cleared whole rather than key by key: every entry in it — the
---database list, each schema, each page of rows — is an answer the *old* server
---gave, and none of it is worth keeping against the chance that the new one
---agrees. In-flight requests go the same way, and a log follow needs the extra
---word `ui/sidebar.close()` documents: `cancel_all` kills its `curl`, but the
---repeating flush timer is the log view's own and only its teardown closes it.
local function drop_everything()
	local state = require("spacetime.state")
	state.cancel_all()
	require("spacetime.ui.logs").teardown()
	state.cache_clear()
end

---Print the server we are on and the ones `cli.toml` offers. `:SpacetimeConnect`
---with no argument.
---
---`nvim_echo` with `history = true`, as |:SpacetimeStatus| does: command output
---belongs in |:messages| where it can be read back, not in a notification a
---plugin may collapse.
local function report_servers()
	local config = require("spacetime.config")

	local connection, err = config.current(vim.api.nvim_get_current_buf())
	local current = connection and ("%s (%s)"):format(connection.server or connection.host, connection.url)
		or (err or "could not be resolved")

	local lines = { "server:     " .. current }
	if config.selected_server() then
		lines[#lines + 1] = "selected:   " .. config.selected_server() .. " (:SpacetimeConnect! to undo)"
	end

	local nicknames = cli_nicknames()
	lines[#lines + 1] = "available:  " .. (#nicknames > 0 and table.concat(nicknames, ", ") or "(none in cli.toml)")

	vim.api.nvim_echo({ { table.concat(lines, "\n") } }, true, {})
end

---Switch to a `cli.toml` server nickname. What `:SpacetimeConnect [nick]` does.
---
---With no argument it reports rather than switches, because a command that
---changes where you are pointed should need you to say where. The bang is the
---undo: it drops the selection and goes back to whatever the configuration
---resolves to, which is the only way back when the original address came from a
---`host`/`port` rather than from a nickname you could retype.
---@param arg string The command's one argument; empty when it was omitted.
---@param bang boolean Forget the selection instead of making one.
local function connect(arg, bang)
	local logger = require("spacetime.logger")
	local config = require("spacetime.config")

	if bang then
		if not config.clear_server() then
			logger.info("no server has been selected with :SpacetimeConnect")
			return
		end
		drop_everything()
		require("spacetime.ui.sidebar").reconnect()
		local connection = config.current(vim.api.nvim_get_current_buf())
		logger.info(("back to the configured server: %s"):format(connection and connection.url or "unresolved"))
		return
	end

	if arg == "" then
		report_servers()
		return
	end

	-- Resolved against the *current* buffer, before anything is torn down: which
	-- database a nickname lands on still depends on the project config governing
	-- the buffer the user ran this from, exactly as `:SpacetimeRows` does.
	local connection, err = config.select_server(arg, vim.api.nvim_get_current_buf())
	if not connection then
		-- The selection is unchanged — `select_server` puts it back — so this is a
		-- refusal, not a half-switch.
		logger.error(err or ("could not switch to " .. arg))
		return
	end

	drop_everything()
	require("spacetime.ui.sidebar").reconnect()
	logger.info(("connected to %s (%s)"):format(arg, connection.url))
end

---The schema entry `table_name` names in `database`, from the cache only.
---
---Never fetches. A database the user has expanded this session has its schema in
---hand, and it supplies the primary keys and the types a `Ref` resolves through;
---one they have not means the grid renders without those rather than this
---command putting a second request on the wire behind the rows query.
---
---Both spellings match, as completion offers both: `ledgerEntry` and
---`ledger_entry` are the same table.
---@param database string
---@param table_name string
---@return SpacetimeSchemaTable|SpacetimeSchemaView|nil entry
---@return SpacetimeSchema|nil schema
local function cached_entry(database, table_name)
	local state = require("spacetime.state")
	local schema = state.cache_get(state.key("schema", database))
	if type(schema) ~= "table" then
		return nil, nil
	end
	-- Both spellings, tables before views: `lib/schema` owns that rule, and the
	-- schema view resolves the same name the same way.
	return require("spacetime.lib.schema").entry_by_name(schema, table_name), schema
end

---Split a `[db.]table` argument and resolve the connection it belongs to.
---
---The argument splits on its first dot: `spacegym.member` names both halves,
---`member` alone means the database the project config resolved to. Which is
---why the connection is resolved from the *current* buffer, before the layout
---displaces it — the same ordering, for the same reason, as point 1 of
---`ui/sidebar.lua`'s header.
---
---Every failure is reported here and answers `nil`, so a caller has one thing to
---check and the two commands that take a table cannot word the same complaint
---two different ways.
---@param arg string The command's one argument.
---@param command string The command as the user typed it, for the messages.
---@return SpacetimeConnection|nil connection
---@return string|nil database
---@return string|nil table_name
local function table_target(arg, command)
	local logger = require("spacetime.logger")

	local database, table_name = arg:match("^([^.]+)%.(.+)$")
	if not database then
		table_name = arg
	end
	if type(table_name) ~= "string" or table_name == "" then
		logger.warn(command .. " needs a table name, as [database.]table")
		return nil, nil, nil
	end

	local connection, err = require("spacetime.config").current(vim.api.nvim_get_current_buf())
	if not connection then
		logger.error(err or "no connection could be resolved")
		return nil, nil, nil
	end

	database = database or connection.database
	if type(database) ~= "string" or database == "" then
		logger.warn(("no database is configured here: write it as db.%s"):format(table_name))
		return nil, nil, nil
	end

	return connection, database, table_name
end

---Resolve the database a `[db]` argument means, and the connection it belongs to.
---
---The bare-argument sibling of `table_target`: with no argument the database is
---the one the resolved connection carries — the project's `spacetime.json`, the
---environment, or whatever `setup()` was given — which is what "the currently
---selected database" amounts to outside the sidebar. As there, the connection is
---resolved from the *current* buffer, before the layout displaces it.
---
---Every failure is reported here and answers `nil`, so a caller has one thing to
---check.
---@param arg string The command's one argument; empty when it was omitted.
---@param command string The command as the user typed it, for the messages.
---@return SpacetimeConnection|nil connection
---@return string|nil database
local function database_target(arg, command)
	local logger = require("spacetime.logger")

	local connection, err = require("spacetime.config").current(vim.api.nvim_get_current_buf())
	if not connection then
		logger.error(err or "no connection could be resolved")
		return nil, nil
	end

	local database = (type(arg) == "string" and arg ~= "") and arg or connection.database
	if type(database) ~= "string" or database == "" then
		logger.warn(("no database is configured here: write it as %s <database>"):format(command))
		return nil, nil
	end

	return connection, database
end

---Open the browser on `[db.]table`'s rows. What `:SpacetimeRows` does.
---@param arg string The command's one argument.
local function open_rows(arg)
	local connection, database, table_name = table_target(arg, ":SpacetimeRows")
	if not connection or not database or not table_name then
		return
	end

	local entry, schema = cached_entry(database, table_name)

	-- The layout first: `ui/rows.lua` paints into the content buffer, and there
	-- is no content buffer until the browser is open.
	require("spacetime.ui.sidebar").open()
	require("spacetime.ui.rows").open({
		connection = connection,
		database = database,
		-- The canonical name is what SQL takes; the source spelling is what the
		-- user typed and what the messages should say.
		table_name = entry and entry.canonical or table_name,
		label = entry and entry.name or table_name,
		entry = entry,
		schema = schema,
	})
end

---Show `[db.]table`'s schema. What `:SpacetimeSchema` does.
---
---No cache lookup here, unlike `open_rows`: the schema view needs the whole
---model rather than one entry, and it fetches the model itself when the session
---has not already got it. Either spelling of the table is handed straight
---through — the view resolves it against the schema it ends up with.
---@param arg string The command's one argument.
local function open_schema(arg)
	local connection, database, table_name = table_target(arg, ":SpacetimeSchema")
	if not connection or not database or not table_name then
		return
	end

	-- The layout first: `ui/schema.lua` paints into the content buffer, and there
	-- is no content buffer until the browser is open.
	require("spacetime.ui.sidebar").open()
	require("spacetime.ui.schema").open({
		connection = connection,
		database = database,
		table_name = table_name,
	})
end

---Show `[db]`'s reducers. What `:SpacetimeReducers` does.
---
---No cache lookup here, as in `open_schema`: the view needs the whole model
---rather than one entry, and it fetches the model itself when the session has not
---already got it.
---@param arg string The command's one argument; empty when it was omitted.
local function open_reducers(arg)
	local connection, database = database_target(arg, ":SpacetimeReducers")
	if not connection or not database then
		return
	end

	-- The layout first: `ui/reducers.lua` paints into the content buffer, and there
	-- is no content buffer until the browser is open.
	require("spacetime.ui.sidebar").open()
	require("spacetime.ui.reducers").open({ connection = connection, database = database })
end

---Show `[db]`'s logs. What `:SpacetimeLogs[!]` does.
---@param arg string The command's one argument; empty when it was omitted.
---@param follow boolean The bang: keep the connection open and stream.
local function open_logs(arg, follow)
	local connection, database = database_target(arg, ":SpacetimeLogs")
	if not connection or not database then
		return
	end

	-- The layout first: `ui/logs.lua` paints into the content buffer, and there is
	-- no content buffer until the browser is open — nor anything for the follow's
	-- `BufWipeout` autocommand to attach to.
	require("spacetime.ui.sidebar").open()
	require("spacetime.ui.logs").open({ connection = connection, database = database, follow = follow })
end

---One user command, as `M.register` needs it.
---@class SpacetimeCommandSpec
---@field name string Command name, without the colon.
---@field run fun(cmd: table) Receives `nvim_create_user_command`'s argument table.
---@field desc string Shown in `:command` and by completion UIs.
---@field nargs? string|integer Passed straight through; omitted means `0`.
---@field bang? boolean
---@field complete? fun(arg_lead: string, cmd_line: string, cursor_pos: integer): string[]

---Every command the plugin defines, in the order the documentation lists them.
---@type SpacetimeCommandSpec[]
M.COMMANDS = {
	{
		name = "Spacetime",
		desc = "Open the SpacetimeDB browser",
		-- The single front door: both windows, the database tree, and the keymaps
		-- that drive it. A cached list renders without a request.
		run = function()
			require("spacetime.ui.sidebar").open()
		end,
	},
	{
		name = "SpacetimeToggle",
		desc = "Toggle the SpacetimeDB browser",
		run = function()
			require("spacetime.ui.sidebar").toggle()
		end,
	},
	{
		name = "SpacetimeConnect",
		desc = "Switch to a cli.toml server nickname; with ! forget the switch",
		nargs = "?",
		bang = true,
		complete = M.complete_server,
		run = function(cmd)
			connect(cmd.args, cmd.bang == true)
		end,
	},
	{
		name = "SpacetimeDatabases",
		desc = "List the databases for the current identity",
		-- The sidebar *is* the database list, so this is `:Spacetime` with the
		-- cache dropped: asking for the list explicitly means asking for a fresh one.
		run = function()
			require("spacetime.ui.sidebar").open({ refresh = true })
		end,
	},
	{
		name = "SpacetimeRows",
		desc = "Browse the rows of [db.]table",
		nargs = 1,
		complete = M.complete_table,
		run = function(cmd)
			open_rows(cmd.args)
		end,
	},
	{
		name = "SpacetimeSchema",
		desc = "Show the schema of [db.]table",
		nargs = 1,
		complete = M.complete_table,
		run = function(cmd)
			open_schema(cmd.args)
		end,
	},
	{
		name = "SpacetimeReducers",
		desc = "Show a database's reducers",
		nargs = "?",
		-- A database, not a table: the reducers belong to the module rather than to
		-- any one of its tables, which is why they are not in the schema view.
		complete = M.complete_database,
		run = function(cmd)
			open_reducers(cmd.args)
		end,
	},
	{
		name = "SpacetimeLogs",
		desc = "Show a database's logs; with ! follow them",
		nargs = "?",
		bang = true,
		complete = M.complete_database,
		-- The bang is the follow/static switch: `!` streams until
		-- `:SpacetimeLogsStop`, the buffer goes or Neovim exits; without it the
		-- backlog is fetched once and the connection closes.
		run = function(cmd)
			open_logs(cmd.args, cmd.bang == true)
		end,
	},
	{
		name = "SpacetimeLogsStop",
		desc = "Stop following logs",
		run = function()
			require("spacetime.ui.logs").stop()
		end,
	},
	{
		name = "SpacetimeStatus",
		desc = "Show the resolved SpacetimeDB connection",
		run = function()
			require("spacetime.status").show()
		end,
	},
}

---Define every `:Spacetime*` command.
---
---Called once, from `plugin/spacetime.lua`. Idempotent in the sense that
---`nvim_create_user_command` overwrites a command of the same name, so a reload
---during development replaces the definitions rather than failing.
function M.register()
	for _, spec in ipairs(M.COMMANDS) do
		vim.api.nvim_create_user_command(spec.name, spec.run, {
			desc = spec.desc,
			nargs = spec.nargs,
			bang = spec.bang,
			complete = spec.complete,
			-- Safe to chain with `|`: none of these takes a `|` in an argument.
			bar = true,
		})
	end
end

return M
