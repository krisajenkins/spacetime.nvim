-- Tests for the sidebar controller: `:Spacetime` as the single front door.
--
-- A child Neovim throughout — windows, buffer-local keymaps, extmarks and
-- registers are all real editor state. The transport seam `spacetime.lib.http`
-- is stubbed, never `spacetime.lib.client` (tests/CLAUDE.md), so the client's
-- own fan-out is genuinely exercised: the `/databases` request, one `/names`
-- request per identity, the completion counter, and the one place in the client
-- where a callback carries *both* an error and a list.
--
-- The stub answers from a `RESPONDER` global the cases reassign, and records
-- every URL it is asked for plus every `kill()`. A responder that returns
-- nothing simply never calls back, which is how "in flight" is modelled without
-- a timer.
--
-- Three environment precautions, all deliberate:
--
-- * `XDG_CONFIG_HOME` points at an empty temporary directory, so the developer's
--   real `cli.toml` is never read and no live token can reach these tests.
-- * The `SPACETIMEDB_*` variables are cleared, so a developer shell that has
--   them set cannot change what the config chain resolves.
-- * The identity is supplied through `setup({identity = …})`, the documented
--   override, so nothing here needs a token to derive one from.
--
-- The `q` case relies on the layout being two windows of a tabpage that has no
-- others: closing the sidebar leaves one window, and the content window is
-- handed back the buffer it displaced rather than being closed — which is what
-- keeps the child alive (the tests/CLAUDE.md gotcha) *and* what the user wants.
local child, new_set = require("tests.helpers.child")()
local expect = MiniTest.expect
local read = require("tests.helpers.fixtures").read

-- Two databases, each with one name. `identity_hex` strips a leading `0x`, so
-- these are plain hex-ish strings; the shape with `__identity__` is the one the
-- client documents as unverified-but-accepted.
--
-- `MINI_SCHEMA` is the smallest thing `lib/schema.parse` accepts — a v9 document
-- with one table — so the cases that are not *about* the schema still get a
-- child line out of an expansion without carrying the 95 KB live fixture. The
-- cases that are about it install the fixture through `SCHEMA_RESPONDER`.
local DEFAULT_RESPONDER = [[
	MINI_SCHEMA = '{"typespace":{"types":[]},"tables":[{"name":"widget"}]}'

	RESPONDER = function(url)
		if url:find('/v1/identity/', 1, true) then
			return { status = 200, body = '{"identities":[{"__identity__":"aa11"},{"__identity__":"bb22"}]}' }
		end
		local db = url:match('/v1/database/(.-)/names')
		if db == 'aa11' then return { status = 200, body = '{"names":["spacegym"]}' } end
		if db == 'bb22' then return { status = 200, body = '{"names":["spacetutorial"]}' } end
		if url:find('/schema?', 1, true) then return { status = 200, body = MINI_SCHEMA } end
		return { status = 404, body = 'no such database' }
	end

	-- Answer schema requests with `reply`, leaving the rest of the responder
	-- alone: a case that cares about one endpoint should have to spell out only
	-- that endpoint.
	SCHEMA_RESPONDER = function(reply)
		local base = RESPONDER
		RESPONDER = function(url)
			if url:find('/schema?', 1, true) then return reply(url) end
			return base(url)
		end
	end
]]

local T = new_set({
	pre_case = function(c)
		c.lua([[
			local dir = vim.fn.tempname()
			vim.fn.mkdir(dir, 'p')
			vim.env.XDG_CONFIG_HOME = dir
			for _, name in ipairs({ 'HOST', 'PORT', 'SERVER', 'DATABASE', 'TOKEN' }) do
				vim.env['SPACETIMEDB_' .. name] = nil
			end

			require('spacetime').setup({ identity = 'c200aaaa' })

			B = require('spacetime.ui.buffer')
			S = require('spacetime.ui.sidebar')
			STATE = require('spacetime.state')
			KEY = require('spacetime.commands').DATABASES_KEY

			NOTIFIED = {}
			vim.notify = function(msg) NOTIFIED[#NOTIFIED + 1] = msg end

			-- The buffer of the first window a teardown could have left standing.
			-- Floats are skipped: they are never what Neovim keeps, and a case that
			-- opens one would otherwise be asserting about the float.
			function surviving_buffer()
				for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
					if not B.is_floating(winid) then
						return vim.api.nvim_win_get_buf(winid)
					end
				end
			end

			REQUESTS, KILLED, STREAMED = {}, 0, {}
			package.loaded['spacetime.lib.http'] = {
				request = function(opts, on_done)
					REQUESTS[#REQUESTS + 1] = opts.url
					local response = RESPONDER(opts.url)
					if response then
						on_done(nil, { status = response.status, headers = {}, body = response.body })
					end
					return { kill = function() KILLED = KILLED + 1 end }
				end,
				-- `client:logs` is the one thing the sidebar reaches that streams —
				-- `gl` and `gL` — and it streams whether or not it is following. One
				-- `Info` line, delivered in the |fast-event| context the real transport
				-- uses, so the stub touches nothing but plain tables from inside it.
				stream = function(opts, on_line, on_done)
					STREAMED[#STREAMED + 1] = opts.url
					on_line('{"level":"Info","ts":"1754728000000000","message":"hello"}')
					on_done(nil, { status = 200, headers = {}, body = '' })
					return { kill = function() KILLED = KILLED + 1 end }
				end,
			}
		]])
		c.lua(DEFAULT_RESPONDER)
	end,
})

---The buffer names of every window in the child's current tabpage, sorted.
---@return string[]
local function window_buffers()
	local names = child.lua_get([[
		vim.tbl_map(function(winid)
			return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(winid))
		end, vim.api.nvim_tabpage_list_wins(0))
	]])
	table.sort(names)
	return names
end

---@param name string A `spacetime://…` buffer name.
---@return string[]
local function buffer_lines(name)
	return child.lua_get([[vim.api.nvim_buf_get_lines(B.find(...), 0, -1, false)]], { name })
end

---@return string[]
local function sidebar_lines()
	return buffer_lines("spacetime://sidebar")
end

---Which line the sidebar's cursor is on, 1-based.
---@return integer
local function sidebar_cursor()
	return child.lua_get([[vim.api.nvim_win_get_cursor(B.window_showing(B.find('spacetime://sidebar')))[1] ]])
end

---Make a fresh repository, containing `contents` as `spacetime.json` when given,
---and make it the child's working directory. The `.git` marker is what stops the
---VCS-root walk, so a case with no project file gets a *deliberate* absence
---rather than whatever happens to sit above the checkout.
---@param contents? string
local function in_project(contents)
	child.lua(
		[[
			local contents = ...
			local root = vim.fn.tempname()
			vim.fn.mkdir(root .. '/.git', 'p')
			if contents then
				vim.fn.writefile({ contents }, root .. '/spacetime.json')
			end
			vim.fn.chdir(root)
		]],
		{ contents }
	)
end

---How many schema requests the stub has been asked for.
---@return integer
local function schema_requests()
	return child.lua_get([[
		#vim.tbl_filter(function(url) return url:find('/schema?', 1, true) ~= nil end, REQUESTS)
	]])
end

--------------------------------------------------------------------------------
-- The layout
--------------------------------------------------------------------------------

T[":Spacetime opens both windows"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])

	expect.equality(window_buffers(), { "spacetime://content", "spacetime://sidebar" })
	-- Focus is on the sidebar, which is where the keymaps live.
	expect.equality(child.lua_get([[vim.api.nvim_buf_get_name(0)]]), "spacetime://sidebar")
end

T[":Spacetime twice does not stack windows"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])
	child.lua([[ vim.cmd('Spacetime') ]])

	expect.equality(child.lua_get([[#vim.api.nvim_tabpage_list_wins(0)]]), 2)
	expect.equality(window_buffers(), { "spacetime://content", "spacetime://sidebar" })
	-- The second open served the list from the cache: three requests, not six.
	expect.equality(child.lua_get([[#REQUESTS]]), 3)
end

T["the content window shows a placeholder until something is selected"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])
	expect.equality(buffer_lines("spacetime://content"), child.lua_get([[S.PLACEHOLDER]]))
end

T["<Tab> crosses the layout and comes back"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])
	expect.equality(child.lua_get([[vim.api.nvim_buf_get_name(0)]]), "spacetime://sidebar")

	child.type_keys("<Tab>")
	expect.equality(child.lua_get([[vim.api.nvim_buf_get_name(0)]]), "spacetime://content")

	child.type_keys("<Tab>")
	expect.equality(child.lua_get([[vim.api.nvim_buf_get_name(0)]]), "spacetime://sidebar")
end

T["q closes the layout and cancels what is in flight"] = function()
	-- A responder that never answers, so there is something to cancel.
	child.lua([[ RESPONDER = function() return nil end ]])
	child.lua([[ vim.cmd('Spacetime') ]])
	expect.equality(child.lua_get([[vim.tbl_count(STATE.data.inflight)]]), 1)

	child.type_keys("q")

	expect.equality(child.lua_get([[vim.tbl_count(STATE.data.inflight)]]), 0)
	expect.equality(child.lua_get([[S.is_open()]]), false)
	for _, name in ipairs(window_buffers()) do
		expect.no_equality(name:find("spacetime://", 1, true), 1)
	end
	-- And the child is still alive, one window showing what it displaced.
	expect.equality(child.lua_get([[#vim.api.nvim_tabpage_list_wins(0)]]), 1)
end

-- The bug in issue #43: a float is in `nvim_tabpage_list_wins` but can never be
-- the window Neovim keeps, so a teardown that counted it saw "two windows left"
-- and closed the last real one — `E444: Cannot close last window`, raised out of
-- the `q` mapping. One `vim.notify` popup from any notification plugin is enough
-- to reproduce it, which is why the report says "regardless of" how the layout
-- was opened.
T["q closes the layout with a float on screen"] = function()
	child.lua([[ vim.cmd('edit ' .. vim.fn.tempname()) ]])
	child.lua([[ ORIGINAL = vim.api.nvim_get_current_buf() ]])
	child.lua([[ vim.cmd('Spacetime') ]])
	child.lua([[
    FLOAT = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = 'editor', row = 1, col = 1, width = 10, height = 3,
    })
  ]])

	expect.equality(child.lua_get([[(pcall(S.close))]]), true)

	expect.equality(child.lua_get([[S.is_open()]]), false)
	-- One real window, showing the file the layout displaced. The float is
	-- somebody else's and is left alone.
	expect.equality(child.lua_get([[B.normal_windows()]]), 1)
	expect.equality(child.lua_get([[vim.api.nvim_win_is_valid(FLOAT)]]), true)
	expect.equality(child.lua_get([[surviving_buffer() == ORIGINAL]]), true)
end

T["q closes both windows when the tabpage has others"] = function()
	child.lua([[ vim.cmd('split') ]])
	child.lua([[ vim.cmd('Spacetime') ]])
	expect.equality(child.lua_get([[#vim.api.nvim_tabpage_list_wins(0)]]), 3)

	-- Pressed in the content window: `q` means the same thing from either half.
	child.lua([[ vim.api.nvim_set_current_win(B.window_showing(B.find('spacetime://content'))) ]])
	child.type_keys("q")

	expect.equality(child.lua_get([[S.is_open()]]), false)
	expect.equality(child.lua_get([[#vim.api.nvim_tabpage_list_wins(0)]]), 1)
	for _, name in ipairs(window_buffers()) do
		expect.no_equality(name:find("spacetime://", 1, true), 1)
	end
end

-- `:only` in the sidebar leaves the layout as one window, and that window cannot
-- be closed either. It gets a buffer — and its own chrome — back instead.
T["q hands the sidebar back when it is the last window standing"] = function()
	child.lua([[ vim.cmd('edit ' .. vim.fn.tempname()) ]])
	child.lua([[ ORIGINAL = vim.api.nvim_get_current_buf() ]])
	child.lua([[ vim.cmd('Spacetime') ]])
	child.lua([[ vim.cmd('only') ]])
	expect.equality(window_buffers(), { "spacetime://sidebar" })

	child.type_keys("q")

	expect.equality(child.lua_get([[S.is_open()]]), false)
	expect.equality(child.lua_get([[#vim.api.nvim_tabpage_list_wins(0)]]), 1)
	expect.equality(child.lua_get([[surviving_buffer() == ORIGINAL]]), true)
	expect.equality(child.lua_get([[vim.wo[0].winfixwidth]]), false)
end

-- A `:split` of the content window makes two windows showing the same buffer.
-- Teardown deals with both, or the user is left sitting in a scratch buffer.
T["q leaves no spacetime buffer on screen when the content window was split"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])
	child.lua([[
    local content = B.window_showing(B.find('spacetime://content'))
    vim.api.nvim_win_call(content, function() vim.cmd('split') end)
  ]])
	expect.equality(child.lua_get([[#vim.api.nvim_tabpage_list_wins(0)]]), 3)

	child.type_keys("q")

	expect.equality(child.lua_get([[S.is_open()]]), false)
	expect.equality(child.lua_get([[#vim.api.nvim_tabpage_list_wins(0)]]), 1)
	for _, name in ipairs(window_buffers()) do
		expect.no_equality(name:find("spacetime://", 1, true), 1)
	end
end

-- Nothing to displace and no alternate: the fallback is a real, listed buffer
-- the user can work in, not one of ours.
T["q falls back to a fresh listed buffer"] = function()
	child.lua([[ ORIGINAL = vim.api.nvim_get_current_buf() ]])
	child.lua([[ vim.cmd('Spacetime') ]])
	-- The displaced buffer is gone by the time `q` comes to put it back.
	child.lua([[ vim.api.nvim_buf_delete(ORIGINAL, { force = true }) ]])

	child.type_keys("q")

	expect.equality(child.lua_get([[#vim.api.nvim_tabpage_list_wins(0)]]), 1)
	expect.equality(child.lua_get([[B.is_ours(vim.api.nvim_get_current_buf())]]), false)
	expect.equality(child.lua_get([[vim.bo[0].buflisted]]), true)
	expect.equality(child.lua_get([[vim.bo[0].buftype]]), "")
end

T[":SpacetimeToggle closes an open layout and reopens a closed one"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])
	expect.equality(child.lua_get([[S.is_open()]]), true)

	child.lua([[ vim.cmd('SpacetimeToggle') ]])
	expect.equality(child.lua_get([[S.is_open()]]), false)

	child.lua([[ vim.cmd('SpacetimeToggle') ]])
	expect.equality(child.lua_get([[S.is_open()]]), true)
	expect.equality(window_buffers(), { "spacetime://content", "spacetime://sidebar" })
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

T["a stubbed database list renders into the sidebar"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])

	expect.equality(sidebar_lines(), { "▸ spacegym", "▸ spacetutorial" })
	-- One request for the list, one per database for its names.
	expect.equality(child.lua_get([[#REQUESTS]]), 3)
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

T["the rendered names are highlighted as extmarks in the plugin namespace"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])

	local marks = child.lua_get([[
		vim.api.nvim_buf_get_extmarks(B.find('spacetime://sidebar'), B.namespace(), 0, -1, { details = true })
	]])
	expect.equality(#marks, 2)
	-- The marker is a three-byte arrow plus a space, so the name starts at 4.
	expect.equality(marks[1][3], 4)
	expect.equality(marks[1][4].hl_group, "SpacetimeDatabase")
end

T["a table name's extmark starts past its icons, counted in bytes"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])
	child.type_keys("<CR>")
	expect.equality(sidebar_lines()[2], "    📋🔒 widget")

	local marks = child.lua_get([[
		vim.api.nvim_buf_get_extmarks(
			B.find('spacetime://sidebar'), B.namespace(), { 1, 0 }, { 1, -1 }, { details = true }
		)
	]])
	expect.equality(#marks, 1)
	-- Four spaces, a four-byte clipboard, a four-byte lock and a space: thirteen
	-- bytes, ten columns. A character count would put the highlight three bytes
	-- inside the second emoji.
	expect.equality(marks[1][3], 13)
	expect.equality(marks[1][4].end_col, 13 + #"widget")
	expect.equality(marks[1][4].hl_group, "SpacetimeTable")
end

T["icons = ascii and icons = none replace the emoji columns"] = function()
	child.lua([[ require('spacetime').setup({ identity = 'c200aaaa', icons = 'ascii' }) ]])
	child.lua([[ vim.cmd('Spacetime') ]])
	child.type_keys("<CR>")

	expect.equality(sidebar_lines(), { "▾ spacegym", "    t- widget", "▸ spacetutorial" })

	-- Read per render, so a later `setup()` takes effect on the next paint.
	child.lua([[ require('spacetime').setup({ identity = 'c200aaaa', icons = 'none' }) ]])
	child.lua([[ S.render() ]])
	expect.equality(sidebar_lines(), { "▾ spacegym", "    widget", "▸ spacetutorial" })

	-- An unknown mode is refused where the rest of the options are, at setup()
	-- time, rather than silently rendering something else.
	child.lua([[ expect.error(function() require('spacetime').setup({ icons = 'runes' }) end) ]])
end

T["<CR> expands and collapses the database under the cursor"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])

	child.type_keys("<CR>")
	expect.equality(sidebar_lines(), { "▾ spacegym", "    📋🔒 widget", "▸ spacetutorial" })

	child.type_keys("<CR>")
	expect.equality(sidebar_lines(), { "▸ spacegym", "▸ spacetutorial" })

	-- `o` is the same action.
	child.type_keys("o")
	expect.equality(sidebar_lines(), { "▾ spacegym", "    📋🔒 widget", "▸ spacetutorial" })

	-- One request for the list, one per database for its names, one schema.
	expect.equality(child.lua_get([[#REQUESTS]]), 4)
end

T["a project config naming a database expands straight to it"] = function()
	in_project('{"database": "spacetutorial"}')

	child.lua([[ vim.cmd('Spacetime') ]])

	-- Expanded *and* filled in: landing on the database means seeing its tables.
	expect.equality(sidebar_lines(), { "▸ spacegym", "▾ spacetutorial", "    📋🔒 widget" })
	expect.equality(schema_requests(), 1)
	-- And the cursor is *on* it, rather than on the alphabetically first database.
	expect.equality(sidebar_cursor(), 2)
end

T["a project config naming a database by identity lands on it too"] = function()
	-- `bb22` is the stub's identity for `spacetutorial`: the same rule that picks
	-- the node to expand picks the line to sit on.
	in_project('{"database": "bb22"}')

	child.lua([[ vim.cmd('Spacetime') ]])

	expect.equality(sidebar_lines(), { "▸ spacegym", "▾ spacetutorial", "    📋🔒 widget" })
	expect.equality(sidebar_cursor(), 2)
end

T["with no project database the cursor stays at the top"] = function()
	in_project()

	child.lua([[ vim.cmd('Spacetime') ]])

	expect.equality(sidebar_lines(), { "▸ spacegym", "▸ spacetutorial" })
	expect.equality(sidebar_cursor(), 1)
end

-- The focus is one-shot. Every later paint restores the row the cursor was on, so
-- moving off the project database has to stick — otherwise `r`, a schema landing
-- or a second `:Spacetime` would fight the user for the cursor.
T["the project focus happens once, and never takes the cursor back"] = function()
	in_project('{"database": "spacetutorial"}')
	child.lua([[ vim.cmd('Spacetime') ]])
	expect.equality(sidebar_cursor(), 2)

	child.type_keys("gg")
	child.type_keys("r")
	expect.equality(sidebar_lines(), { "▸ spacegym", "▾ spacetutorial", "    📋🔒 widget" })
	expect.equality(sidebar_cursor(), 1)

	child.lua([[ vim.cmd('Spacetime') ]])
	expect.equality(sidebar_cursor(), 1)
end

--------------------------------------------------------------------------------
-- Schemas
--------------------------------------------------------------------------------

-- The live v10 fixture, as `<CR>` renders it: user tables first, then views,
-- each group in `lib/schema.lua`'s canonical order but *labelled* with the
-- source spelling the developer wrote. The module owns no `st_*` table, so the
-- system group is empty here — the case below builds one to prove where it goes.
local FIXTURE_LINES = {
	"▾ spacegym",
	"    📋🔒 booking",
	"    📋🔒 classInstance",
	"    📋🔒 classTemplate",
	"    📋🔒 identity",
	"    📋🔒 ledgerBalance",
	"    📋🔒 ledgerEntry",
	"    📋🔒 ledgerTransaction",
	"    📋🔒 materializeTick",
	"    📋🔒 passPack",
	"    📋🔒 redemptionTick",
	"    📋🔒 security",
	"    📋🔒 user",
	"    👓🌎 adminTemplatesView",
	"    👓🌎 meView",
	"    👓🌎 myBookingsView",
	"    👓🌎 publicClassesView",
	"▸ spacetutorial",
}

---Serve `body` for every schema request, whatever version it asks for.
---@param body string
local function serve_schema(body)
	child.lua(
		[[
			local body = ...
			SCHEMA_RESPONDER(function() return { status = 200, body = body } end)
		]],
		{ body }
	)
end

T["expanding a database fetches its schema and renders it grouped"] = function()
	serve_schema(read("schema_v10.json"))
	child.lua([[ vim.cmd('Spacetime') ]])

	child.type_keys("<CR>")

	expect.equality(sidebar_lines(), FIXTURE_LINES)
	expect.equality(schema_requests(), 1)
	-- v10 is asked for first and answered, so nothing falls back.
	expect.equality(child.lua_get([[REQUESTS[#REQUESTS] ]]):find("version=10", 1, true) ~= nil, true)
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

T["expanding the same database twice issues one request"] = function()
	serve_schema(read("schema_v10.json"))
	child.lua([[ vim.cmd('Spacetime') ]])

	child.type_keys("<CR>")
	child.type_keys("<CR>")
	child.type_keys("<CR>")

	-- Collapse and expand as often as you like: the second render comes out of
	-- the session cache, and the cache is keyed by database name.
	expect.equality(sidebar_lines(), FIXTURE_LINES)
	expect.equality(schema_requests(), 1)
	expect.equality(child.lua_get([[STATE.cache_get(STATE.key('schema', 'spacegym')).version]]), 10)
end

T["r drops the cached schema and fetches it again"] = function()
	serve_schema(read("schema_v10.json"))
	child.lua([[ vim.cmd('Spacetime') ]])
	child.type_keys("<CR>")
	expect.equality(schema_requests(), 1)

	child.type_keys("r")

	-- Still expanded, still rendered — and asked for again, because `r` is the
	-- only expiry the cache has.
	expect.equality(sidebar_lines(), FIXTURE_LINES)
	expect.equality(schema_requests(), 2)
end

T["an unanswered schema request renders the node as loading"] = function()
	child.lua([[ SCHEMA_RESPONDER(function() return nil end) ]])
	child.lua([[ vim.cmd('Spacetime') ]])

	child.type_keys("<CR>")

	expect.equality(sidebar_lines(), { "▾ spacegym", "    loading…", "▸ spacetutorial" })
	expect.equality(child.lua_get([[vim.tbl_count(STATE.data.inflight)]]), 1)
end

T["collapsing cancels a schema fetch in flight"] = function()
	child.lua([[ SCHEMA_RESPONDER(function() return nil end) ]])
	child.lua([[ vim.cmd('Spacetime') ]])

	child.type_keys("<CR>")
	expect.equality(child.lua_get([[KILLED]]), 0)

	child.type_keys("<CR>")

	expect.equality(sidebar_lines(), { "▸ spacegym", "▸ spacetutorial" })
	expect.equality(child.lua_get([[vim.tbl_count(STATE.data.inflight)]]), 0)
	expect.equality(child.lua_get([[KILLED]]), 1)
end

T["a schema that lost its sequence token does not repaint the sidebar"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])

	-- Hold the schema response, so it can be fired after the token is burnt.
	child.lua([[
		PENDING = {}
		package.loaded['spacetime.lib.http'].request = function(opts, on_done)
			REQUESTS[#REQUESTS + 1] = opts.url
			PENDING[#PENDING + 1] = on_done
			return { kill = function() KILLED = KILLED + 1 end }
		end
	]])

	child.type_keys("<CR>")
	child.lua([[ STATE.cancel(STATE.key('schema', 'spacegym')) ]])
	child.lua([[ PENDING[1](nil, { status = 200, headers = {}, body = ... }) ]], { read("schema_v10.json") })

	-- Still the loading line the fetch started with, and nothing cached: the
	-- stale schema was dropped, and nothing raised on the way.
	expect.equality(sidebar_lines(), { "▾ spacegym", "    loading…", "▸ spacetutorial" })
	expect.equality(child.lua_get([[STATE.cache_get(STATE.key('schema', 'spacegym')) == nil]]), true)
end

T["a v10 rejection falls back to v9"] = function()
	child.lua(
		[[
			local body = ...
			SCHEMA_RESPONDER(function(url)
				if url:find('version=10', 1, true) then
					return { status = 400, body = 'unsupported schema version' }
				end
				return { status = 200, body = body }
			end)
		]],
		{ read("schema_v9.json") }
	)
	child.lua([[ vim.cmd('Spacetime') ]])

	child.type_keys("<CR>")

	-- Same module, the other wire shape: v9 has no source names, so the labels
	-- are the canonical ones.
	local lines = sidebar_lines()
	expect.equality({ lines[1], lines[2], lines[14], lines[18] }, {
		"▾ spacegym",
		"    📋🔒 booking",
		"    👓🌎 admin_templates_view",
		"▸ spacetutorial",
	})
	expect.equality(schema_requests(), 2)
end

T["system tables are grouped below the tables and the views"] = function()
	serve_schema(table.concat({
		'{"typespace":{"types":[]},"tables":[',
		'{"name":"st_table"},{"name":"widget"}',
		'],"misc_exports":[{"View":{"name":"widgets_view"}}]}',
	}))
	child.lua([[ vim.cmd('Spacetime') ]])

	child.type_keys("<CR>")

	expect.equality(sidebar_lines(), {
		"▾ spacegym",
		"    📋🔒 widget",
		"    👓🔒 widgets_view",
		"    🔧🔒 st_table",
		"▸ spacetutorial",
	})
end

--------------------------------------------------------------------------------
-- Paused databases
--------------------------------------------------------------------------------

-- A paused database answers 503 on *every* endpoint, so the one thing that must
-- never happen is a retry loop. `lib/schema.should_fallback` is 4xx-only, so the
-- client does not retry the version negotiation, and the sidebar remembers the
-- pause so a second expand does not ask again either.
T["a paused database renders ⏸ and is asked exactly once"] = function()
	child.lua([[
		SCHEMA_RESPONDER(function() return { status = 503, body = 'database is paused' } end)
	]])
	child.lua([[ vim.cmd('Spacetime') ]])

	child.type_keys("<CR>")

	expect.equality(sidebar_lines(), { "▾ spacegym ⏸", "▸ spacetutorial" })
	expect.equality(schema_requests(), 1)

	-- Collapsing and expanding again asks nothing: the pause is already known,
	-- and hammering a sick server is exactly what this is here to prevent.
	child.type_keys("<CR>")
	child.type_keys("<CR>")
	expect.equality(schema_requests(), 1)
	expect.equality(sidebar_lines(), { "▾ spacegym ⏸", "▸ spacetutorial" })

	-- No stack trace, no notification: the marker is the whole of the report.
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

T["r asks a paused database again, in case it has woken up"] = function()
	child.lua([[
		SCHEMA_RESPONDER(function() return { status = 503, body = 'database is paused' } end)
	]])
	child.lua([[ vim.cmd('Spacetime') ]])
	child.type_keys("<CR>")
	expect.equality(schema_requests(), 1)

	-- The server wakes up: back to the default responder, which answers.
	child.lua(DEFAULT_RESPONDER)
	child.type_keys("r")

	expect.equality(sidebar_lines(), { "▾ spacegym", "    📋🔒 widget", "▸ spacetutorial" })
	expect.equality(schema_requests(), 2)
end

T["a failed schema renders as buffer text under its database"] = function()
	child.lua([[
		SCHEMA_RESPONDER(function() return { status = 500, body = 'schema exploded' } end)
	]])
	child.lua([[ vim.cmd('Spacetime') ]])

	child.type_keys("<CR>")

	expect.equality(sidebar_lines(), {
		"▾ spacegym",
		"    error: HTTP 500: schema exploded",
		"▸ spacetutorial",
	})
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

--------------------------------------------------------------------------------
-- Errors
--------------------------------------------------------------------------------

T["a failed list renders as buffer text, not as a stack trace"] = function()
	child.lua([[
		RESPONDER = function() return { status = 500, body = 'kaboom' } end
	]])

	child.lua([[ expect.no_error(function() vim.cmd('Spacetime') end) ]])

	local lines = sidebar_lines()
	expect.equality(#lines, 1)
	expect.equality(lines[1], "error: HTTP 500: kaboom")
	-- No notification, no `E`-code, no traceback: the message is the whole of it.
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
	expect.equality(lines[1]:find("stack traceback"), nil)
end

T["a config that will not resolve renders its reason in the sidebar"] = function()
	child.lua([[ require('spacetime').setup({ identity = 'c200aaaa', server = 'nowhere' }) ]])

	child.lua([[ expect.no_error(function() vim.cmd('Spacetime') end) ]])

	local lines = sidebar_lines()
	expect.equality(#lines, 1)
	expect.equality(lines[1]:find('error: server "nowhere" not found', 1, true), 1)
	-- Nothing was put on the wire for a connection that does not exist.
	expect.equality(child.lua_get([[#REQUESTS]]), 0)
end

-- `list_databases` is the one client method that can call back with an error
-- *and* a list. Both halves have to survive.
T["a partial failure renders the databases it has and the error it hit"] = function()
	child.lua([[
		RESPONDER = function(url)
			if url:find('/v1/identity/', 1, true) then
				return { status = 200, body = '{"identities":["aa11","bb22"]}' }
			end
			if url:match('/v1/database/(.-)/names') == 'aa11' then
				return { status = 200, body = '{"names":["spacegym"]}' }
			end
			return { status = 500, body = 'names exploded' }
		end
	]])

	child.lua([[ vim.cmd('Spacetime') ]])

	-- The failed entry falls back to its identity for a name, sorts before
	-- `spacegym`, and is expanded so its error is on screen rather than hidden.
	expect.equality(sidebar_lines(), {
		"▾ bb22",
		"    error: HTTP 500: names exploded",
		"▸ spacegym",
	})
end

--------------------------------------------------------------------------------
-- Keymaps
--------------------------------------------------------------------------------

T["every documented key is mapped, buffer-locally, in the sidebar"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])

	-- A mapping's `callback` is a Lua function and cannot cross the RPC boundary,
	-- so the interesting fields are picked out inside the child.
	local described = [[
		(function(lhs)
			local map = vim.fn.maparg(lhs, 'n', false, true)
			return { buffer = map.buffer, callback = type(map.callback) }
		end)(...)
	]]

	for _, lhs in ipairs({ "<CR>", "o", "s", "R", "gl", "gL", "r", "q", "y", "gi", "?" }) do
		local map = child.lua_get(described, { lhs })
		expect.equality({ lhs, map.buffer, map.callback }, { lhs, 1, "function" })
	end

	-- And they really are buffer-local: the sidebar's own keys are not in the
	-- content buffer.
	child.lua([[ vim.api.nvim_set_current_win(vim.fn.win_findbuf(B.find('spacetime://content'))[1]) ]])
	for _, lhs in ipairs({ "r", "gi", "?" }) do
		-- No mapping at all: no `buffer` field, and nothing to call.
		expect.equality(child.lua_get(described, { lhs }), { callback = "nil" })
	end

	-- `q` is the exception, and deliberately so: the sidebar and the content
	-- window are one thing, so `q` closes the layout from either side.
	local close = child.lua_get(described, { "q" })
	expect.equality({ close.buffer, close.callback }, { 1, "function" })
end

T["y yanks the node's name and gi yanks its identity"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])

	child.type_keys("y")
	expect.equality(child.lua_get([[vim.fn.getreg('"')]]), "spacegym")

	child.type_keys("gi")
	expect.equality(child.lua_get([[vim.fn.getreg('"')]]), "aa11")

	-- A named register still works, so `"+y` reaches the system clipboard.
	child.type_keys("j", '"ay')
	expect.equality(child.lua_get([[vim.fn.getreg('a')]]), "spacetutorial")
end

T["r drops the cache and fetches again"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])
	expect.equality(sidebar_lines(), { "▸ spacegym", "▸ spacetutorial" })

	child.lua([[
		RESPONDER = function(url)
			if url:find('/v1/identity/', 1, true) then
				return { status = 200, body = '{"identities":["cc33"]}' }
			end
			return { status = 200, body = '{"names":["renamed"]}' }
		end
	]])
	child.type_keys("r")

	expect.equality(sidebar_lines(), { "▸ renamed" })
	expect.equality(child.lua_get([[#REQUESTS]]), 5)
	expect.equality(child.lua_get([[STATE.cache_get(KEY)[1].name]]), "renamed")
end

-- The refetch replaces the tree from the top — the list goes back to a single
-- `loading…` line before the new one lands — so the row the cursor was on is
-- gone by the time there is anything to sit on. These four cases pin the whole
-- of what `r` puts it back to.
T["r comes back to the table it was pressed on"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])
	child.type_keys("j", "<CR>")
	expect.equality(sidebar_lines(), { "▸ spacegym", "▾ spacetutorial", "    📋🔒 widget" })

	child.type_keys("j")
	expect.equality(sidebar_cursor(), 3)

	child.type_keys("r")
	expect.equality(sidebar_lines(), { "▸ spacegym", "▾ spacetutorial", "    📋🔒 widget" })
	expect.equality(sidebar_cursor(), 3)
end

-- Not the row: the replacement schema has a table in the same position, so a
-- cursor that merely stayed on line 3 would land on `gadget` and look right.
T["r comes back to the database when the table has gone"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])
	child.type_keys("j", "<CR>", "j")
	expect.equality(sidebar_cursor(), 3)

	child.lua([[
		SCHEMA_RESPONDER(function()
			return { status = 200, body = '{"typespace":{"types":[]},"tables":[{"name":"gadget"}]}' }
		end)
	]])
	child.type_keys("r")

	expect.equality(sidebar_lines(), { "▸ spacegym", "▾ spacetutorial", "    📋🔒 gadget" })
	expect.equality(sidebar_cursor(), 2)
end

T["r leaves the cursor at the top when the database has gone"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])
	child.type_keys("j", "<CR>", "j")
	expect.equality(sidebar_cursor(), 3)

	-- The identity now owns `spacegym` alone, so the node the cursor was on has
	-- no database left to fall back to.
	child.lua([[
		local base = RESPONDER
		RESPONDER = function(url)
			if url:find('/v1/identity/', 1, true) then
				return { status = 200, body = '{"identities":["aa11"]}' }
			end
			return base(url)
		end
	]])
	child.type_keys("r")

	expect.equality(sidebar_lines(), { "▸ spacegym" })
	expect.equality(sidebar_cursor(), 1)
end

-- The restoration is held across the renders a refetch takes, so it has to let
-- go the moment the user does something with the cursor themselves.
T["a selection during a refresh keeps the cursor the user moved"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])
	child.type_keys("j", "<CR>", "j")
	expect.equality(sidebar_cursor(), 3)

	-- The schema never answers, so the target is still pending: `spacetutorial`
	-- is left reading `loading…` and the cursor is on its database line.
	child.lua([[ SCHEMA_RESPONDER(function() return nil end) ]])
	child.type_keys("r")
	expect.equality(sidebar_lines(), { "▸ spacegym", "▾ spacetutorial", "    loading…" })
	expect.equality(sidebar_cursor(), 2)

	-- Expanding `spacegym` retires the target: the repaint that grows the tree
	-- leaves the cursor on what was just opened rather than hauling it back down
	-- to the `spacetutorial` line the pending target names.
	child.lua([[ SCHEMA_RESPONDER(function() return { status = 200, body = MINI_SCHEMA } end) ]])
	child.type_keys("gg", "<CR>")

	expect.equality(sidebar_lines(), { "▾ spacegym", "    📋🔒 widget", "▾ spacetutorial", "    loading…" })
	expect.equality(sidebar_cursor(), 1)
end

T["? prints the key map"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])
	child.type_keys("?")

	local messages = child.cmd_capture("messages")
	expect.equality(messages:find("spacetime.nvim sidebar", 1, true) ~= nil, true)
	expect.equality(messages:find("yank the database identity", 1, true) ~= nil, true)
	-- The keys that reach the other views are listed too: `?` is the only place
	-- they are discoverable, and it is built from the mapping table itself.
	expect.equality(messages:find("show the schema of the table under the cursor", 1, true) ~= nil, true)
	expect.equality(messages:find("show the reducers of the database the cursor is in", 1, true) ~= nil, true)
	expect.equality(messages:find("show the logs of the database the cursor is in", 1, true) ~= nil, true)
	expect.equality(messages:find("follow those logs live", 1, true) ~= nil, true)
end

--------------------------------------------------------------------------------
-- Navigating to the other views
--------------------------------------------------------------------------------

-- `s`, `gl` and `gL` are the keystroke forms of `:SpacetimeSchema` and
-- `:SpacetimeLogs[!]`, answered by the node under the cursor. Two tables, so
-- "the schema of *that* table" is an assertion rather than a coincidence.
local TWO_TABLES = '{"typespace":{"types":[]},"tables":[{"name":"widget"},{"name":"gadget"}]}'

---@return string[]
local function content_lines()
	return buffer_lines("spacetime://content")
end

---The URL of the one and only log request, or `nil`.
---@return string|nil
local function streamed()
	return child.lua_get([[STREAMED[1] ]])
end

T["s shows the schema of the table under the cursor"] = function()
	serve_schema(TWO_TABLES)
	child.lua([[ vim.cmd('Spacetime') ]])
	child.type_keys("<CR>")
	expect.equality(
		sidebar_lines(),
		{ "▾ spacegym", "    📋🔒 gadget", "    📋🔒 widget", "▸ spacetutorial" }
	)

	-- Line three is `widget`, and it is `widget` the content window must describe.
	child.type_keys("jj", "s")

	local lines = content_lines()
	expect.equality(lines[1], "widget")
	expect.equality(vim.tbl_contains(lines, "Columns"), true)
	-- The schema is the one the expansion cached, so pressing `s` costs nothing.
	expect.equality(schema_requests(), 1)
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
	-- And the cursor has not left the sidebar.
	expect.equality(child.lua_get([[vim.api.nvim_buf_get_name(0)]]), "spacetime://sidebar")
end

T["s on a database node says so and does nothing"] = function()
	serve_schema(TWO_TABLES)
	child.lua([[ vim.cmd('Spacetime') ]])

	child.lua([[ expect.no_error(function() vim.cmd('normal s') end) ]])

	expect.equality(content_lines(), child.lua_get([[S.PLACEHOLDER]]))
	expect.equality(child.lua_get([[NOTIFIED]]), { "[spacetime] there is no table to describe here" })
end

T["gl shows the logs of the database the cursor is inside"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])
	-- From a *table* node: the logs are the database's, whichever of its tables
	-- the cursor happens to be on.
	child.type_keys("<CR>", "j", "gl")

	expect.equality(streamed():find("/v1/database/spacegym/logs", 1, true) ~= nil, true)
	expect.equality(streamed():find("follow=false", 1, true) ~= nil, true)

	local lines = content_lines()
	expect.equality(lines[1]:find("spacegym · 1 line", 1, true), 1)
	expect.equality(lines[2]:find("hello", 1, true) ~= nil, true)
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

T["gL follows them instead"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])

	child.type_keys("gL")

	expect.equality(streamed():find("follow=true", 1, true) ~= nil, true)
	-- The stub's stream ends as soon as it has spoken, so the badge reports a
	-- follow that has stopped rather than one still running.
	expect.equality(content_lines()[1]:find("· stopped", 1, true) ~= nil, true)
end

T["gl on a line that belongs to no database says so and does nothing"] = function()
	child.lua([[ RESPONDER = function() return { status = 500, body = 'kaboom' } end ]])
	child.lua([[ vim.cmd('Spacetime') ]])
	expect.equality(sidebar_lines(), { "error: HTTP 500: kaboom" })

	child.lua([[ expect.no_error(function() vim.cmd('normal gl') end) ]])
	child.lua([[ expect.no_error(function() vim.cmd('normal gL') end) ]])

	expect.equality(child.lua_get([[#STREAMED]]), 0)
	expect.equality(content_lines(), child.lua_get([[S.PLACEHOLDER]]))
	expect.equality(child.lua_get([[NOTIFIED]]), {
		"[spacetime] there is no database to show logs for here",
		"[spacetime] there is no database to show logs for here",
	})
end

--------------------------------------------------------------------------------
-- Cancellation
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Switching server
--------------------------------------------------------------------------------

---Give the child a `cli.toml` with one selectable nickname, in the temporary
---`XDG_CONFIG_HOME` the hooks already point it at. The `[==[` is load-bearing:
---the TOML contains `]]`, which would close a plain long bracket early.
local function serve_cli_toml()
	child.lua([==[
		local dir = vim.env.XDG_CONFIG_HOME
		vim.fn.mkdir(dir .. '/spacetime', 'p')
		vim.fn.writefile({
			'[[server_configs]]',
			'nickname = "testnet"',
			'host = "testnet.example.com"',
			'protocol = "https"',
		}, dir .. '/spacetime/cli.toml')
	]==])
end

T[":SpacetimeConnect refetches an open layout against the new server"] = function()
	serve_cli_toml()
	child.lua([[ vim.cmd('Spacetime') ]])
	-- Everything so far went to the default, which is not where we are going.
	expect.equality(child.lua_get([[REQUESTS[1] ]]):find("testnet", 1, true), nil)

	child.lua([[ REQUESTS = {} ]])
	child.lua([[ vim.cmd('SpacetimeConnect testnet') ]])

	-- The list is asked for again, and asked of the server just selected.
	expect.equality(#child.lua_get([[REQUESTS]]) > 0, true)
	expect.equality(child.lua_get([[REQUESTS[1] ]]):find("https://testnet.example.com:443", 1, true), 1)
	expect.equality(sidebar_lines(), { "▸ spacegym", "▸ spacetutorial" })
end

T["switching server puts the content window back to the placeholder"] = function()
	serve_cli_toml()
	serve_schema(TWO_TABLES)
	child.lua([[ vim.cmd('Spacetime') ]])
	-- Something of the old server's on screen: a table's schema.
	child.type_keys("<CR>", "jj", "s")
	expect.equality(content_lines()[1], "widget")

	child.lua([[ vim.cmd('SpacetimeConnect testnet') ]])

	-- Left alone it would sit there looking like the new server's answer.
	expect.equality(content_lines(), child.lua_get([[S.PLACEHOLDER]]))
end

T["a refused switch leaves the layout on the server it was on"] = function()
	serve_cli_toml()
	child.lua([[ vim.cmd('Spacetime') ]])
	local before = sidebar_lines()

	child.lua([[ REQUESTS = {} ]])
	child.lua([[ expect.no_error(function() vim.cmd('SpacetimeConnect nosuchserver') end) ]])

	-- Nothing refetched, nothing repainted, nothing dropped: a refusal is not a
	-- half-switch.
	expect.equality(child.lua_get([[REQUESTS]]), {})
	expect.equality(sidebar_lines(), before)
	expect.equality(child.lua_get([[#NOTIFIED]]), 1)
end

T["a second :Spacetime cancels the first fetch"] = function()
	child.lua([[ RESPONDER = function() return nil end ]])

	child.lua([[ vim.cmd('Spacetime') ]])
	local first = child.lua_get([[STATE.data.seq[KEY] ]])
	expect.equality(child.lua_get([[KILLED]]), 0)

	child.lua([[ vim.cmd('Spacetime') ]])

	-- The first fetch's handle was killed, and its sequence token burned, so a
	-- response that arrives late for it is dropped rather than painted.
	expect.equality(child.lua_get([[KILLED]]), 1)
	expect.no_equality(child.lua_get([[STATE.data.seq[KEY] ]]), first)
	expect.equality(child.lua_get([[vim.tbl_count(STATE.data.inflight)]]), 1)
end

T["a response that lost its sequence token does not repaint the sidebar"] = function()
	-- Hold the responder's callback, so it can be fired after the token is burnt.
	child.lua([[
		PENDING = {}
		RESPONDER = function() return nil end
		package.loaded['spacetime.lib.http'].request = function(opts, on_done)
			REQUESTS[#REQUESTS + 1] = opts.url
			PENDING[#PENDING + 1] = on_done
			return { kill = function() KILLED = KILLED + 1 end }
		end
	]])

	child.lua([[ vim.cmd('Spacetime') ]])
	child.lua([[ STATE.cancel(KEY) ]])

	child.lua([[
		PENDING[1](nil, {
			status = 200,
			headers = {},
			body = '{"identities":["aa11"]}',
		})
	]])

	-- Still the loading line the fetch started with: the stale response was
	-- dropped, and nothing raised on the way.
	expect.equality(sidebar_lines(), { "loading…" })
end

return T
