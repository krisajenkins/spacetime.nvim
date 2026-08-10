-- Tests for the schema detail view: `:SpacetimeSchema [db.]tbl`, rendered into
-- the content window.
--
-- A child Neovim throughout — buffers, extmarks and keymaps are real editor
-- state — with the transport seam `spacetime.lib.http` stubbed and *nothing*
-- else (tests/CLAUDE.md). Neither `lib.client` nor `lib.schema` is mocked, so
-- the version negotiation, the v10 sections and the v9 fallback are all
-- genuinely exercised against the two committed captures of the same module.
--
-- That pairing is the point of the file. `schema_v10.json` and `schema_v9.json`
-- are the same live module in both wire shapes, so the same assertions can be
-- run twice, and the v9 run is what proves the fallback path is really taken.
--
-- The reducers are NOT here: they belong to the database rather than to any one
-- table and have a view of their own (tests/test_reducers_ui.lua). What this file
-- asserts about them is that this view no longer mentions them at all.
local child, new_set = require("tests.helpers.child")()
local expect = MiniTest.expect
local read = require("tests.helpers.fixtures").read

---One statement result with a single String column, for the rows view: the
---keymap case needs a grid on screen before the schema view takes it away.
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

			RESPONDER = function(url)
				if url:find('/v1/identity/', 1, true) then
					return { status = 200, body = '{"identities":[{"__identity__":"aa11"}]}' }
				end
				if url:find('/names', 1, true) then
					return { status = 200, body = '{"names":["spacegym"]}' }
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
				stream = function() error('the schema view must not stream') end,
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

---Every extmark in the content buffer as `{ line, col, hl_group }`.
---@return table[]
local function content_marks()
	return child.lua_get([[
		vim.tbl_map(function(mark)
			return { mark[2], mark[3], mark[4].hl_group }
		end, vim.api.nvim_buf_get_extmarks(B.find('spacetime://content'), B.namespace(), 0, -1, { details = true }))
	]])
end

---The lines of one section: everything between its heading and the blank line
---that starts the next one.
---@param heading string e.g. `"Columns"`, `"Indexes"`.
---@return string[]
local function section(heading)
	local out, inside = {}, false
	for _, line in ipairs(content_lines()) do
		if inside then
			if line == "" then
				break
			end
			out[#out + 1] = line
		elseif line:sub(1, #heading) == heading then
			inside = true
		end
	end
	return out
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
-- Columns
--------------------------------------------------------------------------------

T["the columns render with resolved types and a primary-key marker"] = function()
	serve_schema(read("schema_v10.json"))

	child.lua([[ vim.cmd('SpacetimeSchema spacegym.ledgerEntry') ]])

	local lines = content_lines()
	-- Both spellings, because the module wrote `ledgerEntry` and SQL knows it as
	-- `ledger_entry` — and either is accepted by the endpoint.
	expect.equality(lines[1], "ledgerEntry (ledger_entry)")
	expect.equality(lines[2], "table · Private · 5 columns · schema v10")

	local columns = section("Columns")
	expect.equality(#columns, 5)

	-- The primary key is the sequence-backed `entry_id`, typed through
	-- `lib/value.label` rather than printed as its raw `{U64 = {}}`.
	local first = columns[1]
	expect.equality(first:find("entry_id", 1, true), 3)
	expect.equality(first:find("U64", 1, true) ~= nil, true)
	expect.equality(first:find("PK autoinc", 1, true) ~= nil, true)

	-- An unrecognised newtype is shown as the plain product it is, rather than
	-- guessed at: `lib/value` is deliberately verbatim about `__uuid__`.
	expect.equality(line_with(columns, "transaction_id"):find("{ __uuid__: U128 }", 1, true) ~= nil, true)
	-- And an Array column says what it is an array of.
	expect.equality(line_with(columns, "account"):find("Array<String>", 1, true) ~= nil, true)

	-- The name of the primary-key column is marked as one; the title is a header.
	local marks = content_marks()
	expect.equality(marks[1][3], "SpacetimeHeader")
	expect.equality(#vim.tbl_filter(function(mark)
		return mark[3] == "SpacetimePrimaryKey"
	end, marks), 1)

	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

T["either spelling of the table names it, and a view says it is one"] = function()
	serve_schema(read("schema_v10.json"))

	-- The SQL spelling of a table the module wrote in camelCase.
	child.lua([[ vim.cmd('SpacetimeSchema spacegym.ledger_entry') ]])
	expect.equality(content_lines()[1], "ledgerEntry (ledger_entry)")

	child.lua([[ vim.cmd('SpacetimeSchema spacegym.meView') ]])
	local lines = content_lines()
	expect.equality(lines[1], "meView (me_view)")
	expect.equality(lines[2]:find("view · ", 1, true), 1)
	-- Issue #45: a view can never have either, so the sections are dropped rather
	-- than left reading "(none)" on every view forever.
	for _, needle in ipairs({ "Indexes", "Constraints" }) do
		expect.equality({ needle, line_with(lines, needle) }, { needle, nil })
	end
end

--------------------------------------------------------------------------------
-- Indexes and constraints
--------------------------------------------------------------------------------

T["indexes and constraints render with the columns they are over"] = function()
	serve_schema(read("schema_v10.json"))

	child.lua([[ vim.cmd('SpacetimeSchema spacegym.ledgerEntry') ]])

	local indexes = section("Indexes")
	expect.equality(#indexes, 3)
	local by_entry = line_with(indexes, "ledgerEntry_entryId_idx_btree")
	-- The algorithm's `{BTree = {0}}` is column 0 of this table, named.
	expect.equality(by_entry:find("BTree(entry_id)", 1, true) ~= nil, true)
	expect.equality(by_entry:find("accessor entryId", 1, true) ~= nil, true)

	local constraints = section("Constraints")
	expect.equality(#constraints, 1)
	expect.equality(constraints[1]:find("ledger_entry_entry_id_key", 1, true), 3)
	expect.equality(constraints[1]:find("Unique(entry_id)", 1, true) ~= nil, true)
end

--------------------------------------------------------------------------------
-- No reducers
--------------------------------------------------------------------------------

-- Issue #38: the reducers are the *database's*, not the table's, so describing a
-- table must not list them. |:SpacetimeReducers| is where they live now, and
-- tests/test_reducers_ui.lua is where they are asserted.
T["the reducers are not in the schema view at all"] = function()
	serve_schema(read("schema_v10.json"))

	child.lua([[ vim.cmd('SpacetimeSchema spacegym.ledgerEntry') ]])

	-- No heading, and none of the signature or visibility text that would come
	-- with one — `book` and `onConnect` are reducers of this very module.
	expect.equality(section("Reducers"), {})
	for _, needle in ipairs({ "Reducers", "ClientCallable", "book(", "onConnect", "on_connect" }) do
		expect.equality({ needle, line_with(content_lines(), needle) }, { needle, nil })
	end

	-- The last section is Constraints, so nothing was appended below it.
	local lines = content_lines()
	expect.equality(lines[#lines - 1], "Constraints")
	-- And nothing is greyed out: the `Private` marker was the only user of that
	-- highlight in this view.
	expect.equality(#vim.tbl_filter(function(mark)
		return mark[3] == "SpacetimeNull"
	end, content_marks()), 0)
end

T["a v9 schema describes its table and no reducers either"] = function()
	serve_v9(read("schema_v9.json"))

	child.lua([[ vim.cmd('SpacetimeSchema spacegym.ledger_entry') ]])

	local lines = content_lines()
	-- v9 names are already canonical, so there is one spelling to show.
	expect.equality(lines[1], "ledger_entry")
	expect.equality(lines[2], "table · Private · 5 columns · schema v9")
	-- v10 was asked for first and rejected, so this really is the fallback path.
	expect.equality(schema_requests(), 2)

	expect.equality(section("Reducers"), {})
	expect.equality(line_with(lines, "on_connect"), nil)
end

--------------------------------------------------------------------------------
-- The cache
--------------------------------------------------------------------------------

T["a schema the session already has costs no request"] = function()
	serve_schema(read("schema_v10.json"))

	child.lua([[ vim.cmd('Spacetime') ]])
	child.type_keys("<CR>") -- expand spacegym: the sidebar fetches the schema
	expect.equality(schema_requests(), 1)

	child.lua([[ vim.cmd('SpacetimeSchema spacegym.security') ]])

	expect.equality(content_lines()[1], "security")
	expect.equality(schema_requests(), 1)
end

-- One key means one request, so `:SpacetimeSchema` can supersede a fetch the
-- sidebar started. The answer lands in the shared cache either way, and the tree
-- must not be left reading `loading…` for a request that was taken over.
T["a schema request the sidebar started is taken over, not left hanging"] = function()
	serve_schema(read("schema_v10.json"))
	child.lua([[ SCHEMA_REPLY = function() return nil end ]]) -- never answers

	child.lua([[ vim.cmd('Spacetime') ]])
	child.type_keys("<CR>")
	local sidebar = child.lua_get([[vim.api.nvim_buf_get_lines(B.find('spacetime://sidebar'), 0, -1, false)]])
	expect.equality(sidebar, { "▾ spacegym", "    loading…" })

	child.lua([[ SCHEMA_REPLY = function() return { status = 200, body = SCHEMA } end ]])
	child.lua([[ vim.cmd('SpacetimeSchema spacegym.security') ]])

	expect.equality(content_lines()[1], "security")
	sidebar = child.lua_get([[vim.api.nvim_buf_get_lines(B.find('spacetime://sidebar'), 0, -1, false)]])
	expect.equality(sidebar[1], "▾ spacegym")
	expect.equality(sidebar[2], "    🔒 booking")
	expect.equality(child.lua_get([[vim.tbl_count(STATE.data.inflight)]]), 0)
end

--------------------------------------------------------------------------------
-- Sharing the content buffer with the row grid
--------------------------------------------------------------------------------

---Every key mapped buffer-locally in the content buffer, sorted. Asked of the
---buffer rather than of `maparg`, which answers for whichever buffer happens to
---be current — and after any of these commands that is the sidebar.
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
	expect.equality(content_keys(), { "K", "Y", "[p", "]p", "q", "s", "y" })

	child.lua([[ vim.cmd('SpacetimeSchema spacegym.security') ]])

	expect.equality(content_lines()[1], "security")
	-- Not one of the grid's keys is left on the buffer: a stale `]p` must not page
	-- a grid that is no longer displayed. The shared `q` stays, because every
	-- buffer in the layout binds it.
	expect.equality(content_keys(), { "q" })

	-- And going back to the grid binds them again.
	child.lua([[ vim.cmd('SpacetimeRows spacegym.security') ]])
	expect.equality(content_keys(), { "K", "Y", "[p", "]p", "q", "s", "y" })
end

--------------------------------------------------------------------------------
-- Errors
--------------------------------------------------------------------------------

T["a table the module does not define renders as buffer text"] = function()
	serve_schema(read("schema_v10.json"))

	child.lua([[ expect.no_error(function() vim.cmd('SpacetimeSchema spacegym.nope') end) ]])

	expect.equality(content_lines(), { "error: spacegym has no table or view called nope" })
	expect.equality(content_marks()[1][3], "SpacetimeError")
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

T["a failed schema request renders its message, not a stack trace"] = function()
	child.lua([[ SCHEMA_REPLY = function() return { status = 500, body = 'schema exploded' } end ]])

	child.lua([[ expect.no_error(function() vim.cmd('SpacetimeSchema spacegym.ledgerEntry') end) ]])

	local lines = content_lines()
	expect.equality(lines, { "error: HTTP 500: schema exploded" })
	expect.equality(lines[1]:find("stack traceback"), nil)
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
	expect.equality(child.lua_get([[STATE.cache_get(STATE.key('schema', 'spacegym')) == nil]]), true)
end

T["a bare table name with no project database says which to write"] = function()
	child.lua([[ vim.cmd('SpacetimeSchema ledgerEntry') ]])

	expect.equality(schema_requests(), 0)
	local notified = child.lua_get([[NOTIFIED]])
	expect.equality(#notified, 1)
	expect.equality(notified[1]:find("db.ledgerEntry", 1, true) ~= nil, true)
end

return T
