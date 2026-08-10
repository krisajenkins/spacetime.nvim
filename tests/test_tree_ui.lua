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

-- Two databases, each with one name. `identity_hex` strips a leading `0x`, so
-- these are plain hex-ish strings; the shape with `__identity__` is the one the
-- client documents as unverified-but-accepted.
local DEFAULT_RESPONDER = [[
	RESPONDER = function(url)
		if url:find('/v1/identity/', 1, true) then
			return { status = 200, body = '{"identities":[{"__identity__":"aa11"},{"__identity__":"bb22"}]}' }
		end
		local db = url:match('/v1/database/(.-)/names')
		if db == 'aa11' then return { status = 200, body = '{"names":["spacegym"]}' } end
		if db == 'bb22' then return { status = 200, body = '{"names":["spacetutorial"]}' } end
		return { status = 404, body = 'no such database' }
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

			REQUESTS, KILLED = {}, 0
			package.loaded['spacetime.lib.http'] = {
				request = function(opts, on_done)
					REQUESTS[#REQUESTS + 1] = opts.url
					local response = RESPONDER(opts.url)
					if response then
						on_done(nil, { status = response.status, headers = {}, body = response.body })
					end
					return { kill = function() KILLED = KILLED + 1 end }
				end,
				stream = function()
					error('the sidebar must not stream')
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

T["<CR> expands and collapses the database under the cursor"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])

	child.type_keys("<CR>")
	expect.equality(sidebar_lines(), { "▾ spacegym", "▸ spacetutorial" })

	child.type_keys("<CR>")
	expect.equality(sidebar_lines(), { "▸ spacegym", "▸ spacetutorial" })

	-- `o` is the same action, and expansion at this task fetches nothing: the
	-- schema request belongs to roadmap task 25.
	child.type_keys("o")
	expect.equality(sidebar_lines(), { "▾ spacegym", "▸ spacetutorial" })
	expect.equality(child.lua_get([[#REQUESTS]]), 3)
end

T["a project config naming a database expands straight to it"] = function()
	child.lua([[
		local root = vim.fn.tempname()
		vim.fn.mkdir(root .. '/.git', 'p')
		vim.fn.writefile({ '{"database": "spacetutorial"}' }, root .. '/spacetime.json')
		vim.fn.chdir(root)
	]])

	child.lua([[ vim.cmd('Spacetime') ]])

	expect.equality(sidebar_lines(), { "▸ spacegym", "▾ spacetutorial" })
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

	for _, lhs in ipairs({ "<CR>", "o", "r", "q", "y", "gi", "?" }) do
		local map = child.lua_get(described, { lhs })
		expect.equality({ lhs, map.buffer, map.callback }, { lhs, 1, "function" })
	end

	-- And they really are buffer-local: the content buffer has none of them.
	child.lua([[ vim.api.nvim_set_current_win(vim.fn.win_findbuf(B.find('spacetime://content'))[1]) ]])
	-- No mapping at all: no `buffer` field, and nothing to call.
	expect.equality(child.lua_get(described, { "q" }), { callback = "nil" })
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

T["? prints the key map"] = function()
	child.lua([[ vim.cmd('Spacetime') ]])
	child.type_keys("?")

	local messages = child.cmd_capture("messages")
	expect.equality(messages:find("spacetime.nvim sidebar", 1, true) ~= nil, true)
	expect.equality(messages:find("yank the database identity", 1, true) ~= nil, true)
end

--------------------------------------------------------------------------------
-- Cancellation
--------------------------------------------------------------------------------

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
