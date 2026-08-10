-- Tests for the static log view: `:SpacetimeLogs [db]`, rendered into the
-- content window.
--
-- A child Neovim throughout — buffers, extmarks and keymaps are real editor
-- state — with the transport seam `spacetime.lib.http` stubbed and *nothing*
-- else (tests/CLAUDE.md). Neither `lib.client` nor `lib.logs` is mocked, so the
-- NDJSON parse, the `num_lines`/`follow` query string and the 503-paused
-- classification are all genuinely exercised.
--
-- The stub drives `http.stream`, not `http.request`: `client:logs` streams
-- whether or not it is following, because a non-follow response is NDJSON too.
-- Its `on_line` callback stays in the |fast-event| context, so the stub — like
-- the plugin — touches nothing but plain tables from inside it.
--
-- The body is the committed capture of 11 real log lines, so "all 11 render" is
-- a statement about the live wire format rather than about a hand-written
-- sample.
local child, new_set = require("tests.helpers.child")()
local expect = MiniTest.expect
local read = require("tests.helpers.fixtures").read

local LOGS = read("logs.ndjson")

---One statement result with a single String column, for the rows view: the
---keymap cases need a grid on screen before the log view takes it away.
local ONE_ROW =
	'[{"schema":{"elements":[{"name":{"some":"id"},"algebraic_type":{"String":[]}}]},"rows":[["x"]],"total_duration_micros":1}]'

---One line per level, plus one level no server has: the committed fixture is
---eleven `Info` lines, which cannot exercise a filter at all. `Verbose` is the
---invented one — `lib/logs` keeps the name verbatim and ranks it as `Info`.
local MIXED = table.concat({
	'{"level":"Trace","ts":"1754728000000000","message":"trace line"}',
	'{"level":"Debug","ts":"1754728000000001","message":"debug line"}',
	'{"level":"Info","ts":"1754728000000002","message":"info line"}',
	'{"level":"Verbose","ts":"1754728000000003","message":"verbose line"}',
	'{"level":"Warn","ts":"1754728000000004","message":"warn line"}',
	'{"level":"Error","ts":"1754728000000005","message":"error line"}',
	'{"level":"Panic","ts":"1754728000000006","message":"panic line"}',
}, "\n")

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

			BODY, ROWS = ...
			-- Replaced by a case that wants a failure instead of a body.
			LOG_REPLY = function() return { status = 200, body = '' } end
			STREAMED = {}

			package.loaded['spacetime.lib.http'] = {
				request = function(opts, on_done)
					if opts.url:find('/v1/identity/', 1, true) then
						on_done(nil, { status = 200, headers = {}, body = '{"identities":[{"__identity__":"aa11"}]}' })
					elseif opts.url:find('/names', 1, true) then
						on_done(nil, { status = 200, headers = {}, body = '{"names":["spacegym"]}' })
					elseif opts.url:find('/sql', 1, true) then
						on_done(nil, { status = 200, headers = {}, body = ROWS })
					else
						on_done(nil, { status = 404, headers = {}, body = 'no such endpoint' })
					end
					return { kill = function() end }
				end,
				stream = function(opts, on_line, on_done)
					STREAMED[#STREAMED + 1] = opts.url
					local reply = LOG_REPLY(opts.url)
					if reply.status == 200 then
						-- Fast-event context: plain tables only, exactly as the real one.
						for line in BODY:gmatch('[^\n]+') do
							on_line(line)
						end
					end
					on_done(nil, { status = reply.status, headers = {}, body = reply.body })
					return { kill = function() end }
				end,
			}
		]],
			{ LOGS, ONE_ROW }
		)
	end,
})

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

---The log lines, i.e. everything below the badge.
---@return string[]
local function entry_lines()
	local lines = content_lines()
	table.remove(lines, 1)
	return lines
end

---The URL of the one and only log request, or `nil`.
---@param index? integer Defaults to the first.
---@return string|nil
local function streamed(index)
	return child.lua_get([[STREAMED[...] ]], { index or 1 })
end

---How many log requests have gone out. The level filter must never add one.
---@return integer
local function request_count()
	return child.lua_get([[#STREAMED]])
end

---Focus the content window, which is where the log view's keys are bound.
local function focus_content()
	child.lua([[ vim.api.nvim_set_current_win(B.window_showing(B.find('spacetime://content'))) ]])
end

---The trailing word of every rendered log line: `trace`, `info`, `warn`… in
---display order, with the level and timestamp columns dropped.
---@return string[]
local function messages()
	local out = {}
	for _, line in ipairs(entry_lines()) do
		out[#out + 1] = line:match("(%S+) line$") or line
	end
	return out
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

T["the fixture's eleven lines all render, level first"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs spacegym') ]])

	local lines = content_lines()
	expect.equality(lines[1], "spacegym · 11 lines · asked for 200 · level ≥ Trace")
	expect.equality(#entry_lines(), 11)

	-- Level, then the timestamp `lib/value` renders a Timestamp column with, then
	-- the message verbatim.
	expect.equality(lines[2], "Info  2026-08-09T08:43:53.970840Z  Repairing stale view backing tables")
	expect.equality(lines[3]:find("Disconnecting all users", 1, true) ~= nil, true)
	-- Every line keeps the level in the same column, so the messages line up.
	for _, line in ipairs(entry_lines()) do
		expect.equality(line:sub(1, 6), "Info  ")
	end

	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

T["the level column is highlighted, and the badge is a header"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs spacegym') ]])

	local marks = content_marks()
	expect.equality(marks[1], { 0, 0, "SpacetimeHeader" })

	local levels = vim.tbl_filter(function(mark)
		return mark[3] == "SpacetimeLogInfo"
	end, marks)
	expect.equality(#levels, 11)
	-- Exactly the four bytes of `Info`, at the start of the line: the level, not
	-- the whole entry.
	expect.equality(levels[1], { 1, 0, "SpacetimeLogInfo" })
	expect.equality(
		child.lua_get([[
		(function()
			local marks = vim.api.nvim_buf_get_extmarks(
				B.find('spacetime://content'), B.namespace(), { 1, 0 }, { 1, -1 }, { details = true })
			return marks[1][4].end_col
		end)()
	]]),
		4
	)
end

-- One bad line must never cost the other eleven. `lib/logs.parse_line` is total
-- and `lib/client:logs` drops what it answers `nil` for, so this is a test of
-- that contract holding all the way to the buffer.
T["a malformed line is skipped without aborting the render"] = function()
	child.lua([[
		local lines = vim.split(BODY, '\n', { plain = true })
		table.insert(lines, 4, '{"level":"Error","ts":"nope",,,')
		BODY = table.concat(lines, '\n')
	]])

	child.lua([[ expect.no_error(function() vim.cmd('SpacetimeLogs spacegym') end) ]])

	expect.equality(#entry_lines(), 11)
	expect.equality(content_lines()[1], "spacegym · 11 lines · asked for 200 · level ≥ Trace")
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

T["a database with nothing in its log says so rather than rendering nothing"] = function()
	child.lua([[ BODY = '' ]])

	child.lua([[ vim.cmd('SpacetimeLogs spacegym') ]])

	expect.equality(content_lines(), { "spacegym · 0 lines · asked for 200 · level ≥ Trace", "(no log entries)" })
end

--------------------------------------------------------------------------------
-- The request
--------------------------------------------------------------------------------

T["the backlog defaults to 200 lines, and follow is off"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs spacegym') ]])

	expect.equality(streamed():find("/v1/database/spacegym/logs?num_lines=200&follow=false", 1, true) ~= nil, true)
	expect.equality(child.lua_get([[#STREAMED]]), 1)
end

T["log_lines is what reaches the query string"] = function()
	child.lua([[ require('spacetime').setup({ log_lines = 5 }) ]])

	child.lua([[ vim.cmd('SpacetimeLogs spacegym') ]])

	expect.equality(streamed():find("num_lines=5&follow=false", 1, true) ~= nil, true)
	expect.equality(content_lines()[1], "spacegym · 11 lines · asked for 5 · level ≥ Trace")
end

T["a log_lines that is not a whole count of lines is rejected by setup()"] = function()
	child.lua([[
		expect.error(function() require('spacetime').setup({ log_lines = -1 }) end)
		expect.error(function() require('spacetime').setup({ log_lines = 1.5 }) end)
		expect.error(function() require('spacetime').setup({ log_lines = '200' }) end)
		expect.no_error(function() require('spacetime').setup({ log_lines = 0 }) end)
	]])
end

T["the database may be left off, and comes from the resolved connection"] = function()
	child.lua([[ vim.env.SPACETIMEDB_DATABASE = 'spacegym' ]])

	child.lua([[ vim.cmd('SpacetimeLogs') ]])

	expect.equality(streamed():find("/v1/database/spacegym/logs?", 1, true) ~= nil, true)
	expect.equality(content_lines()[1], "spacegym · 11 lines · asked for 200 · level ≥ Trace")
end

T["a second database cancels the first and leaves one request in flight"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs spacegym') ]])
	child.lua([[ vim.cmd('SpacetimeLogs archive') ]])

	expect.equality(streamed(2):find("/v1/database/archive/logs?", 1, true) ~= nil, true)
	expect.equality(content_lines()[1]:sub(1, 7), "archive")
	expect.equality(child.lua_get([[vim.tbl_count(STATE.data.inflight)]]), 0)
	-- Logs are never cached: a tail is stale the moment it lands.
	expect.equality(child.lua_get([[STATE.cache_get(STATE.key('logs', 'spacegym')) == nil]]), true)
end

--------------------------------------------------------------------------------
-- Errors
--------------------------------------------------------------------------------

-- A paused database answers 503 on every endpoint, and `lib/client.classify`
-- turns that into `kind = "paused"`. It must read as buffer text.
T["a paused database renders in the buffer rather than raising"] = function()
	child.lua([[ LOG_REPLY = function() return { status = 503, body = 'database is paused' } end ]])

	child.lua([[ expect.no_error(function() vim.cmd('SpacetimeLogs spacegym') end) ]])

	local lines = content_lines()
	expect.equality(lines, { "error: database is paused" })
	expect.equality(lines[1]:find("stack traceback"), nil)
	expect.equality(content_marks()[1][3], "SpacetimeError")
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

T["a failed log request renders its message"] = function()
	child.lua([[ LOG_REPLY = function() return { status = 500, body = 'logs exploded' } end ]])

	child.lua([[ expect.no_error(function() vim.cmd('SpacetimeLogs spacegym') end) ]])

	expect.equality(content_lines(), { "error: HTTP 500: logs exploded" })
end

T["with no database anywhere the command says which to write"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs') ]])

	expect.equality(child.lua_get([[#STREAMED]]), 0)
	local notified = child.lua_get([[NOTIFIED]])
	expect.equality(#notified, 1)
	expect.equality(notified[1]:find(":SpacetimeLogs <database>", 1, true) ~= nil, true)
end

--------------------------------------------------------------------------------
-- The level filter
--------------------------------------------------------------------------------

-- The point of the whole feature: the ring buffer is the data, so narrowing and
-- widening are both a re-layout of what is already in memory. A request here
-- would be wrong twice over — it costs a round trip, and during a follow it
-- would restart the stream under the user.
T["> raises the minimum level and < brings the hidden lines back, with no new request"] = function()
	child.lua([[ BODY = ... ]], { MIXED })
	child.lua([[ vim.cmd('SpacetimeLogs spacegym') ]])
	focus_content()
	expect.equality(messages(), { "trace", "debug", "info", "verbose", "warn", "error", "panic" })
	expect.equality(request_count(), 1)

	child.type_keys(">")
	expect.equality(messages(), { "debug", "info", "verbose", "warn", "error", "panic" })

	child.type_keys(">")
	child.type_keys(">")
	expect.equality(messages(), { "warn", "error", "panic" })

	-- Every hidden line is still *kept* — the cap and the filter are different
	-- things — so widening brings all four back without asking for them again.
	child.type_keys("<")
	expect.equality(messages(), { "info", "verbose", "warn", "error", "panic" })
	child.type_keys("<")
	child.type_keys("<")
	expect.equality(messages(), { "trace", "debug", "info", "verbose", "warn", "error", "panic" })

	-- The whole exchange put nothing on the wire.
	expect.equality(request_count(), 1)
	expect.equality(#child.lua_get([[NOTIFIED]]), 0)
end

T["the badge names the minimum, and says how many lines it is hiding"] = function()
	child.lua([[ BODY = ... ]], { MIXED })
	child.lua([[ vim.cmd('SpacetimeLogs spacegym') ]])
	focus_content()
	-- Named even when it is hiding nothing: it is the only thing on screen that
	-- says a level filter exists.
	expect.equality(content_lines()[1], "spacegym · 7 lines · asked for 200 · level ≥ Trace")

	child.type_keys(">")
	expect.equality(content_lines()[1], "spacegym · 6 of 7 lines · asked for 200 · level ≥ Debug")

	child.type_keys(">")
	child.type_keys(">")
	child.type_keys(">")
	expect.equality(content_lines()[1], "spacegym · 2 of 7 lines · asked for 200 · level ≥ Error")
end

-- `lib/logs.rank` sorts a level it does not recognise as `Info`, so the one
-- thing a user must not lose is a line whose level the server invented.
T["a level the server invented stays visible at the default, and sorts as Info"] = function()
	child.lua([[ BODY = ... ]], { MIXED })
	child.lua([[ vim.cmd('SpacetimeLogs spacegym') ]])
	focus_content()
	expect.equality(vim.tbl_contains(messages(), "verbose"), true)
	-- Rendered under its own name, not renamed to `Info`.
	expect.equality(entry_lines()[4]:sub(1, 7), "Verbose")

	-- Visible at `Info`, which it ranks as…
	child.type_keys(">")
	child.type_keys(">")
	expect.equality(vim.tbl_contains(messages(), "verbose"), true)
	-- …and gone at `Warn`, which it does not.
	child.type_keys(">")
	expect.equality(vim.tbl_contains(messages(), "verbose"), false)
end

-- Clamping, not wrapping: `>` held down must not tip over from `Error` back to
-- `Trace` and bury what the user was narrowing in on.
T["> at the top and < at the bottom stop rather than wrapping round"] = function()
	child.lua([[ BODY = ... ]], { MIXED })
	child.lua([[ vim.cmd('SpacetimeLogs spacegym') ]])
	focus_content()

	for _ = 1, 3 do
		child.type_keys("<")
	end
	expect.equality(content_lines()[1]:find("level ≥ Trace", 1, true) ~= nil, true)
	expect.equality(#messages(), 7)

	for _ = 1, 10 do
		child.type_keys(">")
	end
	-- `Error`, not `Panic`: a floor above `Error` would only ever hide errors,
	-- since a panic outranks one anyway.
	expect.equality(content_lines()[1]:find("level ≥ Error", 1, true) ~= nil, true)
	expect.equality(messages(), { "error", "panic" })

	expect.equality(request_count(), 1)
end

T["a filter that hides everything says so, and says which key widens it"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs spacegym') ]]) -- the eleven-line `Info` fixture
	focus_content()
	for _ = 1, 4 do
		child.type_keys(">")
	end

	expect.equality(content_lines(), {
		"spacegym · 0 of 11 lines · asked for 200 · level ≥ Error",
		"(no log entries at Error or above — press < to widen)",
	})
	-- Distinct from the marker a genuinely empty log gets: only one of the two is
	-- fixed by pressing `<`.
	expect.equality(request_count(), 1)
end

T["a second open starts unfiltered again"] = function()
	child.lua([[ BODY = ... ]], { MIXED })
	child.lua([[ vim.cmd('SpacetimeLogs spacegym') ]])
	focus_content()
	child.type_keys(">")
	child.type_keys(">")
	expect.equality(content_lines()[1]:find("level ≥ Info", 1, true) ~= nil, true)

	child.lua([[ vim.cmd('SpacetimeLogs archive') ]])

	expect.equality(content_lines()[1], "archive · 7 lines · asked for 200 · level ≥ Trace")
end

--------------------------------------------------------------------------------
-- Sharing the content buffer
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

T["switching to the logs and back leaves no stale keymaps"] = function()
	child.lua([[ vim.cmd('SpacetimeRows spacegym.security') ]])
	expect.equality(content_keys(), { "K", "Y", "[p", "]p", "s", "y" })

	child.lua([[ vim.cmd('SpacetimeLogs spacegym') ]])
	-- The log view's own two keys, and not one of the grid's: a stale `]p` must
	-- not page a grid that is no longer displayed. Neovim reports a `<` mapping's
	-- left-hand side as `<lt>`, which is the same key.
	expect.equality(content_keys(), { "<lt>", ">" })
	expect.equality(#entry_lines(), 11)

	-- And going back to the grid binds them again, over the logs.
	child.lua([[ vim.cmd('SpacetimeRows spacegym.security') ]])
	expect.equality(content_keys(), { "K", "Y", "[p", "]p", "s", "y" })
	expect.equality(content_lines()[1]:find("1 row", 1, true) ~= nil, true)
end

T["a log response that lands after the rows view took the buffer is dropped"] = function()
	child.lua([[
		-- Hold the log response back until the rows view has claimed the buffer.
		HELD = nil
		package.loaded['spacetime.lib.http'].stream = function(opts, on_line, on_done)
			STREAMED[#STREAMED + 1] = opts.url
			HELD = function()
				for line in BODY:gmatch('[^\n]+') do on_line(line) end
				on_done(nil, { status = 200, headers = {}, body = '' })
			end
			return { kill = function() end }
		end
	]])

	child.lua([[ vim.cmd('SpacetimeLogs spacegym') ]])
	expect.equality(content_lines(), { "loading…" })

	child.lua([[ vim.cmd('SpacetimeRows spacegym.security') ]])
	child.lua([[ HELD() ]])

	-- The grid is still on screen, and the log lines went nowhere near it.
	expect.equality(content_lines()[1]:find("1 row", 1, true) ~= nil, true)
	expect.equality(content_keys(), { "K", "Y", "[p", "]p", "s", "y" })
end

return T
