-- The log view: what `:SpacetimeLogs[!] [db]` paints into the content window.
--
-- `lib/client:logs` puts `GET /v1/database/{db}/logs?num_lines=N&follow=…` on
-- the wire and `lib/logs.parse_line` turns each NDJSON line into an entry; this
-- module is the part that owns the buffer. It lives under `ui/` and may
-- therefore touch `vim.api`; everything it calls under `lib/` may not.
--
-- Five things this file exists to get right:
--
-- 1. **`on_entry` runs in a |fast-event| context.** `lib/http.lua`
--    schedule-wraps every callback above it *except* the streaming one, so the
--    per-entry callback here may only append to a plain Lua table. Every
--    `vim.api` call — the whole render — happens in the completion callback,
--    which is back on the main loop. Getting this the other way round is a
--    crash, not a style point.
-- 2. **A malformed line is never fatal.** `lib/logs.parse_line` is total and
--    answers `nil` for a blank, truncated or junk line, and `lib/client:logs`
--    drops those rather than calling back — so a bad line in the middle of a
--    response costs that one line and nothing else. Nothing in this file has to
--    do anything for that to hold, which is the point of stating it here.
--    The corollary is that the count of skipped lines is not observable from
--    this layer, so the badge does not claim one: the roadmap allows for showing
--    it, and inventing a number would be worse than omitting it.
-- 3. **Errors are buffer text.** A paused database (503), an unauthorised token
--    (401) or a database that is not there (404) all arrive as a
--    `SpacetimeClientError` and are rendered as lines, never raised at the user.
-- 4. **Nothing is cached.** `state.key("logs", db)` registers the request so a
--    second `:SpacetimeLogs` supersedes the first, but the answer is deliberately
--    not put in `state`'s cache: a log tail is the one thing in this plugin that
--    is stale the moment it lands, and serving it from a cache would show the
--    user yesterday's logs while telling them nothing had happened.
-- 5. **The content buffer is shared** with the row grid and the schema view.
--    `open` claims it through `ui/buffer.claim_content`, so a rows response still
--    on the wire does not paint over the logs when it lands, and the render
--    applies this view's key map through `ui/keys`, which binds `<`, `>` and the
--    shared `q` and takes the grid's `s`, `]p`, `y`, `Y` and `K` back off the
--    buffer.
--
-- The lines are laid out here rather than through `ui/grid.lua`: the grid has a
-- header row this view does not want, and it truncates a cell to 40 columns,
-- which is exactly the wrong thing to do to a log message. Two narrow columns
-- (level, timestamp) padded to their widest entry is the whole of the layout.
--
-- Follow — `:SpacetimeLogs!` — adds four rules of its own on top of those:
--
-- 6. **The buffer is written on a clock, not per line.** `on_entry` only ever
--    appends to `pending`; a single repeating |vim.uv| timer, `M.FLUSH_MS` apart,
--    moves whatever has accumulated into `view.entries` and repaints. A module
--    logging 500 lines a second therefore costs ten writes a second rather than
--    five hundred, which is the difference between a log you can read and an
--    editor that stalls. `state.debounce` is deliberately *not* reused for this:
--    it is trailing-edge and one-shot, so a stream that never goes quiet for
--    `FLUSH_MS` would restart the countdown forever and never paint at all.
-- 7. **The bottom is sticky only if the cursor was already on it.** Scrolling up
--    to read something is the one moment a follow must not move the cursor, so
--    `render` asks where the cursor is *before* the write and puts it back on the
--    last line only if that is where it already was.
-- 8. **`M.MAX_ENTRIES` is a hard cap.** `append` drops from the front once the
--    view is over it: a follow left running overnight must cost bounded memory,
--    and the oldest line is the one worth losing.
-- 9. **Every teardown path kills the handle *and* the timer.** `:SpacetimeLogsStop`,
--    `BufWipeout` on the content buffer, `VimLeavePre` and closing the layout all
--    go through `teardown`, because a leaked `curl` outliving Neovim and a
--    repeating timer firing at a wiped buffer are the same bug seen from two ends.
--    Closing the layout is the path that needs `M.teardown`: it cancels the
--    request but leaves the content buffer hidden rather than wiped, so the
--    `BufWipeout` never fires and the timer would otherwise outlive the view.
--
-- The level filter — `<` and `>` — adds one more:
--
-- 10. **The filter is a display rule, never a request.** `M.filter` moves
--     `view.min_level` along `lib/logs.MINIMUMS` and calls `M.render`; nothing
--     goes on the wire. That is not an optimisation: during a follow a refetch
--     would restart the stream, and the lines the user was reading would be
--     replaced by whatever the server sends next. The corollary is that
--     `M.MAX_ENTRIES` caps what is *kept*, not what is shown, so lowering the
--     minimum brings back every line that was merely hidden.

local M = {}

---The name this view claims the content buffer under.
M.OWNER = "logs"

---How much backlog `:SpacetimeLogs` asks for when |spacetime-opt-log_lines| is
---unset.
---
---Exported rather than inlined so the code, the tests and a user reading
---`:help` all have one number to point at — the same reason
---`ui/rows.PAGE_SIZE` is exported.
M.DEFAULT_LINES = 200

---How long a follow lets entries accumulate before it repaints, in milliseconds.
---
---The coalescing interval from ROADMAP.md — see point 6 of the module header.
M.FLUSH_MS = 100

---How many entries a follow keeps. The oldest go first.
M.MAX_ENTRIES = 5000

---The minimum level a fresh view starts at: the least severe one, which hides
---nothing.
---
---`lib/logs.rank` sorts a level it does not recognise as `Info`, and `Info`
---outranks this, so a level the server invented is visible by default too.
M.DEFAULT_MIN_LEVEL = "Trace"

---Every key the content window binds while it is showing logs.
---
---Applied on every render, which is also what *unbinds* the row grid's keys —
---see point 5 of the module header.
---@type SpacetimeKeymap[]
M.KEYMAPS = {
	{
		keys = { ">" },
		desc = "show only more severe log levels",
		action = function()
			M.filter(1)
		end,
	},
	{
		keys = { "<" },
		desc = "show less severe log levels too",
		action = function()
			M.filter(-1)
		end,
	},
	-- Shared with the sidebar and the grid: the layout is one thing, and `q`
	-- closes it from either window.
	require("spacetime.ui.keys").CLOSE,
}

local LOADING = "loading…"
local NO_ENTRIES = "(no log entries)"
---Shown when there are entries, but the filter is hiding all of them: an empty
---view and a filtered-to-nothing view are different problems, and only one of
---them is fixed by pressing `<`.
local NO_ENTRIES_AT_LEVEL = "(no log entries at %s or above — press < to widen)"
local UNKNOWN_ERROR = "unknown error"
local NO_TIMESTAMP = "?"

---Highlight group per canonical level. `lib/logs.parse_line` canonicalises the
---names it recognises, so these lookups are exact; a level the server invented
---is highlighted as `Info`, which is also the severity `lib/logs.rank` gives it.
local LEVEL_HL = {
	Panic = "SpacetimeLogPanic",
	Error = "SpacetimeLogError",
	Warn = "SpacetimeLogWarn",
	Info = "SpacetimeLogInfo",
	Debug = "SpacetimeLogDebug",
	Trace = "SpacetimeLogTrace",
}

---What |spacetime.ui.logs.open()| needs.
---
---The connection is passed in rather than resolved here, for the same reason as
---the row grid's: `config.current()` reads the project config governing the
---*current* buffer, and by the time this runs that buffer may be one of our own
---scratch buffers. The caller resolves it before the layout displaces it.
---@class SpacetimeLogsRequest
---@field connection SpacetimeConnection Resolved by the caller, not by this module.
---@field database string Database name or identity, as it goes in the URL path.
---@field num_lines? integer Backlog to ask for. Defaults to the configured value.
---@field follow? boolean Keep the connection open and stream. What `!` means.

---The request plus what has become of it.
---@class SpacetimeLogsView : SpacetimeLogsRequest
---@field num_lines integer Resolved: never `nil` once the view exists.
---@field follow boolean Resolved: never `nil` once the view exists.
---@field following boolean Is the stream live *now*? `false` once it has stopped.
---@field status "loading"|"ready"|"error"
---@field error? string Set when `status == "error"`.
---@field entries spacetime.LogEntry[] In arrival order, oldest first. Capped at `M.MAX_ENTRIES`.
---@field min_level string Least severe level shown. One of `lib/logs.MINIMUMS`.

---What is on screen, or being fetched onto it. `nil` before the first open.
---@type SpacetimeLogsView|nil
local view = nil

---The one repeating flush timer, or `nil` when nothing is being followed.
---
---Module-local rather than a field of `view`, because "at most one follow at a
---time" is the invariant, and one variable is how it is enforced. Not
---`state.data.timers`: those are `state.debounce`'s one-shot timers, and point 6
---of the module header is why this is not a debounce.
---@type any
local flush_timer = nil

---How much backlog to ask for, from |spacetime.setup()|.
---
---`setup()` has already validated the option, so anything unusable here means a
---user has assigned over `require("spacetime").config` by hand; the default is a
---better answer than no logs at all.
---@return integer
local function configured_lines()
	local configured = require("spacetime").config.log_lines
	if type(configured) ~= "number" or configured < 0 then
		return M.DEFAULT_LINES
	end
	return math.floor(configured)
end

--------------------------------------------------------------------------------
-- Building the lines
--------------------------------------------------------------------------------

---Message text as buffer lines, each marked in full.
---
---Split on newlines first: a server's error is regularly several lines long, and
---folding it onto one would hide the part that says what went wrong.
---@param message any
---@return string[] lines
---@return SpacetimeGridSpan[] spans
local function error_lines(message)
	local grid = require("spacetime.ui.grid")
	local text = (type(message) == "string" and message ~= "") and message or UNKNOWN_ERROR

	local lines, spans = {}, {}
	for _, raw in ipairs(vim.split("error: " .. text, "\n", { plain = true })) do
		local line = grid.sanitise(raw)
		lines[#lines + 1] = line
		if #line > 0 then
			spans[#spans + 1] = { line = #lines - 1, start_col = 0, end_col = #line, hl_group = "SpacetimeError" }
		end
	end
	return lines, spans
end

---The badge: which database, how much of it is on screen, and how much was
---asked for.
---
---The last piece matters more here than it looks: a tail that came back exactly
---`num_lines` long is almost certainly cut off at the top, and the number that
---produced it is the one to raise.
---
---The minimum level is always named, even at the default: it is the only thing
---on screen that says a level filter exists at all, and `<`/`>` are otherwise
---undiscoverable. When it is hiding something the count says so too — `3 of 412
---lines` — because a bare `3 lines` would read as "that is all the server sent".
---
---A follow adds a fourth field, and it is the only thing on screen that says
---whether lines are still coming: `following` while the stream is live, `stopped`
---once `:SpacetimeLogsStop` — or the server — has ended it. A static view says
---neither, because for it the question does not arise.
---@param current SpacetimeLogsView
---@param shown integer Entries rendered.
---@param total integer Entries kept, filtered and unfiltered alike.
---@return string
local function badge_text(current, shown, total)
	local count = ("%d line%s"):format(total, total == 1 and "" or "s")
	if shown ~= total then
		count = ("%d of %d lines"):format(shown, total)
	end

	local badge = ("%s · %s · asked for %d · level ≥ %s"):format(
		current.database,
		count,
		current.num_lines,
		current.min_level
	)
	if current.follow then
		badge = badge .. (current.following and " · following" or " · stopped")
	end
	return badge
end

---Every line of the view, and every span to mark on it.
---
---May raise, in principle — `M.render` calls it through `pcall` and turns
---anything that escapes into buffer text, exactly as the row grid does.
---@param current SpacetimeLogsView
---@return string[] lines
---@return SpacetimeGridSpan[] spans
local function build(current)
	if current.status == "loading" then
		return { LOADING }, {}
	end
	if current.status == "error" then
		return error_lines(current.error)
	end

	local grid = require("spacetime.ui.grid")
	local value = require("spacetime.lib.value")
	local lib_logs = require("spacetime.lib.logs")
	local entries = current.entries

	-- Two passes: the columns are padded to their widest entry, and nothing is
	-- truncated, so the widths cannot be known before every entry has been seen.
	-- The filter is applied here and nowhere else — `current.entries` keeps every
	-- line, so `<` can bring the hidden ones straight back. See point 10.
	local cells = {} ---@type { level: string, stamp: string, message: string }[]
	local level_width, stamp_width = 0, 0
	for _, entry in ipairs(entries) do
		if lib_logs.at_least(entry.level, current.min_level) then
			local level = grid.sanitise(entry.level or "")
			-- `lib/value.timestamp` is the renderer a Timestamp *column* goes through,
			-- so a log stamp and a cell read alike. An entry whose `ts` was unreadable
			-- still shows its message: losing that would be the worse failure.
			local stamp = value.timestamp(entry.ts) or NO_TIMESTAMP
			cells[#cells + 1] = { level = level, stamp = stamp, message = grid.sanitise(entry.message or "") }
			level_width = math.max(level_width, grid.display_width(level))
			stamp_width = math.max(stamp_width, grid.display_width(stamp))
		end
	end

	local lines, spans = {}, {}
	for _, cell in ipairs(cells) do
		local level_pad = string.rep(" ", level_width - grid.display_width(cell.level))
		local stamp_pad = string.rep(" ", stamp_width - grid.display_width(cell.stamp))
		lines[#lines + 1] = cell.level .. level_pad .. "  " .. cell.stamp .. stamp_pad .. "  " .. cell.message
		if #cell.level > 0 then
			spans[#spans + 1] = {
				line = #lines - 1,
				start_col = 0,
				end_col = #cell.level,
				hl_group = LEVEL_HL[cell.level] or "SpacetimeLogInfo",
			}
		end
	end
	local shown = #lines
	if shown == 0 then
		-- An empty buffer reads as a rendering failure; say so instead — and say
		-- which of the two emptinesses this is.
		lines[1] = #entries == 0 and NO_ENTRIES or NO_ENTRIES_AT_LEVEL:format(current.min_level)
	end

	-- The badge takes line one, so every span below it moves down by one. Done
	-- here, once, as in `ui/rows.lua`.
	local badge = badge_text(current, shown, #entries)
	table.insert(lines, 1, badge)
	for _, span in ipairs(spans) do
		span.line = span.line + 1
	end
	spans[#spans + 1] = { line = 0, start_col = 0, end_col = #badge, hl_group = "SpacetimeHeader" }

	return lines, spans
end

--------------------------------------------------------------------------------
-- Painting
--------------------------------------------------------------------------------

---Paint the current view into the content buffer.
---
---A no-op when there is nothing to show, when the content buffer does not exist,
---or when another view has claimed it since — a log response that lands after
---the user has opened a table's rows must not paint over the grid.
---
---While following, the cursor is pulled to the new last line **only if it was on
---the old one**: see point 7 of the module header.
function M.render()
	local current = view
	if current == nil then
		return
	end

	local buffer = require("spacetime.ui.buffer")
	if not buffer.owns_content(M.OWNER) then
		return
	end
	local bufnr = buffer.find(buffer.CONTENT_NAME)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- Asked before the write, because afterwards there is no way to tell "was on
	-- the last line" from "is on a line that used to be the last one". Only a
	-- follow moves the cursor at all; nothing else here repaints under the user.
	local winid = current.follow and buffer.window_showing(bufnr) or nil
	local at_bottom = false
	if winid then
		local ok_cursor, cursor = pcall(vim.api.nvim_win_get_cursor, winid)
		at_bottom = ok_cursor and cursor[1] >= vim.api.nvim_buf_line_count(bufnr)
	end
	-- Applying this view's key map is how the row grid's keys come off the shared
	-- buffer; see point 5 of the module header.
	require("spacetime.ui.keys").apply(bufnr, M.KEYMAPS)

	local lines, spans
	local ok, built_lines, built_spans = pcall(build, current)
	if ok then
		lines, spans = built_lines, built_spans
	else
		-- Strip the "file:line: " a raise carries: the message is for a user, not
		-- for whoever is reading this file.
		lines, spans = error_lines((tostring(built_lines):gsub("^.-:%d+: ", "")))
	end

	-- The one write. Everything above assembles; nothing below adds a line.
	buffer.set_lines(bufnr, lines)

	local namespace = buffer.namespace()
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(bufnr, namespace, span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	if at_bottom and winid then
		-- `pcall`: a window closed between the two halves of this function is not
		-- an error worth reporting, and the lines have already landed.
		pcall(vim.api.nvim_win_set_cursor, winid, { vim.api.nvim_buf_line_count(bufnr), 0 })
	end
end

--------------------------------------------------------------------------------
-- Fetching
--------------------------------------------------------------------------------

---Take the entries a request has accumulated and show them, oldest first out.
---
---Called once at completion for a static view and every `M.FLUSH_MS` for a
---follow, which is why the cap lives here rather than at either call site: a
---follow left running overnight must cost bounded memory, and dropping from the
---front is what makes the view a tail rather than a transcript.
---@param current SpacetimeLogsView
---@param entries spacetime.LogEntry[] Accumulated in fast-event context; main loop now.
local function append(current, entries)
	local kept = current.entries
	for _, entry in ipairs(entries) do
		kept[#kept + 1] = entry
	end

	local excess = #kept - M.MAX_ENTRIES
	if excess > 0 then
		local total = #kept
		for i = 1, total - excess do
			kept[i] = kept[i + excess]
		end
		for i = total - excess + 1, total do
			kept[i] = nil
		end
	end
end

---Empty `pending` and hand back what was in it.
---
---Cleared **in place**: the fast-event `on_entry` closed over this exact table,
---so replacing it with a fresh one would leave every later line being appended to
---a table nobody reads.
---@param pending spacetime.LogEntry[]
---@return spacetime.LogEntry[] taken
local function take(pending)
	local taken = {} ---@type spacetime.LogEntry[]
	for i = 1, #pending do
		taken[i] = pending[i]
		pending[i] = nil
	end
	return taken
end

---Stop the flush timer, if one is running, and close its libuv handle.
---
---Closed rather than merely stopped: an open handle keeps a headless Neovim
---alive, which is how this would show up as a hung test run rather than as a
---leak (`state.reset` closes its own timers for the same reason).
local function stop_flush()
	if flush_timer then
		flush_timer:stop()
		if not flush_timer:is_closing() then
			flush_timer:close()
		end
		flush_timer = nil
	end
end

---Start the one repeating timer that moves `pending` into the view.
---
---The uv callback runs in a |fast-event| context, so it does nothing but read a
---table length and `vim.schedule`; every `vim.api` call is on the main loop, in
---`M.render`. See point 6 of the module header for why this is a repeating timer
---and not `state.debounce`.
---@param current SpacetimeLogsView
---@param key string The `state` key this follow is registered under.
---@param seq integer The token `state.start` handed back.
---@param pending spacetime.LogEntry[] The table `on_entry` appends to.
local function start_flush(current, key, seq, pending)
	stop_flush()

	local timer = vim.uv.new_timer()
	flush_timer = timer
	timer:start(M.FLUSH_MS, M.FLUSH_MS, function()
		if #pending == 0 then
			-- A quiet stream costs nothing but this comparison: no schedule, no
			-- render, no write.
			return
		end
		vim.schedule(function()
			-- Three ways this turn can already be obsolete: the follow was torn
			-- down, it was superseded by another request under the same key, or
			-- another database's logs took the view over.
			if flush_timer ~= timer or not require("spacetime.state").is_current(key, seq) or current ~= view then
				return
			end
			local taken = take(pending)
			if #taken == 0 then
				return
			end
			-- The backlog arrives down this path too, so this is also what turns
			-- `loading…` into the first screenful.
			current.status = "ready"
			append(current, taken)
			M.render()
		end)
	end)
end

---Stop a follow: the timer first, then the process behind it.
---
---Idempotent, and safe on a view that was never following. `state.cancel` kills
---the handle *and* burns the key's token, so the `cb(nil, nil)` the cancelled
---stream reports is dropped by the `state.finish` check in `fetch` rather than
---being rendered — a clean stop is not an error.
---
---Deliberately paints nothing: `VimLeavePre` is one of its callers.
---@param current SpacetimeLogsView|nil
local function teardown(current)
	stop_flush()
	if current == nil or not current.following then
		return
	end
	current.following = false
	local state = require("spacetime.state")
	state.cancel(state.key("logs", current.database))
end

---The augroup the follow's teardown autocommands live in.
---
---One group, recreated with `clear = true` on every follow, so a session that
---follows twenty databases still has exactly two autocommands.
local AUGROUP = "SpacetimeLogsFollow"

---Arrange for the stream to die with the buffer, and with Neovim.
---
---A `curl` that outlives the editor is the failure this exists to prevent, which
---is why `VimLeavePre` is registered whether or not the content buffer is there
---to hang a `BufWipeout` off.
---@param bufnr integer|nil The content buffer, when one exists.
local function watch(bufnr)
	local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		desc = "spacetime: stop following logs before Neovim exits",
		callback = function()
			teardown(view)
		end,
	})

	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_create_autocmd("BufWipeout", {
			group = group,
			buffer = bufnr,
			desc = "spacetime: stop following logs when the content buffer goes",
			callback = function()
				teardown(view)
			end,
		})
	end
end

---Fetch the backlog — and, when following, keep reading — and repaint.
---
---The handle is registered with `state.start` *before* the request goes out: a
---stubbed transport completes inside the call, and a callback that ran before
---`start` returned would have no token to present. The flush timer starts before
---it too, for the same reason.
---@param current SpacetimeLogsView
local function fetch(current)
	local state = require("spacetime.state")
	local key = state.key("logs", current.database)
	local client = require("spacetime.lib.client").new(current.connection)

	-- Written to from the |fast-event| context of `on_entry`, so nothing here may
	-- be anything but a plain Lua table. See point 1 of the module header.
	local pending = {} ---@type spacetime.LogEntry[]

	local handle = nil ---@type SpacetimeHttpHandle|nil
	local seq = state.start(key, {
		kill = function()
			if handle then
				handle.kill()
			end
		end,
	})

	if current.follow then
		local buffer = require("spacetime.ui.buffer")
		current.following = true
		start_flush(current, key, seq, pending)
		watch(buffer.find(buffer.CONTENT_NAME))
	end

	handle = client:logs(current.database, current.num_lines, current.follow, function(entry)
		pending[#pending + 1] = entry
	end, function(err)
		-- A response that lost its token belongs to a database the user has moved
		-- away from; painting it now would undo what they did. It is also what
		-- makes `cb(nil, nil)` — a clean cancel, not an error — a no-op here: the
		-- only thing that cancels this request burns the token as it goes.
		if not state.finish(key, seq) then
			return
		end
		-- This request is still the current one, so the timer running is this
		-- follow's: the stream has ended, so the clock it was flushing on goes too.
		stop_flush()
		current.following = false
		if current ~= view then
			return
		end

		if err then
			current.status = "error"
			current.error = err.message
		else
			current.status = "ready"
			append(current, take(pending))
		end
		M.render()
	end)
end

---Show a database's logs in the content window.
---
---What `:SpacetimeLogs[!]` does. Never served from a cache — see point 4 of the
---module header — so every call puts one request on the wire and supersedes
---whatever was already in flight for that database, follow or not.
---@param request SpacetimeLogsRequest
function M.open(request)
	vim.validate("request", request, "table")
	vim.validate("connection", request.connection, "table")
	vim.validate("database", request.database, "string")
	vim.validate("num_lines", request.num_lines, "number", true)
	vim.validate("follow", request.follow, "boolean", true)

	if request.database == "" then
		-- A name we cannot fetch anything by is data, not a programming error.
		require("spacetime.logger").warn("there are no logs to show: no database was named")
		return
	end

	local state = require("spacetime.state")
	local key = state.key("logs", request.database)

	-- Whatever was being followed stops here, whichever database it was: there is
	-- one flush timer, and the follow that is starting is about to want it.
	teardown(view)

	-- A different database is a different key, so `state.start` below would leave
	-- the previous fetch running and its token live. Cancel it by hand.
	if view ~= nil then
		local previous = state.key("logs", view.database)
		if previous ~= key then
			state.cancel(previous)
		end
	end

	view = {
		connection = request.connection,
		database = request.database,
		num_lines = request.num_lines and math.floor(request.num_lines) or configured_lines(),
		follow = request.follow == true,
		following = false,
		status = "loading",
		entries = {},
		-- A fresh view starts unfiltered. Carrying the last view's minimum over
		-- would mean a `:SpacetimeLogs` that quietly hid most of another
		-- database's log, with only the badge to say why.
		min_level = M.DEFAULT_MIN_LEVEL,
	}

	require("spacetime.ui.buffer").claim_content(M.OWNER)

	M.render()
	fetch(view)
end

---Move the minimum displayed level, and repaint from what is already in memory.
---
---What `>` (one step more severe) and `<` (one step less severe) do. **No
---request goes out** — see point 10 of the module header — so the same entries
---are simply laid out again, and a follow keeps streaming into the same ring
---buffer throughout. New lines respect the new minimum because the filter lives
---in the render, not in the append.
---
---Clamped at both ends by `lib/logs.step_minimum`: `>` on `Error` and `<` on
---`Trace` stop rather than wrap, and stop silently — a keystroke that has
---nothing left to do is not an error, exactly as `]p` on the last page is not.
---@param steps integer Positive is more severe. `>` is `1`, `<` is `-1`.
function M.filter(steps)
	local current = view
	if current == nil or type(steps) ~= "number" or steps == 0 then
		return
	end

	local minimum = require("spacetime.lib.logs").step_minimum(current.min_level, steps)
	if minimum == current.min_level then
		return
	end
	current.min_level = minimum
	M.render()
end

---Stop following, silently: no paint, no message, and nothing said when there was
---nothing to stop.
---
---What `ui/sidebar.close()` calls. `M.stop()` is the *user's* stop and reports
---"no log follow is running" when there is none, which is exactly wrong for a `q`
---that was never about the logs. Idempotent, like the teardown behind it.
function M.teardown()
	teardown(view)
end

---Stop following, keeping what has already been shown.
---
---What `:SpacetimeLogsStop` does. The buffer is left exactly as it is — the point
---of stopping is usually to read what went past — and only the badge changes, to
---say that nothing more is coming.
---
---Says so and does nothing when no follow is running: a user who types this after
---the stream has already ended has done nothing wrong.
function M.stop()
	local current = view
	if current == nil or not current.following then
		require("spacetime.logger").info("no log follow is running")
		return
	end

	local database = current.database
	teardown(current)
	-- A follow stopped before its first line would otherwise sit on `loading…`
	-- forever, which reads as a hang rather than as a stop.
	if current.status == "loading" then
		current.status = "ready"
	end
	M.render()
	require("spacetime.logger").info(("stopped following %s's logs"):format(database))
end

return M
