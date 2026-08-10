-- Tests for following the logs: `:SpacetimeLogs!`, the coalesced flush, the ring
-- buffer, and the three ways a follow is torn down.
--
-- A child Neovim throughout, with the transport seam `spacetime.lib.http`
-- stubbed and nothing else (tests/CLAUDE.md). The stub keeps the stream *open*
-- rather than completing inside the call, which is the whole difference from
-- `test_logs_ui.lua`: it hands its `on_line` back to the test as `FEED` so lines
-- can be delivered on demand, and it counts `kill()`s so each teardown path can
-- be checked from the outside.
--
-- Two things the stub copies from `lib/http.stream` deliberately, because the
-- plugin's behaviour depends on both:
--
--   * `on_line` is called straight, in the caller's context, exactly as the real
--     one does from its |fast-event| stdout handler. Nothing in the stub touches
--     `vim.api` from inside it.
--   * `kill()` reports `(nil, nil)` — a cancelled stream is not an error — and
--     does so through `vim.schedule`, so a stop is delivered on a later turn just
--     as it is in production.
--
-- Writes are counted by wrapping `ui/buffer.set_lines`, which is the one place
-- every renderer in this plugin writes lines through.
local child, new_set = require("tests.helpers.child")()
local expect = MiniTest.expect

---How long a `vim.wait` predicate is given before the test gives up on it.
local PATIENCE = 5000

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
			STATE = require('spacetime.state')

			NOTIFIED = {}
			vim.notify = function(msg) NOTIFIED[#NOTIFIED + 1] = msg end

			-- One counter per buffer write, so "500 lines produced N writes" is a
			-- statement about the thing the coalescing exists to reduce.
			WRITES = 0
			local set_lines = B.set_lines
			B.set_lines = function(...)
				WRITES = WRITES + 1
				return set_lines(...)
			end

			STREAMED = {}
			KILLED = 0
			FEED = nil
			ENDED = nil

			package.loaded['spacetime.lib.http'] = {
				request = function(opts, on_done)
					if opts.url:find('/v1/identity/', 1, true) then
						on_done(nil, { status = 200, headers = {}, body = '{"identities":[{"__identity__":"aa11"}]}' })
					elseif opts.url:find('/names', 1, true) then
						on_done(nil, { status = 200, headers = {}, body = '{"names":["spacegym"]}' })
					else
						on_done(nil, { status = 404, headers = {}, body = 'no such endpoint' })
					end
					return { kill = function() end }
				end,
				stream = function(opts, on_line, on_done)
					STREAMED[#STREAMED + 1] = opts.url
					-- Fast-event context in the real transport: plain tables only.
					FEED = on_line

					local done = false
					local function finish(err, res)
						if done then return end
						done = true
						vim.schedule(function() on_done(err, res) end)
					end
					-- So a case can end the stream from the server's side.
					ENDED = finish

					local cancelled = false
					return {
						kill = function()
							if cancelled then return end
							cancelled = true
							KILLED = KILLED + 1
							finish(nil, nil)
						end,
					}
				end,
			}

			---Deliver `n` log lines, as the server would.
			function FEED_LINES(n)
				for _ = 1, n do
					SENT = (SENT or 0) + 1
					FEED(('{"level":"Info","ts":"1754728000000000","message":"line %d"}'):format(SENT))
				end
			end

			---Deliver one line at a named level, for the filter cases.
			function FEED_LEVEL(level, message)
				FEED(('{"level":"%s","ts":"1754728000000000","message":"%s"}'):format(level, message))
			end

			---Whether any line of the content buffer contains `text`.
			function SHOWING(text)
				local bufnr = B.find('spacetime://content')
				for _, l in ipairs(bufnr and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) or {}) do
					if l:find(text, 1, true) then
						return true
					end
				end
				return false
			end

			---Wait until `text` is on screen.
			function SHOWS(text, patience)
				return vim.wait(patience, function() return SHOWING(text) end, 10)
			end

			---Lines currently in the content buffer, badge included.
			function LINE_COUNT()
				local bufnr = B.find('spacetime://content')
				return bufnr and vim.api.nvim_buf_line_count(bufnr) or 0
			end

			---Wait until `n` entries have been flushed into the buffer.
			function FLUSHED(n, patience)
				return vim.wait(patience, function() return LINE_COUNT() >= n + 1 end, 10)
			end

			---How many active libuv timers the child is holding.
			---
			---The flush timer is module-local to `ui/logs.lua`, so this is how a test
			---sees whether a teardown really closed it: the child boots with none of
			---its own, so any active timer here is the follow's.
			function TIMERS()
				local n = 0
				vim.uv.walk(function(handle)
					if handle:get_type() == 'timer' and handle:is_active() then
						n = n + 1
					end
				end)
				return n
			end

			---The window showing the content buffer.
			function CONTENT_WIN()
				return B.window_showing(B.find('spacetime://content'))
			end
		]])
	end,
})

---@param index? integer Defaults to the first.
---@return string|nil
local function streamed(index)
	return child.lua_get([[STREAMED[...] ]], { index or 1 })
end

---@param row integer 1-based buffer line.
---@return string
local function line(row)
	return child.lua_get(
		[[vim.api.nvim_buf_get_lines(B.find('spacetime://content'), ... - 1, ..., false)[1] ]],
		{ row }
	)
end

---@return string
local function badge()
	return line(1)
end

--------------------------------------------------------------------------------
-- The request
--------------------------------------------------------------------------------

T["the bang is what puts follow=true on the wire"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])

	expect.equality(streamed():find("/v1/database/spacegym/logs?num_lines=200&follow=true", 1, true) ~= nil, true)
	expect.equality(child.lua_get([[#STREAMED]]), 1)
	-- The follow is registered, so a second `:SpacetimeLogs` supersedes it.
	expect.equality(child.lua_get([[vim.tbl_count(STATE.data.inflight)]]), 1)
end

T["the badge says a follow is live, and says so as soon as lines arrive"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])
	child.lua([[ FEED_LINES(3) ]])
	expect.equality(child.lua_get([[FLUSHED(3, ...)]], { PATIENCE }), true)

	expect.equality(badge(), "spacegym · 3 lines · asked for 200 · level ≥ Trace · following")
	expect.equality(line(2):find("Info ", 1, true), 1)
end

--------------------------------------------------------------------------------
-- Coalescing
--------------------------------------------------------------------------------

-- The point of the whole exercise: the buffer is written on a 100 ms clock, not
-- once per line. 500 lines over ~450 ms of wall clock can produce at most a
-- handful of writes; one per line would be 500.
T["five hundred lines produce a handful of buffer writes, not five hundred"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])
	child.lua([[ WRITES = 0 ]])

	child.lua([[
		for _ = 1, 10 do
			FEED_LINES(50)
			vim.wait(30)
		end
	]])
	expect.equality(child.lua_get([[FLUSHED(500, ...)]], { PATIENCE }), true)

	local writes = child.lua_get([[WRITES]])
	-- ~450 ms at one flush per 100 ms, plus slack for a slow machine. The
	-- assertion that matters is the ratio: writes are a fraction of the lines.
	expect.equality(writes >= 1, true)
	expect.equality(writes <= 20, true)
	expect.equality(writes * 10 <= 500, true)
	expect.equality(child.lua_get([[LINE_COUNT()]]), 501)
end

T["a quiet stream does not repaint at all"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])
	child.lua([[ FEED_LINES(2) ]])
	expect.equality(child.lua_get([[FLUSHED(2, ...)]], { PATIENCE }), true)

	child.lua([[ WRITES = 0 ]])
	child.lua([[ vim.wait(350) ]])

	expect.equality(child.lua_get([[WRITES]]), 0)
end

--------------------------------------------------------------------------------
-- The ring buffer
--------------------------------------------------------------------------------

T["the ring buffer caps at five thousand entries, dropping the oldest"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])
	child.lua([[ FEED_LINES(6000) ]])
	expect.equality(child.lua_get([[FLUSHED(5000, ...)]], { PATIENCE }), true)
	child.lua([[ vim.wait(200) ]])

	expect.equality(child.lua_get([[LINE_COUNT()]]), 5001)
	expect.equality(badge(), "spacegym · 5000 lines · asked for 200 · level ≥ Trace · following")
	-- The first thousand went, oldest first, and the newest is still there.
	expect.equality(line(2):find("line 1001", 1, true) ~= nil, true)
	expect.equality(line(5001):find("line 6000", 1, true) ~= nil, true)
	expect.equality(child.lua_get([[require('spacetime.ui.logs').MAX_ENTRIES]]), 5000)
end

--------------------------------------------------------------------------------
-- Sticky bottom
--------------------------------------------------------------------------------

T["the cursor follows the bottom when it was already on the bottom"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])
	child.lua([[ FEED_LINES(20) ]])
	expect.equality(child.lua_get([[FLUSHED(20, ...)]], { PATIENCE }), true)

	child.lua([[ vim.api.nvim_win_set_cursor(CONTENT_WIN(), { LINE_COUNT(), 0 }) ]])
	child.lua([[ FEED_LINES(5) ]])
	expect.equality(child.lua_get([[FLUSHED(25, ...)]], { PATIENCE }), true)

	expect.equality(child.lua_get([[LINE_COUNT()]]), 26)
	expect.equality(child.lua_get([[vim.api.nvim_win_get_cursor(CONTENT_WIN())[1] ]]), 26)
end

-- Scrolling up to read something is the one moment a follow must keep its hands
-- off the cursor.
T["a cursor scrolled up is left where the user put it"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])
	child.lua([[ FEED_LINES(20) ]])
	expect.equality(child.lua_get([[FLUSHED(20, ...)]], { PATIENCE }), true)

	child.lua([[ vim.api.nvim_win_set_cursor(CONTENT_WIN(), { 3, 0 }) ]])
	child.lua([[ FEED_LINES(5) ]])
	expect.equality(child.lua_get([[FLUSHED(25, ...)]], { PATIENCE }), true)

	expect.equality(child.lua_get([[LINE_COUNT()]]), 26)
	expect.equality(child.lua_get([[vim.api.nvim_win_get_cursor(CONTENT_WIN())[1] ]]), 3)
end

--------------------------------------------------------------------------------
-- The level filter, mid-follow
--------------------------------------------------------------------------------

---Focus the content window, which is where the log view's keys are bound.
local function focus_content()
	child.lua([[ vim.api.nvim_set_current_win(CONTENT_WIN()) ]])
end

-- The filter lives in the render, not in the append, so a line that arrives
-- after it was set is judged by it too. Nothing about the stream changes: the
-- same `curl` keeps running, and the ring buffer keeps everything.
T["a line arriving during a follow respects the filter, which cost no request"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])
	child.lua([[ FEED_LINES(3) ]]) -- `Info`
	expect.equality(child.lua_get([[FLUSHED(3, ...)]], { PATIENCE }), true)

	focus_content()
	for _ = 1, 3 do
		child.type_keys(">") -- Trace → Debug → Info → Warn
	end
	expect.equality(badge(), "spacegym · 0 of 3 lines · asked for 200 · level ≥ Warn · following")
	expect.equality(line(2), "(no log entries at Warn or above — press < to widen)")

	-- One of each, in the same flush: only the severe one is painted.
	child.lua([[ FEED_LEVEL('Error', 'boom') ]])
	child.lua([[ FEED_LEVEL('Info', 'chatter') ]])
	expect.equality(child.lua_get([[SHOWS('boom', ...)]], { PATIENCE }), true)
	expect.equality(child.lua_get([[SHOWING('chatter')]]), false)
	expect.equality(badge(), "spacegym · 1 of 5 lines · asked for 200 · level ≥ Warn · following")

	-- Widening brings back everything that was merely hidden — the cap is on what
	-- is kept, not on what is shown — and the stream was never touched to do it.
	for _ = 1, 3 do
		child.type_keys("<")
	end
	expect.equality(badge(), "spacegym · 5 lines · asked for 200 · level ≥ Trace · following")
	expect.equality(child.lua_get([[SHOWING('chatter')]]), true)
	expect.equality(child.lua_get([[#STREAMED]]), 1)
	expect.equality(child.lua_get([[KILLED]]), 0)
end

-- The cap is on what the view *keeps*, not on what it shows, so a filter that
-- hides everything still lets the ring buffer fill and still drops the oldest.
T["the five thousand cap counts hidden lines too"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])
	focus_content()
	for _ = 1, 3 do
		child.type_keys(">") -- Warn: the `Info` lines below are all hidden
	end

	child.lua([[ FEED_LINES(6000) ]])
	expect.equality(child.lua_get([[SHOWS('0 of 5000 lines', ...)]], { PATIENCE }), true)
	-- The badge and the "nothing at this level" marker, and nothing else.
	expect.equality(child.lua_get([[LINE_COUNT()]]), 2)

	-- Widening shows the tail that was there all along: the newest 5000, oldest
	-- first, and still no second request.
	for _ = 1, 3 do
		child.type_keys("<")
	end
	expect.equality(badge(), "spacegym · 5000 lines · asked for 200 · level ≥ Trace · following")
	expect.equality(line(2):find("line 1001", 1, true) ~= nil, true)
	expect.equality(line(5001):find("line 6000", 1, true) ~= nil, true)
	expect.equality(child.lua_get([[#STREAMED]]), 1)
end

-- Filtering is a repaint, so the rule that governs every other repaint governs
-- this one too: the cursor is pulled to the new last line only if it was on the
-- old one.
T["the bottom stays sticky across a filter change"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])
	child.lua([[ FEED_LINES(20) ]])
	expect.equality(child.lua_get([[FLUSHED(20, ...)]], { PATIENCE }), true)

	focus_content()
	child.lua([[ vim.api.nvim_win_set_cursor(CONTENT_WIN(), { LINE_COUNT(), 0 }) ]])
	child.type_keys(">") -- Debug: nothing is hidden yet, but the buffer is rewritten
	expect.equality(child.lua_get([[vim.api.nvim_win_get_cursor(CONTENT_WIN())[1] ]]), 21)

	child.lua([[ FEED_LEVEL('Error', 'boom') ]])
	expect.equality(child.lua_get([[SHOWS('boom', ...)]], { PATIENCE }), true)
	expect.equality(child.lua_get([[vim.api.nvim_win_get_cursor(CONTENT_WIN())[1] ]]), 22)
end

--------------------------------------------------------------------------------
-- Teardown
--------------------------------------------------------------------------------

T[":SpacetimeLogsStop kills the stream and stops the clock"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])
	child.lua([[ FEED_LINES(4) ]])
	expect.equality(child.lua_get([[FLUSHED(4, ...)]], { PATIENCE }), true)

	child.lua([[ vim.cmd('SpacetimeLogsStop') ]])

	expect.equality(child.lua_get([[KILLED]]), 1)
	expect.equality(child.lua_get([[vim.tbl_count(STATE.data.inflight)]]), 0)
	expect.equality(badge(), "spacegym · 4 lines · asked for 200 · level ≥ Trace · stopped")

	-- The timer went with the handle: lines arriving after a stop paint nothing.
	child.lua([[ WRITES = 0 ]])
	child.lua([[ FEED_LINES(10) ]])
	child.lua([[ vim.wait(350) ]])
	expect.equality(child.lua_get([[WRITES]]), 0)
	expect.equality(child.lua_get([[LINE_COUNT()]]), 5)
end

-- `lib/client:logs` reports a cancelled stream as `cb(nil, nil)`. Stopping a
-- follow on purpose must therefore not read as a failure.
T["a clean stop is not reported as an error"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])
	child.lua([[ FEED_LINES(4) ]])
	expect.equality(child.lua_get([[FLUSHED(4, ...)]], { PATIENCE }), true)

	child.lua([[ vim.cmd('SpacetimeLogsStop') ]])
	-- Let the transport's `(nil, nil)` completion land.
	child.lua([[ vim.wait(200) ]])

	expect.equality(badge():find("error", 1, true), nil)
	expect.equality(line(2):find("error:", 1, true), nil)
	expect.equality(child.lua_get([[LINE_COUNT()]]), 5)

	local notified = child.lua_get([[NOTIFIED]])
	expect.equality(#notified, 1)
	expect.equality(notified[1]:find("stopped following spacegym", 1, true) ~= nil, true)
end

T["BufWipeout on the content buffer kills the stream"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])
	child.lua([[ FEED_LINES(2) ]])
	expect.equality(child.lua_get([[FLUSHED(2, ...)]], { PATIENCE }), true)

	-- The sidebar is a second window, so wiping the content buffer cannot take
	-- the child Neovim with it (tests/CLAUDE.md).
	expect.equality(child.lua_get([[#vim.api.nvim_tabpage_list_wins(0) >= 2]]), true)
	child.lua([[ vim.api.nvim_buf_delete(B.find('spacetime://content'), { force = true }) ]])

	expect.equality(child.lua_get([[KILLED]]), 1)
	expect.equality(child.lua_get([[vim.tbl_count(STATE.data.inflight)]]), 0)

	child.lua([[ WRITES = 0 ]])
	child.lua([[ vim.wait(350) ]])
	expect.equality(child.lua_get([[WRITES]]), 0)
end

-- Closing the layout is the fourth teardown path, and the one `BufWipeout` cannot
-- cover: `q` hides the content buffer rather than wiping it, so without a
-- teardown of its own the flush timer would tick for the rest of the session.
T["closing the layout stops the follow, timer and all"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])
	child.lua([[ FEED_LINES(2) ]])
	expect.equality(child.lua_get([[FLUSHED(2, ...)]], { PATIENCE }), true)
	expect.equality(child.lua_get([[TIMERS() >= 1]]), true)

	child.lua([[ require('spacetime.ui.sidebar').close() ]])

	expect.equality(child.lua_get([[KILLED]]), 1)
	expect.equality(child.lua_get([[vim.tbl_count(STATE.data.inflight)]]), 0)
	-- The timer went with the handle, rather than being left to fire at a buffer
	-- nobody is looking at.
	expect.equality(child.lua_get([[TIMERS()]]), 0)

	child.lua([[ WRITES = 0 ]])
	child.lua([[ FEED_LINES(10) ]])
	child.lua([[ vim.wait(350) ]])
	expect.equality(child.lua_get([[WRITES]]), 0)

	-- And the view knows it has stopped: `:SpacetimeLogsStop` has nothing left to
	-- do, which is the fact a silent teardown had to get right.
	child.lua([[ NOTIFIED = {} ]])
	child.lua([[ vim.cmd('SpacetimeLogsStop') ]])
	local notified = child.lua_get([[NOTIFIED]])
	expect.equality(#notified, 1)
	expect.equality(notified[1]:find("no log follow is running", 1, true) ~= nil, true)
end

-- The failure this exists to prevent is a `curl` still running after Neovim has
-- gone. Fired by hand: a child that really exited could not be asked about it.
T["VimLeavePre kills the stream"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])
	child.lua([[ FEED_LINES(2) ]])
	expect.equality(child.lua_get([[FLUSHED(2, ...)]], { PATIENCE }), true)

	child.lua([[ vim.api.nvim_exec_autocmds('VimLeavePre', {}) ]])

	expect.equality(child.lua_get([[KILLED]]), 1)
	expect.equality(child.lua_get([[vim.tbl_count(STATE.data.inflight)]]), 0)
end

T["a static open stops the follow it replaces"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])
	child.lua([[ FEED_LINES(2) ]])
	expect.equality(child.lua_get([[FLUSHED(2, ...)]], { PATIENCE }), true)

	child.lua([[ vim.cmd('SpacetimeLogs spacegym') ]])

	expect.equality(child.lua_get([[KILLED]]), 1)
	expect.equality(streamed(2):find("follow=false", 1, true) ~= nil, true)

	-- The second request is a fresh view: the first follow's lines are gone, and
	-- the badge no longer claims anything about following.
	child.lua([[ FEED_LINES(1) ]])
	child.lua([[ ENDED(nil, { status = 200, headers = {}, body = '' }) ]])
	child.lua([[ vim.wait(200) ]])
	expect.equality(badge(), "spacegym · 1 line · asked for 200 · level ≥ Trace")
end

T[":SpacetimeLogsStop says so when nothing is running"] = function()
	child.lua([[ vim.cmd('SpacetimeLogsStop') ]])

	local notified = child.lua_get([[NOTIFIED]])
	expect.equality(#notified, 1)
	expect.equality(notified[1]:find("no log follow is running", 1, true) ~= nil, true)
	expect.equality(child.lua_get([[KILLED]]), 0)
end

-- A follow that never saw a line and is then stopped must not sit on `loading…`:
-- that reads as a hang rather than as a stop.
T["stopping before the first line still leaves a rendered view"] = function()
	child.lua([[ vim.cmd('SpacetimeLogs! spacegym') ]])

	child.lua([[ vim.cmd('SpacetimeLogsStop') ]])

	expect.equality(badge(), "spacegym · 0 lines · asked for 200 · level ≥ Trace · stopped")
	expect.equality(line(2), "(no log entries)")
end

return T
