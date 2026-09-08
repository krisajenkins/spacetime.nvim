-- Tests for the functions view: `:SpacetimeFunctions [db]`, rendered into the
-- content window.
--
-- A child Neovim throughout — buffers, extmarks and keymaps are real editor
-- state — with the transport seam `spacetime.lib.http` stubbed and *nothing*
-- else (tests/CLAUDE.md). Neither `lib.client` nor `lib.schema` is mocked, so the
-- version negotiation and the v9 fallback are genuinely exercised against the two
-- committed captures of the same module.
--
-- That pairing is the point of the file. `schema_v10.json` and `schema_v9.json`
-- are the same live module in both wire shapes, so the same assertions can be run
-- twice: v10 carries `visibility` and v9 carries none, and the second run is what
-- proves an older server's reducers are not all labelled `Private`.
--
-- What the captures do *not* have is a procedure — nothing we have pointed at
-- uses one yet — so the procedure cases splice a `Procedures` section onto the
-- v10 text (`with_procedures` below) rather than editing the capture.
--
-- Issue #38 is why this view exists at all: a module's functions are the
-- *database's*, not any one table's, so listing them under a table's schema was a
-- category error. tests/test_schema_ui.lua asserts the other half — that they are
-- gone from there.
local child, new_set = require("tests.helpers.child")()
local expect = MiniTest.expect
local read = require("tests.helpers.fixtures").read

---A `Procedures` section in the v10 wire shape, taken from `RawProcedureDefV10`
---in the 2.8.0 checkout: one `return_type` where a reducer has the `ok`/`err`
---pair, and the same `FunctionVisibility` a reducer carries.
local PROCEDURES = table.concat({
	'{"Procedures":[',
	'{"source_name":"send_email",',
	'"params":{"elements":[{"name":{"some":"to"},"algebraic_type":{"String":[]}}]},',
	'"return_type":{"Bool":[]},"visibility":{"ClientCallable":[]}},',
	'{"source_name":"purge_cache","params":{"elements":[]},',
	'"return_type":{"Product":{"elements":[]}},"visibility":{"Private":[]}}',
	"]}",
})

---The v10 fixture with that section spliced in, as wire text.
---
---Spliced rather than re-encoded so that the rest of the capture reaches the
---parser byte-for-byte as the server sent it.
---@return string
local function with_procedures()
	local body = read("schema_v10.json"):gsub('"sections":%s*%[', '"sections": [' .. PROCEDURES .. ",", 1)
	return body
end

---One statement result with a single String column, for the rows view: the
---keymap case needs a grid on screen before the functions view takes it away.
local ONE_ROW =
	'[{"schema":{"elements":[{"name":{"some":"id"},"algebraic_type":{"String":[]}}]},"rows":[["x"]],"total_duration_micros":1}]'

local T = new_set({
	pre_case = function(c)
		c.lua(
			[[
				local dir = vim.fn.tempname()
				vim.fn.mkdir(dir, 'p')
				vim.env.XDG_CONFIG_HOME = dir
				for _, name in ipairs({ 'HOST', 'PORT', 'SERVER', 'DATABASE', 'TOKEN' }) do
					vim.env['SPACETIMEDB_' .. name] = nil
				end

				require('spacetime').setup({ identity = 'c200aaaa' })

				B = require('spacetime.ui.buffer')
				STATE = require('spacetime.state')

				NOTIFIED = {}
				vim.notify = function(msg) NOTIFIED[#NOTIFIED + 1] = msg end

				ROWS = ...
				SCHEMA = '{"typespace":{"types":[]},"tables":[{"name":"widget"}]}'
				-- Answers every `?version=` alike unless a case says otherwise.
				SCHEMA_REPLY = function() return { status = 200, body = SCHEMA } end
				REQUESTS = {}

				-- Two databases, one per identity: which of them a keystroke resolves to
				-- is the whole question `R` on a table answers.
				RESPONDER = function(url)
					if url:find('/v1/identity/', 1, true) then
						return { status = 200, body = '{"identities":["aa11","bb22"]}' }
					end
					local named = url:match('/v1/database/(.-)/names')
					if named == 'aa11' then
						return { status = 200, body = '{"names":["spacegym"]}' }
					end
					if named == 'bb22' then
						return { status = 200, body = '{"names":["spacetutorial"]}' }
					end
					if url:find('/schema?', 1, true) then return SCHEMA_REPLY(url) end
					if url:find('/sql', 1, true) then
						return { status = 200, body = ROWS }
					end
					return { status = 404, body = 'no such endpoint' }
				end

				package.loaded['spacetime.lib.http'] = {
					request = function(opts, on_done)
						REQUESTS[#REQUESTS + 1] = opts.url
						local response = RESPONDER(opts.url)
						if response then
							on_done(nil, { status = response.status, headers = {}, body = response.body })
						end
						return { kill = function() end }
					end,
					stream = function() error('the functions view must not stream') end,
				}
			]],
			{ ONE_ROW }
		)
	end,
})

---Serve `body` for every schema request, whatever version it asks for.
---@param body string
local function serve_schema(body)
	child.lua([[ SCHEMA = ... ]], { body })
end

---Serve `body` only to the v9 request, rejecting v10 as an older server does.
---@param body string
local function serve_v9(body)
	child.lua(
		[[
			SCHEMA = ...
			SCHEMA_REPLY = function(url)
				if url:find('version=10', 1, true) then
					return { status = 400, body = 'unsupported schema version' }
				end
				return { status = 200, body = SCHEMA }
			end
		]],
		{ body }
	)
end

---@return string[]
local function content_lines()
	return child.lua_get([[vim.api.nvim_buf_get_lines(B.find('spacetime://content'), 0, -1, false)]])
end

---@return string[]
local function sidebar_lines()
	return child.lua_get([[vim.api.nvim_buf_get_lines(B.find('spacetime://sidebar'), 0, -1, false)]])
end

---Every extmark in the content buffer as `{ line, col, hl_group }`.
---@return table[]
local function content_marks()
	return child.lua_get([[
		vim.tbl_map(function(mark)
			return { mark[2], mark[3], mark[4].hl_group }
		end, vim.api.nvim_buf_get_extmarks(B.find('spacetime://content'), B.namespace(), 0, -1, { details = true }))
	]])
end

---The rows of one section: everything below its heading, up to the blank line.
---@param heading string
---@return string[]
local function section_lines(heading)
	local out, inside = {}, false
	for _, line in ipairs(content_lines()) do
		if inside then
			if line == "" then
				break
			end
			out[#out + 1] = line
		elseif line == heading then
			inside = true
		end
	end
	return out
end

---The rows of the `Reducers` section.
---@return string[]
local function reducer_lines()
	return section_lines("Reducers")
end

---The rows of the `Procedures` section; empty when the view omitted it.
---@return string[]
local function procedure_lines()
	return section_lines("Procedures")
end

---The one line of `lines` containing `needle`, or `nil`.
---@param lines string[]
---@param needle string
---@return string|nil
local function line_with(lines, needle)
	for _, line in ipairs(lines) do
		if line:find(needle, 1, true) then
			return line
		end
	end
	return nil
end

---How many schema requests the stub has been asked for.
---@return integer
local function schema_requests()
	return child.lua_get([[
		#vim.tbl_filter(function(url) return url:find('/schema?', 1, true) ~= nil end, REQUESTS)
	]])
end

--------------------------------------------------------------------------------
-- The view
--------------------------------------------------------------------------------

T["the reducers of a named database render with signatures and visibility"] = function()
	serve_schema(read("schema_v10.json"))

	child.lua([[ vim.cmd('SpacetimeFunctions spacegym') ]])

	local lines = content_lines()
	-- The title is the database, because that is what a reducer belongs to.
	expect.equality(lines[1], "spacegym")
	expect.equality(lines[2], "19 reducers · schema v10")
	expect.equality(lines[4], "Reducers")

	local reducers = reducer_lines()
	expect.equality(#reducers, 19)

	-- The parameter list is typed through `lib/value.label`, and the return types
	-- are the `ok`/`err` pair only v10 carries.
	expect.equality(line_with(reducers, "book("), "  ClientCallable  book(instanceId: U64) -> ok {} | err String")

	-- The canonical spelling alone, where the module and SQL disagree about a name:
	-- a signature reads as a call, so the `name (canonical)` pair the schema view
	-- renders would sit exactly where the argument list belongs.
	expect.equality(line_with(reducers, "on_connect"):find("on_connect()", 1, true) ~= nil, true)
	expect.equality(line_with(reducers, "onConnect"), nil)

	-- The title is a header, and nothing here is an error.
	expect.equality(content_marks()[1][3], "SpacetimeHeader")
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)

	-- This module has no procedures, so that heading is absent altogether rather
	-- than standing there saying `(none)`.
	expect.equality(line_with(content_lines(), "Procedures"), nil)
end

--------------------------------------------------------------------------------
-- Procedures
--------------------------------------------------------------------------------

-- The point of the rename: a procedure is not a reducer. It is not automatically
-- transactional and it returns one value rather than an `ok`/`err` pair, so a
-- user has to be able to tell which of the two a name is before calling it. Two
-- headings, therefore, and not one merged list.
T["procedures render under a heading of their own"] = function()
	serve_schema(with_procedures())

	child.lua([[ vim.cmd('SpacetimeFunctions spacegym') ]])

	expect.equality(content_lines()[2], "19 reducers · 2 procedures · schema v10")

	-- The reducers are where they were, and the procedures are not among them.
	expect.equality(#reducer_lines(), 19)
	expect.equality(line_with(reducer_lines(), "send_email"), nil)

	local procedures = procedure_lines()
	expect.equality(#procedures, 2)
	-- One return type, where a reducer's signature ends in the `ok`/`err` pair.
	-- (That these names are already canonical is the point of asserting the name
	-- map in tests/test_schema.lua instead: it is not this view's job.)
	expect.equality(procedures[2], "  ClientCallable  send_email(to: String) -> Bool")
	-- Sorted by canonical, like every other list in the model.
	expect.equality(procedures[1]:find("purge_cache()", 1, true) ~= nil, true)

	-- The access column is one decision for the whole view, so both headings
	-- align their markers the same way.
	expect.equality(procedures[1]:match("^%s+(%a+)%s"), "Private")
end

T["a Private procedure is greyed out rather than hidden"] = function()
	serve_schema(with_procedures())

	child.lua([[ vim.cmd('SpacetimeFunctions spacegym') ]])

	local greyed = vim.tbl_filter(function(mark)
		return mark[3] == "SpacetimeNull"
	end, content_marks())
	-- Two marks each — the marker and the signature — for the module's five
	-- Private reducers and now one Private procedure as well.
	expect.equality(#greyed, 12)
end

-- A v9 server has no procedures to send, and the section it would head is not
-- rendered as empty: there is nothing there to report on.
T["a v9 schema shows reducers alone, with no procedures heading"] = function()
	serve_v9(read("schema_v9.json"))

	child.lua([[ vim.cmd('SpacetimeFunctions spacegym') ]])

	expect.equality(content_lines()[2], "19 reducers · schema v9")
	expect.equality(line_with(content_lines(), "Procedures"), nil)
end

T["the singular is used for one of each"] = function()
	serve_schema(([[{"sections":[{"Typespace":{"types":[]}},
		{"Reducers":[{"source_name":"tick","params":{"elements":[]},
			"visibility":{"ClientCallable":[]},
			"ok_return_type":{"Product":{"elements":[]}},"err_return_type":{"String":[]}}]},
		{"Procedures":[{"source_name":"ping","params":{"elements":[]},
			"return_type":{"Bool":[]},"visibility":{"ClientCallable":[]}}]}]}]]):gsub("%s+", ""))

	child.lua([[ vim.cmd('SpacetimeFunctions spacegym') ]])

	expect.equality(content_lines()[2], "1 reducer · 1 procedure · schema v10")
	expect.equality(reducer_lines(), { "  ClientCallable  tick() -> ok {} | err String" })
	expect.equality(procedure_lines(), { "  ClientCallable  ping() -> Bool" })
end

-- The `Private` treatment the schema view had, carried over intact: a reducer you
-- cannot call is still part of the module, and a future `:SpacetimeCall` needs to
-- be able to say so. Greyed, therefore, and not dropped.
T["a Private reducer is listed and greyed out rather than hidden"] = function()
	serve_schema(read("schema_v10.json"))

	child.lua([[ vim.cmd('SpacetimeFunctions spacegym') ]])

	local reducers = reducer_lines()
	-- 5 of the module's 19 reducers are Private, and the lifecycle ones are among
	-- them.
	local private = vim.tbl_filter(function(line)
		return line:find("Private", 1, true) ~= nil
	end, reducers)
	expect.equality(#private, 5)
	expect.equality(line_with(reducers, "on_connect"):match("^%s+(%a+)%s+(.*)$"), "Private")

	local greyed = vim.tbl_filter(function(mark)
		return mark[3] == "SpacetimeNull"
	end, content_marks())
	-- Two marks each — the marker and the signature — for the five Private ones.
	expect.equality(#greyed, 10)
end

-- The reason `visibility` is nilable at all: v9 carries no such field, so every
-- reducer's visibility is unknown. Unknown means callable, and a marker that said
-- `Private` on an older server would be actively misleading.
T["the same module on a v9 server marks no reducer Private"] = function()
	serve_v9(read("schema_v9.json"))

	child.lua([[ vim.cmd('SpacetimeFunctions spacegym') ]])

	expect.equality(content_lines()[2], "19 reducers · schema v9")
	-- v10 was asked for first and rejected, so this really is the fallback path.
	expect.equality(schema_requests(), 2)

	local reducers = reducer_lines()
	expect.equality(#reducers, 19)
	for _, line in ipairs(reducers) do
		expect.equality(line:find("Private", 1, true), nil)
		expect.equality(line:find("ClientCallable", 1, true), nil)
	end

	-- The reducer v10 calls Private is listed, with no marker and no invented
	-- return types: the access column does not exist at all on a v9 schema.
	expect.equality(line_with(reducers, "on_connect"), "  on_connect()")
	expect.equality(#vim.tbl_filter(function(mark)
		return mark[3] == "SpacetimeNull"
	end, content_marks()), 0)
end

-- The default stub schema is a bare `{typespace, tables}` document, which is the
-- v9 shape and carries no reducers at all.
T["a module with no reducers says so rather than rendering nothing"] = function()
	child.lua([[ vim.cmd('SpacetimeFunctions spacegym') ]])

	expect.equality(content_lines(), { "spacegym", "0 reducers · schema v9", "", "Reducers", "  (none)" })
	expect.equality(content_marks()[#content_marks()][3], "SpacetimeNull")
end

T["the database may be left off, and comes from the resolved connection"] = function()
	serve_schema(read("schema_v10.json"))
	child.lua([[ vim.env.SPACETIMEDB_DATABASE = 'spacegym' ]])

	child.lua([[ vim.cmd('SpacetimeFunctions') ]])

	expect.equality(content_lines()[1], "spacegym")
	expect.equality(child.lua_get([[REQUESTS[#REQUESTS]:find('/v1/database/spacegym/schema', 1, true) ~= nil]]), true)
end

--------------------------------------------------------------------------------
-- The cache
--------------------------------------------------------------------------------

T["a schema the session already has costs no request"] = function()
	serve_schema(read("schema_v10.json"))

	child.lua([[ vim.cmd('Spacetime') ]])
	child.type_keys("<CR>") -- expand spacegym: the sidebar fetches the schema
	expect.equality(schema_requests(), 1)

	child.lua([[ vim.cmd('SpacetimeFunctions spacegym') ]])

	expect.equality(content_lines()[2], "19 reducers · schema v10")
	expect.equality(schema_requests(), 1)
end

--------------------------------------------------------------------------------
-- The sidebar's F
--------------------------------------------------------------------------------

T["F on a database node opens its functions"] = function()
	serve_schema(read("schema_v10.json"))
	child.lua([[ vim.cmd('Spacetime') ]])
	expect.equality(sidebar_lines(), { "▸ spacegym", "▸ spacetutorial" })

	child.type_keys("F")

	expect.equality(content_lines()[1], "spacegym")
	expect.equality(content_lines()[2], "19 reducers · schema v10")
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
	-- And the cursor has not left the sidebar.
	expect.equality(child.lua_get([[vim.api.nvim_buf_get_name(0)]]), "spacetime://sidebar")
end

-- The point of the key: a table has no functions of its own, so `F` on one shows
-- the functions of the database that table belongs to — which is not necessarily
-- the first database in the tree.
T["F on a table opens that table's database's functions"] = function()
	serve_schema(read("schema_v10.json"))
	child.lua([[ vim.cmd('Spacetime') ]])

	-- Expand the *second* database and put the cursor on one of its tables.
	child.type_keys("j", "<CR>", "j")
	expect.equality(sidebar_lines()[2], "▾ spacetutorial")

	child.type_keys("F")

	expect.equality(content_lines()[1], "spacetutorial")
	expect.equality(content_lines()[2], "19 reducers · schema v10")
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

T["F on a line that belongs to no database says so and does nothing"] = function()
	child.lua([[ RESPONDER = function() return { status = 500, body = 'kaboom' } end ]])
	child.lua([[ vim.cmd('Spacetime') ]])
	expect.equality(sidebar_lines(), { "error: HTTP 500: kaboom" })

	child.lua([[ expect.no_error(function() vim.cmd('normal F') end) ]])

	expect.equality(content_lines(), child.lua_get([[require('spacetime.ui.sidebar').PLACEHOLDER]]))
	expect.equality(child.lua_get([[NOTIFIED]]), { "[spacetime] there are no functions to show here" })
end

-- `r` refreshes and `F` opens the functions: the two are no longer a case pair,
-- but `r` must still do exactly what it always did.
T["r still refreshes rather than opening the functions"] = function()
	serve_schema(read("schema_v10.json"))
	child.lua([[ vim.cmd('Spacetime') ]])
	local before = child.lua_get([[#REQUESTS]])

	child.type_keys("r")

	expect.equality(child.lua_get([[#REQUESTS]]) > before, true)
	-- The content window is still on the placeholder, so `r` had no view to
	-- refresh alongside the tree and left it alone.
	expect.equality(content_lines(), child.lua_get([[require('spacetime.ui.sidebar').PLACEHOLDER]]))
end

-- And once there *is* a view, the same key refreshes it too: the schema behind
-- the function list is cached with no expiry, so `r` is how a republished module
-- reaches the screen.
T["r re-requests the schema behind the function list"] = function()
	serve_schema(read("schema_v10.json"))
	child.lua([[ vim.cmd('SpacetimeFunctions spacegym') ]])
	expect.equality(content_lines()[1], "spacegym")
	expect.equality(schema_requests(), 1)

	-- Pressed in the content window, where the functions view binds it as one of
	-- the three shared keys.
	child.lua([[ vim.api.nvim_set_current_win(B.window_showing(B.find('spacetime://content'))) ]])
	serve_schema('{"typespace":{"types":[]},"tables":[]}')
	child.type_keys("r")

	expect.equality(schema_requests(), 2)
	-- The republished module has none, and the view says so rather than showing
	-- the list it had cached.
	expect.equality(content_lines(), { "spacegym", "0 reducers · schema v9", "", "Reducers", "  (none)" })
end

--------------------------------------------------------------------------------
-- Sharing the content buffer
--------------------------------------------------------------------------------

---Every key mapped buffer-locally in the content buffer, sorted. Asked of the
---buffer rather than of `maparg`, which answers for whichever buffer happens to
---be current.
---@return string[]
local function content_keys()
	return child.lua_get([[
		(function()
			local out = {}
			for _, map in ipairs(vim.api.nvim_buf_get_keymap(B.find('spacetime://content'), 'n')) do
				out[#out + 1] = map.lhs
			end
			table.sort(out)
			return out
		end)()
	]])
end

T["taking the buffer from the row grid leaves none of its keymaps behind"] = function()
	serve_schema(read("schema_v10.json"))

	child.lua([[ vim.cmd('SpacetimeRows spacegym.security') ]])
	expect.equality(content_keys(), { "<Tab>", "K", "Y", "[p", "]p", "q", "r", "s", "y" })

	child.lua([[ vim.cmd('SpacetimeFunctions spacegym') ]])

	expect.equality(content_lines()[1], "spacegym")
	-- Not one of the grid's keys is left on the buffer: a stale `]p` must not page
	-- a grid that is no longer displayed. The shared `q`, `<Tab>` and `r` stay,
	-- because every buffer in the layout binds them.
	expect.equality(content_keys(), { "<Tab>", "q", "r" })
end

T["q closes the layout from the functions view"] = function()
	serve_schema(read("schema_v10.json"))

	child.lua([[ vim.cmd('SpacetimeFunctions spacegym') ]])
	-- Into the content window, and press it there: `q` is the shared key, so the
	-- whole layout goes rather than just the window it was pressed in.
	child.lua([[ vim.api.nvim_set_current_win(vim.fn.win_findbuf(B.find('spacetime://content'))[1]) ]])

	child.type_keys("q")

	expect.equality(child.lua_get([[require('spacetime.ui.sidebar').is_open()]]), false)
	expect.equality(child.lua_get([[vim.tbl_count(STATE.data.inflight)]]), 0)
end

--------------------------------------------------------------------------------
-- Errors
--------------------------------------------------------------------------------

T["a failed schema request renders its message, not a stack trace"] = function()
	child.lua([[ SCHEMA_REPLY = function() return { status = 500, body = 'schema exploded' } end ]])

	child.lua([[ expect.no_error(function() vim.cmd('SpacetimeFunctions spacegym') end) ]])

	local lines = content_lines()
	expect.equality(lines, { "error: HTTP 500: schema exploded" })
	expect.equality(lines[1]:find("stack traceback"), nil)
	expect.equality(content_marks()[1][3], "SpacetimeError")
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
	expect.equality(child.lua_get([[STATE.cache_get(STATE.key('schema', 'spacegym')) == nil]]), true)
end

T["a paused database renders in the buffer rather than raising"] = function()
	child.lua([[ SCHEMA_REPLY = function() return { status = 503, body = 'database is paused' } end ]])

	child.lua([[ expect.no_error(function() vim.cmd('SpacetimeFunctions spacegym') end) ]])

	expect.equality(content_lines(), { "error: database is paused" })
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

T["with no database anywhere the command says which to write"] = function()
	child.lua([[ vim.cmd('SpacetimeFunctions') ]])

	expect.equality(schema_requests(), 0)
	local notified = child.lua_get([[NOTIFIED]])
	expect.equality(#notified, 1)
	expect.equality(notified[1]:find(":SpacetimeFunctions <database>", 1, true) ~= nil, true)
end

return T
