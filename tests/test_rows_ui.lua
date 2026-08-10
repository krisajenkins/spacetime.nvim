-- Tests for the row grid: `<CR>` on a table in the sidebar, rendered into the
-- content window.
--
-- A child Neovim throughout — buffers, extmarks and keymaps are real editor
-- state — with the transport seam `spacetime.lib.http` stubbed and *nothing*
-- else (tests/CLAUDE.md). Neither `lib.client` nor `lib.sql` is mocked, so the
-- 400-is-a-plain-text-SQL-error mapping, the envelope parser and the big-integer
-- path through `lib/json.lua` are all genuinely exercised.
--
-- The stub answers `/sql` from the `SQL` table, keyed by a fragment of the query
-- body, so a case says which table it is stubbing rather than which URL. With
-- `HOLD_SQL` set it parks the reply in `PENDING` instead of delivering it, which
-- is how two overlapping fetches are staged without a timer — and staging them
-- is the whole point: the sequence guard only matters when the *first* table's
-- response lands after the second's.
local child, new_set = require("tests.helpers.child")()
local expect = MiniTest.expect
local read = require("tests.helpers.fixtures").read

-- Two tables, no columns: the cases that are not about the schema still need a
-- table node to press `<CR>` on. The ones that are about it (primary keys)
-- install the live v10 fixture instead.
local MINI_SCHEMA = '{"typespace":{"types":[]},"tables":[{"name":"alpha"},{"name":"beta"}]}'

---One statement result with a single String column, as the server sends it.
---@param column string
---@param value string
---@return string
local function one_column(column, value)
	return ('[{"schema":{"elements":[{"name":{"some":"%s"},"algebraic_type":{"String":[]}}]},"rows":[["%s"]],"total_duration_micros":1}]'):format(
		column,
		value
	)
end

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
			S = require('spacetime.ui.sidebar')
			STATE = require('spacetime.state')

			NOTIFIED = {}
			vim.notify = function(msg) NOTIFIED[#NOTIFIED + 1] = msg end

			SCHEMA = ...
			SQL = {}
			PENDING = {}
			HOLD_SQL = false
			REQUESTS, QUERIES, KILLED = {}, {}, 0

			RESPONDER = function(url, body)
				if url:find('/v1/identity/', 1, true) then
					return { status = 200, body = '{"identities":[{"__identity__":"aa11"}]}' }
				end
				if url:find('/names', 1, true) then
					return { status = 200, body = '{"names":["spacegym"]}' }
				end
				if url:find('/schema?', 1, true) then
					return { status = 200, body = SCHEMA }
				end
				if url:find('/sql', 1, true) then
					for fragment, response in pairs(SQL) do
						if body:find(fragment, 1, true) then return response end
					end
					return { status = 404, body = 'no stub for ' .. tostring(body) }
				end
				return { status = 404, body = 'no such endpoint' }
			end

			package.loaded['spacetime.lib.http'] = {
				request = function(opts, on_done)
					REQUESTS[#REQUESTS + 1] = opts.url
					local is_sql = opts.url:find('/sql', 1, true) ~= nil
					if is_sql then QUERIES[#QUERIES + 1] = opts.body end

					local function reply()
						local response = RESPONDER(opts.url, opts.body)
						if response then
							on_done(nil, { status = response.status, headers = {}, body = response.body })
						end
					end

					if is_sql and HOLD_SQL then
						PENDING[#PENDING + 1] = reply
					else
						reply()
					end
					return { kill = function() KILLED = KILLED + 1 end }
				end,
				stream = function() error('the rows view must not stream') end,
			}
		]],
			{ MINI_SCHEMA }
		)
	end,
})

---Stub the SQL endpoint for every query containing `fragment`.
---@param fragment string e.g. `'"alpha"'`
---@param status integer
---@param body string
local function serve_sql(fragment, status, body)
	child.lua(
		[[
			local fragment, status, body = ...
			SQL[fragment] = { status = status, body = body }
		]],
		{ fragment, status, body }
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

---Open the browser, expand the one database, and put the cursor on `row`.
---@param row integer 1-based sidebar line: 2 is the first table.
local function expand_to(row)
	child.lua([[ vim.cmd('Spacetime') ]])
	child.type_keys("<CR>")
	child.lua([[ vim.api.nvim_win_set_cursor(0, { ..., 0 }) ]], { row })
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

T["<CR> on a table renders its rows, aligned by display width"] = function()
	serve_sql('"alpha"', 200, read("sql_rows.json"))
	expand_to(2)

	child.type_keys("<CR>")

	local lines = content_lines()
	-- A header and the fixture's two rows.
	expect.equality(#lines, 3)
	expect.equality(lines[1]:find("security_id", 1, true), 1)
	-- The Option column renders through `lib/value`, quoted because it is nested.
	expect.equality(lines[2]:find('some("£")', 1, true) ~= nil, true)
	expect.equality(lines[3]:find('some("🎟")', 1, true) ~= nil, true)

	-- The real property: the `code` column starts at the same *display* column on
	-- every line. `£` is 1 column in 2 bytes and `🎟` is 2 columns in 4, so a
	-- byte-based layout would put these three starts two columns apart.
	local starts = child.lua_get([[
		(function()
			local out = {}
			for i, line in ipairs(vim.api.nvim_buf_get_lines(B.find('spacetime://content'), 0, -1, false)) do
				local at = assert(line:find('code', 1, true) or line:find('some(', 1, true))
				out[i] = vim.fn.strdisplaywidth(line:sub(1, at - 1))
			end
			return out
		end)()
	]])
	expect.equality(starts[1], starts[2])
	expect.equality(starts[2], starts[3])

	-- One statement, built by `lib/sql.select_all` and nothing else.
	expect.equality(child.lua_get([[QUERIES]]), {
		('SELECT * FROM "alpha" LIMIT %d'):format(child.lua_get([[require('spacetime.ui.rows').PAGE_SIZE]])),
	})
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

T["a table with no rows says so rather than showing a bare header"] = function()
	serve_sql('"alpha"', 200, '[{"schema":{"elements":[{"name":{"some":"id"},"algebraic_type":{"U8":[]}}]},"rows":[]}]')
	expand_to(2)

	child.type_keys("<CR>")

	expect.equality(content_lines(), { "id", "(no rows)" })
end

T["a big integer keeps the exact spelling lib/json gave it"] = function()
	serve_sql('"alpha"', 200, read("sql_bigint.json"))
	expand_to(2)

	child.type_keys("<CR>")

	local lines = content_lines()
	expect.equality(#lines, 2)
	-- The U256 arrives as hex and stays hex — the column's 40-column budget cuts
	-- it, so what is on screen is a prefix and an ellipsis, not a rounded value.
	expect.equality(lines[2]:find("0xc2005efe02e92547ddd4bd", 1, true), 1)
	expect.equality(lines[2]:find("…", 1, true) ~= nil, true)
	-- The U128 arrives as a bare number and `lib/json.lua` hands it back as 39
	-- exact digits, which fit. `vim.json.decode` would have made that
	-- `1.1858454210193e+38`, and the yank register would have been a lie.
	expect.equality(lines[2]:find("118584542101933595460429904643539362103", 1, true) ~= nil, true)
	expect.equality(lines[2]:find("e+", 1, true), nil)
end

--------------------------------------------------------------------------------
-- Writes and marks
--------------------------------------------------------------------------------

T["the whole grid is written in one nvim_buf_set_lines call"] = function()
	serve_sql('"alpha"', 200, read("sql_rows.json"))
	child.lua([[ HOLD_SQL = true ]])
	expand_to(2)
	child.type_keys("<CR>")
	expect.equality(content_lines(), { "loading…" })

	-- Count only the render of the response: the loading line was a write of its
	-- own, and is not what the budget is about.
	child.lua([[
		WRITES = 0
		local original = vim.api.nvim_buf_set_lines
		vim.api.nvim_buf_set_lines = function(...)
			WRITES = WRITES + 1
			return original(...)
		end
	]])
	child.lua([[ PENDING[1]() ]])

	expect.equality(child.lua_get([[WRITES]]), 1)
	expect.equality(#content_lines(), 3)
end

T["extmarks count features, not cells"] = function()
	serve_sql('"alpha"', 200, read("sql_rows.json"))
	expand_to(2)

	child.type_keys("<CR>")

	-- Four columns over two rows is eight cells. What gets a mark is four headers
	-- plus the one ellipsis where the long description was truncated — and
	-- nothing else, because an unclassified, untruncated cell needs no mark.
	local counted = {}
	for _, mark in ipairs(content_marks()) do
		counted[mark[3]] = (counted[mark[3]] or 0) + 1
	end
	expect.equality(counted, { SpacetimeHeader = 4, SpacetimeTruncated = 1 })
end

T["a NULL cell is marked, and so is a primary-key header"] = function()
	child.lua([[ SCHEMA = ... ]], { read("schema_v10.json") })
	serve_sql('"security"', 200, read("sql_rows.json"))
	-- The live fixture's tables sort with `security` eleventh, so it is line 12.
	expand_to(12)

	child.type_keys("<CR>")

	expect.equality(child.lua_get([[QUERIES[1] ]]):find('FROM "security"', 1, true) ~= nil, true)
	-- `security_id` is the table's primary key, and the header says so.
	local marks = content_marks()
	expect.equality({ marks[1][1], marks[1][2], marks[1][3] }, { 0, 0, "SpacetimePrimaryKey" })

	-- And a `none` in the Option column is a NULL, marked as one.
	serve_sql(
		'"security"',
		200,
		table.concat({
			'[{"schema":{"elements":[',
			'{"name":{"some":"code"},"algebraic_type":{"Sum":{"variants":[',
			'{"name":{"some":"some"},"algebraic_type":{"String":[]}},',
			'{"name":{"some":"none"},"algebraic_type":{"Product":{"elements":[]}}}]}}}',
			']},"rows":[[[1,[]]]]}]',
		})
	)
	child.lua([[ STATE.cache_invalidate(STATE.key('rows', 'spacegym', 'security')) ]])
	child.type_keys("<CR>")

	expect.equality(content_lines(), { "code", "none" })
	expect.equality(content_marks(), { { 0, 0, "SpacetimeHeader" }, { 1, 0, "SpacetimeNull" } })
end

--------------------------------------------------------------------------------
-- Sorting
--------------------------------------------------------------------------------

-- Two columns whose value order and text order disagree: `9` renders as `"9"`,
-- which sorts *after* `"10"`.
local NUMERIC = table.concat({
	'[{"schema":{"elements":[',
	'{"name":{"some":"n"},"algebraic_type":{"U64":[]}},',
	'{"name":{"some":"label"},"algebraic_type":{"String":[]}}',
	']},"rows":[[9,"nine"],[10,"ten"],[1,"one"]]}]',
})

---Focus the content window, which is where the grid's keys are bound.
local function focus_content()
	child.lua([[ vim.api.nvim_set_current_win(B.window_showing(B.find('spacetime://content'))) ]])
end

---The trailing word of every data line: the `label` column, in display order.
---@return string[]
local function labels()
	local out = {}
	for i, line in ipairs(content_lines()) do
		if i > 1 then
			out[#out + 1] = line:match("%a+$")
		end
	end
	return out
end

---@return integer[] `{ line, col }`, 1-based line as Neovim reports it.
local function cursor()
	return child.lua_get([[vim.api.nvim_win_get_cursor(0)]])
end

T["s sorts by the raw value of the column under the cursor, and the cursor follows its row"] = function()
	serve_sql('"alpha"', 200, NUMERIC)
	expand_to(2)
	child.type_keys("<CR>")
	-- Data order to begin with.
	expect.equality(labels(), { "nine", "ten", "one" })

	focus_content()
	-- On the `10` row, in the numeric column.
	child.lua([[ vim.api.nvim_win_set_cursor(0, { 3, 0 }) ]])
	child.type_keys("s")

	-- 9 before 10: sorting the display strings would have put `10` first.
	expect.equality(labels(), { "one", "nine", "ten" })
	-- And the cursor is on the row it was on — now the last one — not on line 3.
	expect.equality(cursor(), { 4, 0 })
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)

	-- The rows themselves were never touched: only the mapping was rebuilt.
	expect.equality(child.lua_get([[STATE.cache_get(STATE.key('rows', 'spacegym', 'alpha')).rows[1][2] ]]), "nine")
end

T["s again reverses the same column"] = function()
	serve_sql('"alpha"', 200, NUMERIC)
	expand_to(2)
	child.type_keys("<CR>")
	focus_content()

	child.lua([[ vim.api.nvim_win_set_cursor(0, { 3, 0 }) ]]) -- the `10` row
	child.type_keys("s")
	expect.equality(cursor(), { 4, 0 })

	child.type_keys("s")
	expect.equality(labels(), { "ten", "nine", "one" })
	expect.equality(cursor(), { 2, 0 })

	-- A different column starts ascending again rather than inheriting the
	-- direction the last column was left in.
	child.lua([[
		local line = vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]
		vim.api.nvim_win_set_cursor(0, { 2, assert(line:find('ten', 1, true)) - 1 })
	]])
	child.type_keys("s")
	expect.equality(labels(), { "nine", "one", "ten" })
end

T["the cursor keeps its column when its row moves"] = function()
	serve_sql('"alpha"', 200, read("sql_rows.json"))
	expand_to(2)
	child.type_keys("<CR>")
	focus_content()

	-- The `code` column, on the 🎟 row. `£` is 2 bytes and `🎟` is 4, so the
	-- column starts at a *different byte offset* on the two rows — which is the
	-- case a byte-preserving cursor restore would get wrong.
	child.lua([[
		local line = vim.api.nvim_buf_get_lines(0, 2, 3, false)[1]
		vim.api.nvim_win_set_cursor(0, { 3, assert(line:find('some(', 1, true)) - 1 })
	]])
	---The display column a byte offset sits at on `line` — the units the grid
	---aligns in, and the only ones in which "the same column" means anything.
	---@param line integer
	---@param col integer
	---@return integer
	local function display_column(line, col)
		return child.lua_get(
			[[(function(at, col)
				return vim.fn.strdisplaywidth(vim.api.nvim_buf_get_lines(0, at - 1, at, false)[1]:sub(1, col))
			end)(...)]],
			{ line, col }
		)
	end

	local before = cursor()
	local before_column = display_column(before[1], before[2])
	child.type_keys("s") -- ascending: "£" < "🎟" byte-wise, so nothing moves
	expect.equality(cursor(), before)

	child.type_keys("s") -- descending: the 🎟 row goes first
	expect.equality(content_lines()[2]:find("🎟", 1, true) ~= nil, true)
	local after = cursor()
	expect.equality(after[1], 2)
	-- Still on the first byte of that cell, at the offset *this* line puts it at.
	expect.equality(
		after[2],
		child.lua_get([[vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]:find('some(', 1, true) - 1]])
	)
	-- And the same grid column, said in the units the grid aligns in.
	expect.equality(display_column(after[1], after[2]), before_column)
end

T["s on the header sorts without moving the cursor, and does nothing at all without a grid"] = function()
	serve_sql('"alpha"', 200, NUMERIC)
	expand_to(2)
	child.type_keys("<CR>")
	focus_content()

	child.lua([[ vim.api.nvim_win_set_cursor(0, { 1, 0 }) ]])
	child.type_keys("s")
	expect.equality(labels(), { "one", "nine", "ten" })
	expect.equality(cursor(), { 1, 0 })

	-- An error is buffer text, not a grid: `s` must be a no-op on it rather than
	-- a raise under the cursor.
	child.lua([[ STATE.cache_invalidate(STATE.key('rows', 'spacegym', 'alpha')) ]])
	serve_sql('"alpha"', 400, "SqlError: Unknown table: alpha")
	child.lua([[ S.select() ]])
	expect.equality(content_lines(), { "error: SqlError: Unknown table: alpha" })

	focus_content()
	child.lua([[ expect.no_error(function() vim.cmd('normal s') end) ]])
	expect.equality(content_lines(), { "error: SqlError: Unknown table: alpha" })
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

--------------------------------------------------------------------------------
-- Errors
--------------------------------------------------------------------------------

T["a SQL error renders its plain text in the buffer, and nothing raises"] = function()
	-- A SQL failure is an HTTP 400 whose body is plain text, not JSON.
	serve_sql('"alpha"', 400, "SqlError: Unknown table: alpha\n  at line 1")
	expand_to(2)

	child.lua([[ expect.no_error(function() S.select() end) ]])

	expect.equality(content_lines(), { "error: SqlError: Unknown table: alpha", "  at line 1" })
	expect.equality(content_marks()[1][3], "SpacetimeError")
	-- No notification, no `E`-code, no traceback: the message is the whole report.
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
	expect.equality(child.lua_get([[STATE.cache_get(STATE.key('rows', 'spacegym', 'alpha')) == nil]]), true)
end

T["a malformed row renders as text rather than a stack trace"] = function()
	-- Two columns, one cell: `ui/grid.lua` treats a ragged row as fatal, and this
	-- module is what stops that reaching the user.
	serve_sql(
		'"alpha"',
		200,
		'[{"schema":{"elements":[{"name":{"some":"a"}},{"name":{"some":"b"}}]},"rows":[["only one"]]}]'
	)
	expand_to(2)

	child.lua([[ expect.no_error(function() S.select() end) ]])

	local lines = content_lines()
	expect.equality(#lines, 1)
	expect.equality(lines[1]:find("error: ", 1, true), 1)
	expect.equality(lines[1]:find("stack traceback"), nil)
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

--------------------------------------------------------------------------------
-- Cancellation
--------------------------------------------------------------------------------

-- The issue's "done when", and the reason the sequence guard exists at all: two
-- tables are two keys, so nothing about `state.start` protects the second table
-- from the first table's response. `ui/rows.lua` cancels the table it switches
-- away from, which burns that key's token.
T["switching tables quickly leaves the second table's rows on screen"] = function()
	serve_sql('"alpha"', 200, one_column("alpha_id", "from alpha"))
	serve_sql('"beta"', 200, one_column("beta_id", "from beta"))
	child.lua([[ HOLD_SQL = true ]])

	expand_to(2)
	child.type_keys("<CR>") -- alpha, held
	child.type_keys("j", "<CR>") -- beta, held

	expect.equality(child.lua_get([[#PENDING]]), 2)
	-- Switching killed alpha's handle. `kill` is asynchronous, though, so the
	-- response may still arrive — which is what the rest of this case stages.
	expect.equality(child.lua_get([[KILLED]]), 1)

	-- Beta answers first, alpha's late response lands afterwards.
	child.lua([[ PENDING[2]() ]])
	child.lua([[ PENDING[1]() ]])

	expect.equality(content_lines(), { "beta_id", "from beta" })
	-- Dropped entirely: not painted, and not cached either.
	expect.equality(child.lua_get([[STATE.cache_get(STATE.key('rows', 'spacegym', 'alpha')) == nil]]), true)
	expect.equality(child.lua_get([[STATE.cache_get(STATE.key('rows', 'spacegym', 'beta')) ~= nil]]), true)
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

T["reopening a table serves it from the session cache"] = function()
	serve_sql('"alpha"', 200, one_column("alpha_id", "from alpha"))
	expand_to(2)

	child.type_keys("<CR>")
	child.type_keys("j", "<CR>") -- beta: no stub, so it 404s
	child.type_keys("k", "<CR>") -- back to alpha

	expect.equality(content_lines(), { "alpha_id", "from alpha" })
	-- Two statements for three openings: alpha's second render came from the cache.
	expect.equality(#child.lua_get([[QUERIES]]), 2)
end

T["closing the browser cancels a fetch that is still in flight"] = function()
	serve_sql('"alpha"', 200, one_column("alpha_id", "from alpha"))
	child.lua([[ HOLD_SQL = true ]])
	expand_to(2)

	child.type_keys("<CR>")
	expect.equality(child.lua_get([[vim.tbl_count(STATE.data.inflight)]]), 1)

	child.type_keys("q")

	expect.equality(child.lua_get([[vim.tbl_count(STATE.data.inflight)]]), 0)
	expect.equality(child.lua_get([[KILLED]]), 1)
	-- The response still arrives; it must not repaint a buffer nobody is looking
	-- at, and it must not raise on the way.
	child.lua([[ expect.no_error(function() PENDING[1]() end) ]])
	expect.equality(content_lines(), { "loading…" })
end

return T
