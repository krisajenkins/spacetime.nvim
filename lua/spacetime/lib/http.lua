-- The transport: turn a request table into a curl invocation, run it, and turn
-- the head of a `curl -i` response back into data.
--
-- `build` and `parse_head` are pure — no process is spawned, nothing is
-- scheduled, and no `vim.api`/`vim.fn`/`vim.notify` call is made. `request`
-- sits on top of the pair and owns all of the I/O; `stream()` (ROADMAP.md,
-- task 14) will join it there.
--
-- Why the invocation looks the way it does:
--
-- * **The bearer token never appears in argv.** argv is visible in `ps` to every
--   local user on the machine, so the credential travels on stdin as a `-K -`
--   config block (ROADMAP.md, risk 4). Once stdin is spoken for, *every* header
--   may as well go there too — one rule instead of two — and the body follows,
--   which incidentally sidesteps `ARG_MAX` for a large SQL statement. Note that
--   `-K -` owns stdin, so `--data-binary @-` is not available: the body has to
--   be inlined into the config block, quoted.
-- * `-i` puts headers and body on one stream, which gives buffered and streaming
--   requests a single code path and keeps the 503 "database paused" case
--   detectable while following logs.
-- * `-K -` is emitted **unconditionally**, even when the config block is empty,
--   so argv has exactly one shape per variant. The consequence for task 13: the
--   caller must always write stdin and close it, or curl waits forever.
-- * No `--location`/`-L`: redirects stay disabled, because a redirect is how a
--   captive portal or a corporate MITM turns an API call into an HTML page.
-- * No `--fail`: SpacetimeDB returns SQL errors as HTTP 400 with the message in
--   a plain-text body, and `--fail` would throw that body away.
-- * No `--retry`: a reducer call is not idempotent, so a transparent retry could
--   run it twice.
-- * `--max-time` bounds a buffered request; the streaming variant drops it (a
--   log follow is meant to last) and adds `--no-buffer` so lines arrive as they
--   are produced rather than in 4 KiB blocks.
--
-- A gotcha for callers (ROADMAP.md, task 15): `--data-binary` makes curl default
-- the request's `Content-Type` to `application/x-www-form-urlencoded`. Anything
-- posting to `/v1/database/{name}/sql` must therefore pass
-- `headers = { ["Content-Type"] = "text/plain" }` explicitly.
--
-- `parse_head` is written for a byte stream that may still be arriving: an
-- incomplete head is `nil` (call again with more bytes), never an error. The one
-- loud failure is a status line that is present but unrecognisable — a proxy
-- emitting an unexpected framing must produce a clear error rather than a
-- plausible-looking mis-parse (ROADMAP.md, risk 5).

local M = {}

-- Seconds for `--max-time` on a buffered request when the caller names none.
local DEFAULT_TIMEOUT = 30

-- The method used when the caller names none.
local DEFAULT_METHOD = "GET"

-- Escapes for a value inside a curl config file. A config value may not contain
-- a literal newline, so the whitespace characters become their two-character
-- forms; `\` and `"` have to be escaped for the quoting itself.
local CONFIG_ESCAPES = {
	["\\"] = "\\\\",
	['"'] = '\\"',
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
	["\v"] = "\\v",
}

---@param ok any Truthy when the check passed.
---@param msg string What went wrong, without the module prefix.
local function want(ok, msg)
	if not ok then
		-- Level 3: `want` is called from `M.build`, so the error points at
		-- whoever built the bad request table.
		error("spacetime.lib.http: " .. msg, 3)
	end
end

---Quote a value for the right-hand side of a curl config line.
---@param value string
---@return string # Including the surrounding double quotes.
local function quote(value)
	-- The parens matter: `gsub` returns two values, and the count would be
	-- concatenated onto the result.
	return '"' .. (value:gsub('[\\"\n\r\t\v]', CONFIG_ESCAPES)) .. '"'
end

---@param s string
---@return string
local function trim(s)
	return s:match("^%s*(.-)%s*$")
end

---@class SpacetimeHttpRequest
---@field url string Absolute URL, already percent-encoded by the caller.
---@field method? string Default `"GET"`. Upper-cased before it reaches argv.
---@field token? string Bearer token. Travels on stdin only — never argv.
---@field body? string Request body, sent as `data-binary` in the config block.
---@field headers? table<string,string> Extra request headers. `Authorization` is rejected; use `token`.
---@field timeout? number Seconds for `--max-time`. Default 30. Ignored when `stream`.
---@field stream? boolean Streaming variant: `--no-buffer`, no `--max-time`.

---@class SpacetimeHttpCommand
---@field argv string[] Argument vector for `vim.system`. Contains no secret.
---@field stdin string The `-K -` config block. `""` when there is nothing to send.

---Build the curl invocation for a request.
---
---Pure: the result is data, and the caller decides what to do with it. The
---argument vector has a fixed element order so tests can assert exact equality.
---@param req SpacetimeHttpRequest
---@return SpacetimeHttpCommand
function M.build(req)
	want(type(req) == "table", "request must be a table")
	want(type(req.url) == "string" and req.url ~= "", "request.url must be a non-empty string")
	want(req.method == nil or type(req.method) == "string", "request.method must be a string")
	want(req.token == nil or type(req.token) == "string", "request.token must be a string")
	want(req.body == nil or type(req.body) == "string", "request.body must be a string")
	want(req.headers == nil or type(req.headers) == "table", "request.headers must be a table")
	want(
		req.timeout == nil or (type(req.timeout) == "number" and req.timeout > 0),
		"request.timeout must be a positive number"
	)
	want(req.stream == nil or type(req.stream) == "boolean", "request.stream must be a boolean")

	local method = (req.method or DEFAULT_METHOD):upper()

	local argv ---@type string[]
	if req.stream then
		argv = { "curl", "-sS", "-i", "--http1.1", "--no-buffer", "-X", method, "-K", "-", req.url }
	else
		local timeout = ("%g"):format(req.timeout or DEFAULT_TIMEOUT)
		argv = { "curl", "-sS", "-i", "--http1.1", "--max-time", timeout, "-X", method, "-K", "-", req.url }
	end

	local lines = {} ---@type string[]

	-- The credential first, so a truncated dump of the block is still obviously
	-- a secret and gets redacted rather than half-shown.
	if req.token then
		lines[#lines + 1] = "header = " .. quote("Authorization: Bearer " .. req.token)
	end

	if req.headers then
		local names = {} ---@type string[]
		for name, value in pairs(req.headers) do
			want(type(name) == "string", "request.headers keys must be strings")
			want(type(value) == "string", ("request.headers[%q] must be a string"):format(name))
			-- `token` is the single path for the credential: two ways to set the
			-- same header is how one of them ends up in a log.
			want(name:lower() ~= "authorization", "set request.token, not an Authorization header")
			names[#names + 1] = name
		end
		-- Sorted, so the block is deterministic for tests and for a diff.
		table.sort(names)
		for _, name in ipairs(names) do
			lines[#lines + 1] = "header = " .. quote(name .. ": " .. req.headers[name])
		end
	end

	if req.body then
		lines[#lines + 1] = "data-binary = " .. quote(req.body)
	end

	local stdin = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
	return { argv = argv, stdin = stdin }
end

---Read one `\n`-terminated line starting at `pos`.
---
---A trailing `\r` is stripped, so a bare-LF response — which is what a hand-run
---`nc` or a lenient proxy produces — parses the same as a CRLF one.
---@param text string
---@param pos integer
---@return string|nil line `nil` when no complete line is available yet.
---@return integer next Index just past the line's terminator.
local function read_line(text, pos)
	local stop = text:find("\n", pos, true)
	if not stop then
		return nil, pos
	end
	return (text:sub(pos, stop - 1):gsub("\r$", "")), stop + 1
end

---@class SpacetimeHttpHead
---@field status integer The status code of the first non-1xx block.
---@field headers table<string,string> Names lower-cased; values trimmed.
---@field rest string Bytes after the head terminator, byte-exact.

---Parse the head of a `curl -i` response.
---
---Returns `nil` when the head is not yet complete — no terminating blank line
---has been seen — so a streaming caller can simply retry as more bytes arrive.
---Raises only when a complete status line is present and unparseable.
---
---Any `1xx` block (`100 Continue`, `103 Early Hints`) is discarded whole,
---headers included, and parsing restarts at the block that follows. A proxy's
---`200 Connection established` block is deliberately *not* skipped: it is
---indistinguishable from a real 200, and guessing is exactly what the loud
---failure above exists to avoid.
---@param text string
---@return SpacetimeHttpHead|nil
function M.parse_head(text)
	if type(text) ~= "string" then
		error("spacetime.lib.http: parse_head expects a string", 2)
	end

	local pos = 1
	while true do
		local line, next_pos = read_line(text, pos)
		if not line then
			return nil
		end
		pos = next_pos

		-- Accepts `HTTP/1.1 503 Service Unavailable` and `HTTP/2 200 ` alike:
		-- HTTP/2 has no reason phrase, and curl prints the trailing space.
		local code = line:match("^HTTP/%d[%d%.]*%s+(%d%d%d)")
		if not code then
			error(("spacetime.lib.http: unparseable status line: %q"):format(line:sub(1, 200)), 2)
		end

		local headers = {} ---@type table<string,string>
		local previous = nil ---@type string|nil
		local terminated = false

		while not terminated do
			local header_line
			header_line, next_pos = read_line(text, pos)
			if not header_line then
				return nil
			end
			pos = next_pos

			if header_line == "" then
				terminated = true
			elseif header_line:match("^[ \t]") then
				-- Obsolete line folding: a continuation of the previous header,
				-- joined with a single space. No previous header means the
				-- fold is meaningless, so it is dropped.
				if previous then
					headers[previous] = headers[previous] .. " " .. trim(header_line)
				end
			else
				local name, value = header_line:match("^([^:]+):%s*(.-)%s*$")
				if name then
					name = trim(name):lower()
					-- Repeats join with `", "`, which is wrong for `Set-Cookie`
					-- and right for everything else. Safe here because this
					-- client never sends a cookie, so no server sends one back.
					headers[name] = headers[name] and (headers[name] .. ", " .. value) or value
					previous = name
				end
				-- A line with neither a colon nor leading whitespace is junk in
				-- the middle of a head; skip it. Only the status line is fatal.
			end
		end

		local status = tonumber(code) --[[@as integer]]
		if status >= 200 then
			-- Only the *first* terminator splits, so a body that itself
			-- contains a blank line survives byte-exact.
			return { status = status, headers = headers, rest = text:sub(pos) }
		end
		-- A 1xx block: throw it away, headers and all, and parse the next one.
	end
end

---@class SpacetimeSystemCompleted The shape `vim.system` reports on exit.
---@field code integer Process exit status, or the signal number when killed.
---@field signal? integer
---@field stdout? string
---@field stderr? string

---Injection point for `vim.system`. Tests replace this so exit-code mapping and
---cancellation can be exercised with no process spawned. Spelled out here
---rather than reused from Neovim's own annotations, which lua_ls only sees when
---the runtime files are on the workspace library path.
---@type fun(cmd: string[], opts: table, on_exit: fun(out: SpacetimeSystemCompleted)): table
M._system = vim.system

-- The curl exit codes worth translating into something a user can act on.
-- Everything else is reported by number, with curl's own stderr quoted, because
-- inventing a friendly phrase for an unknown failure hides more than it helps.
local EXIT_MESSAGES = {
	[6] = "could not resolve host",
	[7] = "connection refused",
	[28] = "timed out",
	[35] = "TLS failure",
	[60] = "TLS failure",
}

---Turn a non-zero curl exit into a message.
---@param code integer
---@param stderr string|nil
---@return string
local function classify_exit(code, stderr)
	local mapped = EXIT_MESSAGES[code]
	if mapped then
		return mapped
	end
	local detail = trim(stderr or "")
	if detail == "" then
		return ("curl exited with code %d"):format(code)
	end
	return ("curl exited with code %d: %s"):format(code, detail)
end

---@class SpacetimeHttpResponse
---@field status integer
---@field headers table<string,string> Names lower-cased.
---@field body string Byte-exact response body.

---@class SpacetimeHttpHandle
---@field kill fun(...) Cancel the request. Idempotent; safe after completion.

---Execute a buffered request.
---
---Exactly one of `err` and `response` is non-nil. `on_done` is
---`vim.schedule_wrap`ped, so every layer above this one may assume main-loop
---context and none of them has to think about fast-event restrictions again.
---
---Cancellation contract: `kill()` is idempotent, and once it has been called
---`on_done` is never invoked — a cancelled request is silent. That covers a
---handle's own late callback only; ordering *between* handles is still the job
---of the sequence guard in `state.lua` (ROADMAP.md, task 20).
---@param req SpacetimeHttpRequest `stream` is ignored here; use `M.stream`.
---@param on_done fun(err: string|nil, response: SpacetimeHttpResponse|nil)
---@return SpacetimeHttpHandle
function M.request(req, on_done)
	if type(req) ~= "table" then
		error("spacetime.lib.http: request must be a table", 2)
	end
	if type(on_done) ~= "function" then
		error("spacetime.lib.http: request needs an on_done callback", 2)
	end

	-- A shallow copy, so a caller that reuses its request table for a later
	-- `stream` call gets it back unmodified. Dropping `stream` here means a
	-- caller passing `stream = true` still gets the buffered argv rather than an
	-- unbounded `--no-buffer` one that would never complete.
	local spec = {}
	for key, value in pairs(req) do
		spec[key] = value
	end
	spec.stream = nil

	local cmd = M.build(spec --[[@as SpacetimeHttpRequest]])

	local cancelled = false
	local proc ---@type table|nil

	-- The cancel check lives *inside* the scheduled function on purpose: testing
	-- it at `on_exit` time would leave a race where a `kill()` landing between
	-- the exit and the scheduled turn still delivered a callback.
	local deliver = vim.schedule_wrap(function(err, response)
		if cancelled then
			return
		end
		on_done(err, response)
	end)

	-- `cmd.stdin` is always a string — `""` when the config block is empty — and
	-- must never be `nil`. `vim.system` opens a pipe for any truthy value, and
	-- `""` is truthy in Lua, so it writes nothing and then closes the pipe, which
	-- is what stops curl blocking forever on `-K -`. Passing `nil` would skip the
	-- pipe and curl would inherit (and read) Neovim's own stdin.
	--
	-- No `text = true`: it rewrites `\r\n` as `\n` in the captured stdout, which
	-- would corrupt both the head framing and the body bytes. No `opts.timeout`
	-- either: curl's `--max-time` already bounds the request and yields the
	-- classifiable exit 28, where `vim.system`'s timeout yields 124 and would
	-- need a second, redundant mapping.
	proc = M._system(cmd.argv, { stdin = cmd.stdin }, function(out)
		if out.code ~= 0 then
			deliver(classify_exit(out.code, out.stderr), nil)
			return
		end
		local ok, head = pcall(M.parse_head, out.stdout or "")
		if not ok then
			-- Strip the "file:line: " that `error(msg, 2)` prepends inside
			-- `parse_head`; the parens keep `gsub`'s count out of the arguments.
			deliver((tostring(head):gsub("^.-:%d+: ", "")), nil)
		elseif not head then
			-- curl exited cleanly but never produced a complete head: a truncated
			-- or non-HTTP response, not something the caller can parse.
			deliver("incomplete response from server", nil)
		else
			deliver(nil, { status = head.status, headers = head.headers, body = head.rest })
		end
	end)

	return {
		-- Written to ignore its argument, so `handle:kill()` and `handle.kill()`
		-- both work.
		kill = function()
			if cancelled then
				return
			end
			cancelled = true
			if proc then
				-- The process may already have exited, in which case libuv's
				-- handle is closed and `kill` raises. A cancel must not.
				pcall(function()
					proc:kill("sigterm")
				end)
			end
		end,
	}
end

return M
