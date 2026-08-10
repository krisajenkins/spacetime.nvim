-- Tests for the `:Spacetime*` command set and its completion.
--
-- A child Neovim throughout: the commands are registered by
-- `plugin/spacetime.lua` at startup, and half of what is asserted here is that
-- they really exist in a session that has done nothing else.
--
-- Two load-bearing cases:
--
-- 1. **Completion never fires a request.** `spacetime.lib.http` — the one
--    transport seam, per tests/CLAUDE.md — is replaced in the child by a stub
--    that records any call instead of making one. Completion is then driven for
--    every command that has any, and the recorder must still be empty.
--    Completion runs on each keystroke at the cmdline, so a request here would
--    put traffic on the wire for a user who has not yet asked for anything.
-- 2. **A cache that is empty, or full of the wrong shapes, completes to `{}`
--    rather than raising.** An error out of a completion function surfaces under
--    the cursor mid-keystroke, and there is no good way for the user to make it
--    stop.
--
-- The `cli.toml` these tests complete nicknames from is written into a temporary
-- `XDG_CONFIG_HOME` per case: synthetic, tokenless, and pointedly not the
-- developer's real one.
--
-- Expected candidate lists are sorted here with the same `table.sort` the module
-- uses, so the assertions pin the *set* without also pinning whatever order the
-- runtime's string comparison puts `ledgerEntry` and `ledger_entry` in.
local child, new_set = require("tests.helpers.child")()
local expect = MiniTest.expect

-- The ten commands, in the order `:h spacetime-commands` documents them.
local COMMANDS = {
	"Spacetime",
	"SpacetimeToggle",
	"SpacetimeConnect",
	"SpacetimeDatabases",
	"SpacetimeTables",
	"SpacetimeRows",
	"SpacetimeSchema",
	"SpacetimeLogs",
	"SpacetimeLogsStop",
	"SpacetimeStatus",
}

-- A `cli.toml` with two usable servers and no credential of any kind. The parser
-- only ever reads `nickname` out of a block, so nothing else here matters.
local CLI_TOML = table.concat({
	'default_server = "local"',
	"",
	"[[server_configs]]",
	'nickname = "local"',
	'host = "127.0.0.1:3000"',
	'protocol = "http"',
	"",
	"[[server_configs]]",
	"# A block with no nickname can never be selected, so it must not complete.",
	'host = "10.0.0.1:3000"',
	"",
	"[[server_configs]]",
	'nickname = "testnet"',
	'host = "testnet.spacetimedb.com"',
	'protocol = "https"',
}, "\n")

---@param list string[]
---@return string[]
local function sorted(list)
	local out = vim.deepcopy(list)
	table.sort(out)
	return out
end

local T = new_set({
	pre_case = function(c)
		c.lua(
			[[
				local dir = vim.fn.tempname()
				vim.fn.mkdir(dir .. '/spacetime', 'p')
				vim.fn.writefile(vim.split(..., '\n'), dir .. '/spacetime/cli.toml')
				vim.env.XDG_CONFIG_HOME = dir

				C = require('spacetime.commands')
				STATE = require('spacetime.state')

				-- Every notification the plugin makes, captured rather than shown.
				NOTIFIED = {}
				vim.notify = function(msg) NOTIFIED[#NOTIFIED + 1] = msg end
			]],
			{ CLI_TOML }
		)
	end,
})

---Seed the cache with a database list, one schema and one rows entry.
local function seed_cache()
	child.lua([[
		STATE.cache_set(C.DATABASES_KEY, {
			{ identity = 'aa', name = 'spacegym', names = { 'spacegym' } },
			{ identity = 'bb', name = 'spacetutorial', names = { 'spacetutorial' } },
		})
		STATE.cache_set(STATE.key('schema', 'spacegym'), {
			tables = {
				{ name = 'ledgerEntry', canonical = 'ledger_entry' },
				{ name = 'member', canonical = 'member' },
			},
			views = { { name = 'activeMembers', canonical = 'active_members' } },
		})
		STATE.cache_set(STATE.key('rows', 'archive', 'old_rows'), { rows = {} })
	]])
end

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

---`:command`'s view of the commands, reduced to what serialises: a Lua-function
---`complete` field cannot cross the RPC boundary, so the interesting fields are
---picked out inside the child.
---@return table<string, { nargs: string, bang: boolean, complete: boolean }>
local function defined_commands()
	return child.lua_get([[
		vim.tbl_map(function(command)
			return { nargs = command.nargs, bang = command.bang, complete = command.complete ~= nil }
		end, vim.api.nvim_get_commands({}))
	]])
end

T["every command exists in a session that has done nothing else"] = function()
	local defined = defined_commands()
	for _, name in ipairs(COMMANDS) do
		expect.equality({ name, defined[name] ~= nil }, { name, true })
	end
end

T["the specs and the registered commands are the same list"] = function()
	expect.equality(child.lua_get("vim.tbl_map(function(spec) return spec.name end, C.COMMANDS)"), COMMANDS)
end

T["arguments are optional, required or forbidden per command"] = function()
	local defined = defined_commands()

	expect.equality(defined.Spacetime.nargs, "0")
	expect.equality(defined.SpacetimeToggle.nargs, "0")
	expect.equality(defined.SpacetimeConnect.nargs, "?")
	expect.equality(defined.SpacetimeDatabases.nargs, "0")
	expect.equality(defined.SpacetimeTables.nargs, "?")
	expect.equality(defined.SpacetimeRows.nargs, "1")
	expect.equality(defined.SpacetimeSchema.nargs, "1")
	expect.equality(defined.SpacetimeLogs.nargs, "?")
	expect.equality(defined.SpacetimeLogsStop.nargs, "0")
	expect.equality(defined.SpacetimeStatus.nargs, "0")
end

T["only :SpacetimeLogs takes a bang"] = function()
	local defined = defined_commands()
	for _, name in ipairs(COMMANDS) do
		expect.equality({ name, defined[name].bang }, { name, name == "SpacetimeLogs" })
	end
end

T["exactly the commands that take a name have completion"] = function()
	local defined = defined_commands()
	local completes = {
		SpacetimeConnect = true,
		SpacetimeTables = true,
		SpacetimeRows = true,
		SpacetimeSchema = true,
		SpacetimeLogs = true,
	}
	for _, name in ipairs(COMMANDS) do
		expect.equality({ name, defined[name].complete }, { name, completes[name] == true })
	end
end

--------------------------------------------------------------------------------
-- Bodies
--------------------------------------------------------------------------------

T["an unimplemented command notifies rather than raising"] = function()
	child.lua([[ expect.no_error(function() vim.cmd('SpacetimeTables') end) ]])

	local notified = child.lua_get("NOTIFIED")
	expect.equality(#notified, 1)
	expect.equality(notified[1]:find("SpacetimeTables", 1, true) ~= nil, true)
	expect.equality(notified[1]:find("not implemented yet", 1, true) ~= nil, true)
end

T["every unimplemented command notifies once, and none of them raise"] = function()
	-- `:Spacetime` is excluded because it really does something, and
	-- `:SpacetimeStatus` has a file of its own.
	child.lua(
		[[
		for _, command in ipairs(...) do
			expect.no_error(function() vim.cmd(command) end)
		end
	]],
		{
			{
				"SpacetimeToggle",
				"SpacetimeConnect",
				"SpacetimeConnect testnet",
				"SpacetimeDatabases",
				"SpacetimeTables spacegym",
				"SpacetimeRows spacegym.member",
				"SpacetimeSchema spacegym.member",
				"SpacetimeLogsStop",
			},
		}
	)

	expect.equality(#child.lua_get("NOTIFIED"), 8)
end

T[":SpacetimeLogs parses its bang"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs') ]])
	child.lua([[ vim.cmd('SpacetimeLogs!') ]])

	local notified = child.lua_get("NOTIFIED")
	expect.equality(#notified, 2)
	expect.equality(notified[1]:find("SpacetimeLogs!", 1, true), nil)
	expect.equality(notified[2]:find("SpacetimeLogs!", 1, true) ~= nil, true)
end

T[":Spacetime opens the layout"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])

	local names = child.lua_get([[
		vim.tbl_map(function(winid)
			return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(winid))
		end, vim.api.nvim_tabpage_list_wins(0))
	]])
	expect.equality(sorted(names), { "spacetime://content", "spacetime://sidebar" })
	-- Opening the layout is not a "not implemented" case, so it says nothing.
	expect.equality(#child.lua_get("NOTIFIED"), 0)
end

--------------------------------------------------------------------------------
-- Completion
--------------------------------------------------------------------------------

T["server completion comes from the cli.toml nicknames"] = function()
	expect.equality(child.lua_get([[C.complete_server('')]]), sorted({ "local", "testnet" }))
	expect.equality(child.lua_get([[C.complete_server('te')]]), { "testnet" })
	expect.equality(child.lua_get([[#C.complete_server('nope')]]), 0)
end

T["a missing cli.toml completes to an empty list"] = function()
	child.lua([[ vim.env.XDG_CONFIG_HOME = '/nonexistent-spacetime-test' ]])
	expect.equality(child.lua_get([[#C.complete_server('')]]), 0)
end

T["database completion comes from the cache"] = function()
	seed_cache()

	-- `archive` is known only from its `rows:` key; the other two from the list.
	expect.equality(child.lua_get([[C.complete_database('')]]), sorted({ "archive", "spacegym", "spacetutorial" }))
	expect.equality(child.lua_get([[C.complete_database('spacet')]]), { "spacetutorial" })
	expect.equality(child.lua_get([[#C.complete_database('nope')]]), 0)
end

T["table completion offers db.table in both spellings"] = function()
	seed_cache()

	expect.equality(
		child.lua_get([[C.complete_table('')]]),
		sorted({
			"archive.old_rows",
			"spacegym.activeMembers",
			"spacegym.active_members",
			"spacegym.ledgerEntry",
			"spacegym.ledger_entry",
			"spacegym.member",
		})
	)
	expect.equality(
		child.lua_get([[C.complete_table('spacegym.led')]]),
		sorted({ "spacegym.ledgerEntry", "spacegym.ledger_entry" })
	)
end

T["completion is wired to the commands themselves"] = function()
	seed_cache()

	expect.equality(child.lua_get([[vim.fn.getcompletion('SpacetimeConnect loc', 'cmdline')]]), { "local" })
	expect.equality(child.lua_get([[vim.fn.getcompletion('SpacetimeTables spacet', 'cmdline')]]), { "spacetutorial" })
	expect.equality(child.lua_get([[vim.fn.getcompletion('SpacetimeLogs arch', 'cmdline')]]), { "archive" })
	expect.equality(
		child.lua_get([[vim.fn.getcompletion('SpacetimeRows spacegym.mem', 'cmdline')]]),
		{ "spacegym.member" }
	)
	expect.equality(
		child.lua_get([[vim.fn.getcompletion('SpacetimeSchema spacegym.mem', 'cmdline')]]),
		{ "spacegym.member" }
	)
end

T["an empty cache completes to an empty list rather than erroring"] = function()
	child.lua([[ STATE.cache_clear() ]])

	child.lua([[
		expect.no_error(function()
			expect.equality(C.complete_database(''), {})
			expect.equality(C.complete_table(''), {})
			expect.equality(vim.fn.getcompletion('SpacetimeTables ', 'cmdline'), {})
		end)
	]])
end

T["a cache full of the wrong shapes still completes cleanly"] = function()
	child.lua([[
		STATE.cache_set(C.DATABASES_KEY, 'not a list')
		STATE.cache_set('schema:broken', { tables = 42, views = { 'nonsense', {} } })
		STATE.cache_set('rows:', {})
	]])

	child.lua([[
		expect.no_error(function()
			expect.equality(C.complete_database('nope'), {})
			expect.equality(C.complete_table(''), {})
		end)
	]])
	-- `schema:broken` still names a database, even though its payload is unusable.
	expect.equality(child.lua_get([[C.complete_database('')]]), { "broken" })
end

T["completion never fires a request"] = function()
	seed_cache()

	-- The one transport seam (tests/CLAUDE.md). Anything reaching it is recorded
	-- rather than run, so the assertion is on the recorder — not on a network
	-- that merely happened to be unreachable.
	child.lua([[
		REQUESTED = {}
		package.loaded['spacetime.lib.http'] = {
			request = function() REQUESTED[#REQUESTED + 1] = 'request' end,
			stream = function() REQUESTED[#REQUESTED + 1] = 'stream' end,
			build = function() REQUESTED[#REQUESTED + 1] = 'build' end,
		}
		-- `lib.client` sits on top of it, and must not be reached either.
		package.loaded['spacetime.lib.client'] = setmetatable({}, {
			__index = function()
				REQUESTED[#REQUESTED + 1] = 'client'
				return function() end
			end,
		})
	]])

	for _, line in ipairs({
		"SpacetimeConnect ",
		"SpacetimeTables ",
		"SpacetimeLogs ",
		"SpacetimeRows ",
		"SpacetimeSchema spacegym.",
	}) do
		child.lua("vim.fn.getcompletion(..., 'cmdline')", { line })
	end

	expect.equality(child.lua_get("#REQUESTED"), 0)
	-- And completion really did run: it produced candidates from the cache.
	expect.equality(child.lua_get([[vim.fn.getcompletion('SpacetimeTables ', 'cmdline')]]), {
		"archive",
		"spacegym",
		"spacetutorial",
	})
end

return T
