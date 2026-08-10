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
-- **The not-implemented seam.** Most of the command set is scaffolding for
-- roadmap tasks 24-33. Those bodies call `todo()`, which notifies through
-- `spacetime.logger` — a message, never an error and never a stack trace. A
-- later task replaces exactly one `run` field in `M.COMMANDS` and deletes its
-- `todo` call; nothing else about the command (its name, `nargs`, `bang` or
-- completion) has to move.

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

---Complete a cached database name. For `:SpacetimeTables` and `:SpacetimeLogs`.
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

---Report a command whose feature has not been built yet.
---
---A notification, deliberately: a user who types a real command name has done
---nothing wrong, so this must not look like a bug in their config. Every call
---site here disappears when its roadmap task lands.
---@param name string The command as the user typed it, colon included.
---@param task integer The ROADMAP.md task that will implement it.
local function todo(name, task)
	require("spacetime.logger").warn(("%s is not implemented yet (roadmap task %d)"):format(name, task))
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
---
---A later task implements one of these by replacing its `run` field; the name,
---argument count and completion are already settled here.
---@type SpacetimeCommandSpec[]
M.COMMANDS = {
	{
		name = "Spacetime",
		desc = "Open the SpacetimeDB browser",
		-- The layout primitive (task 21) is finished, so this is real: it opens or
		-- re-focuses the sidebar/content pair. Filling the sidebar with the
		-- database tree, and the keymaps that drive it, belong to task 24.
		run = function()
			require("spacetime.ui.buffer").open_layout()
		end,
	},
	{
		name = "SpacetimeToggle",
		desc = "Toggle the SpacetimeDB browser",
		-- Closing the layout is task 24's `q`, which also has to cancel whatever is
		-- in flight; a toggle that only half-existed would be worse than none.
		run = function()
			todo(":SpacetimeToggle", 24)
		end,
	},
	{
		name = "SpacetimeConnect",
		desc = "Switch to a cli.toml server nickname",
		nargs = "?",
		complete = M.complete_server,
		run = function()
			todo(":SpacetimeConnect", 24)
		end,
	},
	{
		name = "SpacetimeDatabases",
		desc = "List the databases for the current identity",
		run = function()
			todo(":SpacetimeDatabases", 24)
		end,
	},
	{
		name = "SpacetimeTables",
		desc = "List the tables of a database",
		nargs = "?",
		complete = M.complete_database,
		run = function()
			todo(":SpacetimeTables", 25)
		end,
	},
	{
		name = "SpacetimeRows",
		desc = "Browse the rows of [db.]table",
		nargs = 1,
		complete = M.complete_table,
		run = function()
			todo(":SpacetimeRows", 27)
		end,
	},
	{
		name = "SpacetimeSchema",
		desc = "Show the schema of [db.]table",
		nargs = 1,
		complete = M.complete_table,
		run = function()
			todo(":SpacetimeSchema", 30)
		end,
	},
	{
		name = "SpacetimeLogs",
		desc = "Show a database's logs; with ! follow them",
		nargs = "?",
		bang = true,
		complete = M.complete_database,
		-- The bang is the follow/static switch (tasks 31 and 32), so it is parsed
		-- here rather than left for later: the two are separate features and the
		-- placeholder should say which one was asked for.
		run = function(cmd)
			if cmd.bang then
				todo(":SpacetimeLogs!", 32)
			else
				todo(":SpacetimeLogs", 31)
			end
		end,
	},
	{
		name = "SpacetimeLogsStop",
		desc = "Stop following logs",
		run = function()
			todo(":SpacetimeLogsStop", 32)
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
