-- The log view: what `:SpacetimeLogs [db]` paints into the content window.
--
-- `lib/client:logs` puts `GET /v1/database/{db}/logs?num_lines=N&follow=false`
-- on the wire and `lib/logs.parse_line` turns each NDJSON line into an entry;
-- this module is the part that owns the buffer. It lives under `ui/` and may
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
--    applies this view's key map through `ui/keys`, which takes the grid's `s`,
--    `]p`, `y`, `Y` and `K` back off the buffer.
--
-- The lines are laid out here rather than through `ui/grid.lua`: the grid has a
-- header row this view does not want, and it truncates a cell to 40 columns,
-- which is exactly the wrong thing to do to a log message. Two narrow columns
-- (level, timestamp) padded to their widest entry is the whole of the layout.
--
-- **Follow is roadmap task 32**, and it plugs in at two named places: the
-- `false` handed to `client:logs` below, and `M.append`, which task 32 replaces
-- with a coalesced 100 ms flush off a `vim.uv` timer plus a ring buffer capped at
-- 5000 entries. `:SpacetimeLogs!` currently says that it is not implemented and
-- shows the static backlog instead; see `commands.lua`.

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

---Every key the content window binds while it is showing logs.
---
---Deliberately none until roadmap task 33 adds `<` and `>` for the level
---filter. The table is still here, and still applied on every render, because
---applying it is what *unbinds* the row grid's keys — see point 5 of the module
---header.
---@type SpacetimeKeymap[]
M.KEYMAPS = {}

local LOADING = "loading…"
local NO_ENTRIES = "(no log entries)"
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

---The request plus what has become of it.
---@class SpacetimeLogsView : SpacetimeLogsRequest
---@field num_lines integer Resolved: never `nil` once the view exists.
---@field status "loading"|"ready"|"error"
---@field error? string Set when `status == "error"`.
---@field entries spacetime.LogEntry[] In arrival order, oldest first.

---What is on screen, or being fetched onto it. `nil` before the first open.
---@type SpacetimeLogsView|nil
local view = nil

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
---@param current SpacetimeLogsView
---@param count integer Entries rendered.
---@return string
local function badge_text(current, count)
	return ("%s · %d line%s · asked for %d"):format(
		current.database,
		count,
		count == 1 and "" or "s",
		current.num_lines
	)
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
	local entries = current.entries

	-- Two passes: the columns are padded to their widest entry, and nothing is
	-- truncated, so the widths cannot be known before every entry has been seen.
	local cells = {} ---@type { level: string, stamp: string, message: string }[]
	local level_width, stamp_width = 0, 0
	for i, entry in ipairs(entries) do
		local level = grid.sanitise(entry.level or "")
		-- `lib/value.timestamp` is the renderer a Timestamp *column* goes through,
		-- so a log stamp and a cell read alike. An entry whose `ts` was unreadable
		-- still shows its message: losing that would be the worse failure.
		local stamp = value.timestamp(entry.ts) or NO_TIMESTAMP
		cells[i] = { level = level, stamp = stamp, message = grid.sanitise(entry.message or "") }
		level_width = math.max(level_width, grid.display_width(level))
		stamp_width = math.max(stamp_width, grid.display_width(stamp))
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
	if #lines == 0 then
		-- An empty buffer reads as a rendering failure; say so instead.
		lines[1] = NO_ENTRIES
	end

	-- The badge takes line one, so every span below it moves down by one. Done
	-- here, once, as in `ui/rows.lua`.
	local badge = badge_text(current, #entries)
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
	-- Applying an (as yet empty) key map is how the row grid's keys come off the
	-- shared buffer; see point 5 of the module header.
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
end

--------------------------------------------------------------------------------
-- Fetching
--------------------------------------------------------------------------------

---Take the entries a completed request accumulated and show them.
---
---Split out from `fetch` because it is the seam roadmap task 32 needs: follow
---calls this repeatedly off a coalesced timer instead of once at completion, and
---caps what it keeps at a ring buffer of 5000.
---@param current SpacetimeLogsView
---@param entries spacetime.LogEntry[] Accumulated in fast-event context; main loop now.
local function append(current, entries)
	for _, entry in ipairs(entries) do
		current.entries[#current.entries + 1] = entry
	end
end

---Fetch the backlog and repaint when it lands.
---
---The handle is registered with `state.start` *before* the request goes out: a
---stubbed transport completes inside the call, and a callback that ran before
---`start` returned would have no token to present.
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

	handle = client:logs(current.database, current.num_lines, false, function(entry)
		pending[#pending + 1] = entry
	end, function(err)
		-- A response that lost its token belongs to a database the user has moved
		-- away from; painting it now would undo what they did. It is also what
		-- makes `cb(nil, nil)` — a clean cancel, not an error — a no-op here: the
		-- only thing that cancels this request burns the token as it goes.
		if not state.finish(key, seq) then
			return
		end
		if current ~= view then
			return
		end

		if err then
			current.status = "error"
			current.error = err.message
		else
			current.status = "ready"
			append(current, pending)
		end
		M.render()
	end)
end

---Show a database's logs in the content window.
---
---What `:SpacetimeLogs` does. Never served from a cache — see point 4 of the
---module header — so every call puts one request on the wire and supersedes
---whatever was already in flight for that database.
---@param request SpacetimeLogsRequest
function M.open(request)
	vim.validate("request", request, "table")
	vim.validate("connection", request.connection, "table")
	vim.validate("database", request.database, "string")
	vim.validate("num_lines", request.num_lines, "number", true)

	if request.database == "" then
		-- A name we cannot fetch anything by is data, not a programming error.
		require("spacetime.logger").warn("there are no logs to show: no database was named")
		return
	end

	local state = require("spacetime.state")
	local key = state.key("logs", request.database)

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
		status = "loading",
		entries = {},
	}

	require("spacetime.ui.buffer").claim_content(M.OWNER)

	M.render()
	fetch(view)
end

return M
