-- Tests for the transport.
--
-- No child Neovim and no process: `build` and `parse_head` are argv/stdin in,
-- data out, and `request` runs over the `http._system` seam with a fake in
-- place of `vim.system`. The argv assertions are exact-equality on purpose —
-- the element order is part of the contract, and a stray `--location` or a
-- leaked token should fail here rather than in a live request.
local http = require("spacetime.lib.http")
local expect = MiniTest.expect

local T = MiniTest.new_set()

local URL = "http://127.0.0.1:3000/v1/database/quickstart/sql"
local TOKEN = "eyJhbGciOiJFUzI1NiJ9.not-a-real-token.sig"

T["a buffered GET builds the exact argv"] = function()
	local cmd = http.build({ url = URL })
	expect.equality(cmd.argv, {
		"curl",
		"-sS",
		"-i",
		"--http1.1",
		"--max-time",
		"30",
		"-X",
		"GET",
		"-K",
		"-",
		URL,
	})
end

T["a streaming request drops --max-time and adds --no-buffer"] = function()
	local cmd = http.build({ url = URL, stream = true, timeout = 5 })
	expect.equality(cmd.argv, {
		"curl",
		"-sS",
		"-i",
		"--http1.1",
		"--no-buffer",
		"-X",
		"GET",
		"-K",
		"-",
		URL,
	})
	-- The timeout is not merely unused, it must not appear at all.
	expect.equality(table.concat(cmd.argv, " "):find("5", 1, true), nil)
end

T["redirects are never enabled"] = function()
	for _, req in ipairs({ { url = URL }, { url = URL, stream = true } }) do
		for _, arg in ipairs(http.build(req).argv) do
			expect.no_equality(arg, "-L")
			expect.no_equality(arg, "--location")
		end
	end
end

T["the token travels on stdin and never in argv"] = function()
	local cmd = http.build({ url = URL, token = TOKEN })
	expect.equality(table.concat(cmd.argv, " "):find(TOKEN, 1, true), nil)
	expect.equality(cmd.stdin, 'header = "Authorization: Bearer ' .. TOKEN .. '"\n')
end

T["a POST body lands in stdin, not in argv"] = function()
	local cmd = http.build({ url = URL, method = "post", body = "SELECT * FROM person" })
	expect.equality(cmd.argv[8], "POST")
	expect.equality(table.concat(cmd.argv, " "):find("SELECT", 1, true), nil)
	expect.equality(cmd.stdin, 'data-binary = "SELECT * FROM person"\n')
end

T["config-block values escape quotes, backslashes and newlines"] = function()
	local cmd = http.build({ url = URL, method = "POST", body = 'a"b\\c\nd\re\tf' })
	expect.equality(cmd.stdin, 'data-binary = "a\\"b\\\\c\\nd\\re\\tf"\n')
	-- A literal newline in the block would end the config line early.
	expect.equality(cmd.stdin:sub(1, -2):find("\n", 1, true), nil)
end

T["with no token and no body the config block is empty"] = function()
	local cmd = http.build({ url = URL })
	expect.equality(cmd.stdin, "")
	-- `-K -` is still emitted, so argv has exactly one shape.
	expect.equality(cmd.argv[9], "-K")
	expect.equality(cmd.argv[10], "-")
end

T["extra headers emit in sorted order"] = function()
	local cmd = http.build({
		url = URL,
		token = TOKEN,
		headers = { ["X-Trace"] = "abc", ["Content-Type"] = "text/plain" },
	})
	expect.equality(
		cmd.stdin,
		table.concat({
			'header = "Authorization: Bearer ' .. TOKEN .. '"',
			'header = "Content-Type: text/plain"',
			'header = "X-Trace: abc"',
			"",
		}, "\n")
	)
end

T["an Authorization header is rejected in favour of token"] = function()
	expect.error(function()
		http.build({ url = URL, headers = { authorization = "Bearer sneaky" } })
	end, "request%.token")
	expect.error(function()
		http.build({ url = URL, headers = { ["AUTHORIZATION"] = "Bearer sneaky" } })
	end, "request%.token")
end

T["a non-table request raises"] = function()
	expect.error(function()
		http.build("http://example.invalid")
	end, "must be a table")
end

T["a missing url raises"] = function()
	expect.error(function()
		http.build({ method = "GET" })
	end, "url")
	expect.error(function()
		http.build({ url = "" })
	end, "url")
end

T["both status-line forms parse"] = function()
	local head = http.parse_head("HTTP/1.1 503 Service Unavailable\r\n\r\ndatabase is paused")
	expect.equality(head.status, 503)
	expect.equality(head.rest, "database is paused")

	head = http.parse_head("HTTP/2 200 \r\n\r\n{}")
	expect.equality(head.status, 200)
	expect.equality(head.rest, "{}")
end

T["a 100 Continue preamble is skipped"] = function()
	local head = http.parse_head("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\n\r\nok")
	expect.equality(head.status, 200)
	expect.equality(head.rest, "ok")
end

T["a 103 Early Hints preamble is skipped, headers and all"] = function()
	local head = http.parse_head(
		"HTTP/2 103 \r\nlink: </style.css>; rel=preload\r\n\r\n"
			.. "HTTP/2 200 \r\ncontent-type: application/json\r\n\r\n{}"
	)
	expect.equality(head.status, 200)
	expect.equality(head.headers, { ["content-type"] = "application/json" })
	expect.equality(head.rest, "{}")
end

T["header names normalise to lower case and values are trimmed"] = function()
	local head = http.parse_head("HTTP/1.1 200 OK\r\nContent-Type:   text/plain  \r\n\r\n")
	expect.equality(head.headers["content-type"], "text/plain")
	expect.equality(head.headers["Content-Type"], nil)
end

T["a folded continuation joins onto the previous value"] = function()
	local head = http.parse_head("HTTP/1.1 200 OK\r\nx-note: first\r\n\tsecond\r\n Third\r\n\r\n")
	expect.equality(head.headers["x-note"], "first second Third")
end

T["a repeated header joins with a comma"] = function()
	local head = http.parse_head("HTTP/1.1 200 OK\r\nvia: 1.1 a\r\nVia: 1.1 b\r\n\r\n")
	expect.equality(head.headers["via"], "1.1 a, 1.1 b")
end

T["bare LF framing parses"] = function()
	local head = http.parse_head("HTTP/1.1 200 OK\ncontent-type: text/plain\n\nbody")
	expect.equality(head.status, 200)
	expect.equality(head.headers["content-type"], "text/plain")
	expect.equality(head.rest, "body")
end

T["only the first terminator splits, so the body survives intact"] = function()
	local head = http.parse_head("HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n\r\nline1\r\n\r\nline2\r\n")
	expect.equality(head.rest, "line1\r\n\r\nline2\r\n")
end

T["a garbage status line raises with the raw text"] = function()
	expect.error(function()
		http.parse_head("<html><head><title>Corporate Proxy</title>\r\n\r\n")
	end, vim.pesc('unparseable status line: "<html><head><title>Corporate Proxy</title>"'))
end

T["an incomplete head returns nil rather than raising"] = function()
	-- No terminating blank line yet: the caller retries as bytes arrive.
	expect.equality(http.parse_head("HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n"), nil)
	expect.equality(http.parse_head("HTTP/1.1 20"), nil)
	expect.equality(http.parse_head(""), nil)
end

---Run `body` with `http._system` replaced, restoring it even on failure.
---@param fake function
---@param run function
local function with_system(fake, run)
	local saved = http._system
	http._system = fake
	local ok, err = pcall(run)
	http._system = saved
	if not ok then
		error(err, 0)
	end
end

---Pump the event loop until `pred` holds — this is what runs the scheduled
---callbacks, since `vim.schedule_wrap` defers them past the current turn.
---@param pred function
local function wait_for(pred)
	expect.equality(vim.wait(1000, pred, 5), true)
end

---A `vim.system` stand-in that reports `out` immediately.
---@param out table
---@return function
local function completes_with(out)
	return function(_, _, on_exit)
		on_exit(out)
		return { kill = function() end }
	end
end

T["a 200 yields status, headers and body"] = function()
	local got
	with_system(
		completes_with({
			code = 0,
			stdout = 'HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\r\n{"ok":true}',
			stderr = "",
		}),
		function()
			http.request({ url = URL }, function(err, response)
				got = { err = err, response = response }
			end)
			wait_for(function()
				return got ~= nil
			end)
		end
	)
	expect.equality(got.err, nil)
	expect.equality(got.response.status, 200)
	expect.equality(got.response.headers["content-type"], "application/json")
	expect.equality(got.response.body, '{"ok":true}')
end

T["the config block goes to stdin and stdout is captured raw"] = function()
	local seen
	with_system(function(cmd, opts, on_exit)
		seen = { cmd = cmd, opts = opts }
		on_exit({ code = 0, stdout = "HTTP/1.1 200 OK\r\n\r\n", stderr = "" })
		return { kill = function() end }
	end, function()
		local done = false
		http.request({ url = URL, token = TOKEN }, function()
			done = true
		end)
		wait_for(function()
			return done
		end)
	end)
	local built = http.build({ url = URL, token = TOKEN })
	expect.equality(seen.cmd, built.argv)
	expect.equality(seen.opts.stdin, built.stdin)
	expect.equality(type(seen.opts.stdin), "string")
	-- `text = true` would rewrite CRLF and corrupt the framing; `timeout` would
	-- shadow curl's own `--max-time` with an unclassifiable exit 124.
	expect.equality(seen.opts.text, nil)
	expect.equality(seen.opts.timeout, nil)
	expect.equality(table.concat(seen.cmd, " "):find(TOKEN, 1, true), nil)
end

T["a stream request is forced back onto the buffered path"] = function()
	local seen
	local req = { url = URL, stream = true }
	with_system(function(cmd, _, on_exit)
		seen = cmd
		on_exit({ code = 0, stdout = "HTTP/1.1 200 OK\r\n\r\n", stderr = "" })
		return { kill = function() end }
	end, function()
		local done = false
		http.request(req, function()
			done = true
		end)
		wait_for(function()
			return done
		end)
	end)
	expect.equality(seen, http.build({ url = URL }).argv)
	-- The caller's own table is left alone.
	expect.equality(req.stream, true)
end

T["each mapped curl exit code yields its message"] = function()
	local cases = {
		{ 6, "could not resolve host" },
		{ 7, "connection refused" },
		{ 28, "timed out" },
		{ 35, "TLS failure" },
		{ 60, "TLS failure" },
	}
	for _, case in ipairs(cases) do
		local code, message = case[1], case[2]
		local got
		with_system(
			completes_with({ code = code, stdout = "", stderr = ("curl: (%d) something went wrong"):format(code) }),
			function()
				http.request({ url = URL }, function(err, response)
					got = { err = err, response = response }
				end)
				wait_for(function()
					return got ~= nil
				end)
			end
		)
		-- Exactly the message: a mapped code does not get curl's stderr bolted on.
		expect.equality(got.err, message)
		expect.equality(got.response, nil)
	end
end

T["an unmapped exit code includes the number and curl's stderr"] = function()
	local stderr = "curl: (47) Maximum (50) redirects followed"
	local got
	with_system(completes_with({ code = 47, stdout = "", stderr = stderr }), function()
		http.request({ url = URL }, function(err, response)
			got = { err = err, response = response }
		end)
		wait_for(function()
			return got ~= nil
		end)
	end)
	expect.no_equality(got.err:find("47", 1, true), nil)
	expect.no_equality(got.err:find(stderr, 1, true), nil)
	expect.equality(got.response, nil)
end

T["a truncated head is an error, not a crash"] = function()
	local got
	with_system(
		completes_with({ code = 0, stdout = "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n", stderr = "" }),
		function()
			http.request({ url = URL }, function(err, response)
				got = { err = err, response = response }
			end)
			wait_for(function()
				return got ~= nil
			end)
		end
	)
	expect.no_equality(got.err, nil)
	expect.equality(got.response, nil)
end

T["a garbage status line surfaces as an error"] = function()
	local got
	with_system(
		completes_with({ code = 0, stdout = "<html><head><title>Corporate Proxy</title>\r\n\r\n", stderr = "" }),
		function()
			http.request({ url = URL }, function(err, response)
				got = { err = err, response = response }
			end)
			wait_for(function()
				return got ~= nil
			end)
		end
	)
	expect.no_equality(got.err:find("unparseable status line", 1, true), nil)
	expect.equality(got.response, nil)
end

T["kill() propagates to the process and is idempotent"] = function()
	local killed, signal = 0, nil
	with_system(function()
		return {
			kill = function(_, sig)
				killed = killed + 1
				signal = sig
			end,
		}
	end, function()
		local handle = http.request({ url = URL }, function() end)
		handle:kill()
		expect.equality(killed, 1)
		expect.equality(signal, "sigterm")
		handle:kill()
		expect.equality(killed, 1)
	end)
end

T["a killed request never invokes the callback"] = function()
	local called = false
	local exit
	with_system(function(_, _, on_exit)
		-- Hold the completion callback rather than firing it, so the kill lands
		-- first and the exit arrives afterwards.
		exit = on_exit
		return { kill = function() end }
	end, function()
		local handle = http.request({ url = URL }, function()
			called = true
		end)
		handle:kill()
		exit({ code = 0, stdout = "HTTP/1.1 200 OK\r\n\r\nok", stderr = "" })
		vim.wait(50)
		expect.equality(called, false)
	end)
end

T["callbacks arrive scheduled, not in a fast-event context"] = function()
	local called, fast = false, nil
	with_system(completes_with({ code = 0, stdout = "HTTP/1.1 200 OK\r\n\r\nok", stderr = "" }), function()
		http.request({ url = URL }, function()
			called = true
			fast = vim.in_fast_event()
		end)
		-- The stub called `on_exit` synchronously, yet nothing has run yet.
		expect.equality(called, false)
		wait_for(function()
			return called
		end)
	end)
	expect.equality(fast, false)
end

T["request validates its arguments"] = function()
	expect.error(function()
		http.request({ url = URL }, nil)
	end, "on_done")
	expect.error(function()
		http.request("nope", function() end)
	end, "must be a table")
end

-- A stand-in for the `nil` chunk that means EOF: `nil` itself cannot sit in a
-- list literal without truncating it.
local EOF = {}

---Collect what a splitter emits for a sequence of chunks.
---@param chunks table[] Strings, plus `EOF` wherever the stream should flush.
---@return string[]
local function split(chunks)
	local lines = {}
	local feed = http.new_line_splitter(function(line)
		lines[#lines + 1] = line
	end)
	for _, chunk in ipairs(chunks) do
		feed(chunk ~= EOF and chunk or nil)
	end
	return lines
end

T["the splitter joins a line spread across chunks"] = function()
	expect.equality(split({ "hel", "lo\nwor", "ld\n" }), { "hello", "world" })
end

T["the splitter is chunk-invariant across a CRLF"] = function()
	-- The boundary falls between the `\r` and the `\n`: the `\r` waits in the
	-- buffer and is stripped from the assembled line, not from the chunk.
	expect.equality(split({ "a\r", "\nb\r\n" }), { "a", "b" })
end

T["the splitter emits a trailing partial line at EOF"] = function()
	expect.equality(split({ "a\nb", EOF }), { "a", "b" })
	expect.equality(split({ "a\nb\r", EOF }), { "a", "b" })
end

T["EOF is idempotent and adds no empty final line"] = function()
	-- A body ending in `\n` must not emit a spurious `""`, or the "all chunkings
	-- identical" invariant would depend on whether the last line was terminated.
	expect.equality(split({ "a\n", EOF, EOF }), { "a" })
	expect.equality(split({ "a\nb", EOF, EOF }), { "a", "b" })
	expect.equality(split({ EOF }), {})
end

T["an interior empty line is emitted"] = function()
	expect.equality(split({ "a\n\nb\n" }), { "a", "", "b" })
	expect.equality(split({ "" }), {})
end

T["the splitter validates its argument"] = function()
	expect.error(function()
		http.new_line_splitter(nil)
	end, "on_line")
end

---A `vim.system` stand-in that pushes `chunks` at the stdout callback, closes
---stdout, then exits. Synchronous, like the real callback, which runs in a
---fast-event context rather than on the main loop.
---@param chunks string[]
---@param out? table Defaults to a clean exit.
---@return function
local function streams(chunks, out)
	return function(_, opts, on_exit)
		for _, chunk in ipairs(chunks) do
			opts.stdout(nil, chunk)
		end
		opts.stdout(nil, nil)
		on_exit(out or { code = 0, stderr = "" })
		return { kill = function() end }
	end
end

---Run a stream over canned chunks and report the lines and the completion.
---@param chunks string[]
---@param out? table
---@return string[] lines
---@return table completion `{ err = ..., response = ... }`
local function stream_over(chunks, out)
	local lines, got = {}, nil
	with_system(streams(chunks, out), function()
		http.stream({ url = URL }, function(line)
			lines[#lines + 1] = line
		end, function(err, response)
			got = { err = err, response = response }
		end)
		wait_for(function()
			return got ~= nil
		end)
	end)
	return lines, got
end

local STREAM_HEAD = "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\r\n"
local STREAM_BODY = '{"a":1}\n{"b":2}\n{"c":3}\n'
local STREAM_LINES = { '{"a":1}', '{"b":2}', '{"c":3}' }

T["all three chunkings of one response yield identical lines"] = function()
	local response = STREAM_HEAD .. STREAM_BODY

	local per_byte = {}
	for i = 1, #response do
		per_byte[i] = response:sub(i, i)
	end

	-- The boundary lands *inside* the head terminator, after `...\r\n\r`. This
	-- is the case that breaks an implementation which hunts for `\r\n\r\n`
	-- within a single chunk.
	local at = response:find("\r\n\r\n", 1, true)
	local split_terminator = { response:sub(1, at + 2), response:sub(at + 3) }
	expect.equality(split_terminator[1]:sub(-3), "\r\n\r")
	expect.equality(split_terminator[2]:sub(1, 1), "\n")

	local a = stream_over(per_byte)
	local b = stream_over({ response })
	local c = stream_over(split_terminator)

	expect.equality(a, STREAM_LINES)
	expect.equality(b, a)
	expect.equality(c, a)
end

T["a 2xx stream reports its head with an empty body"] = function()
	local lines, got = stream_over({ STREAM_HEAD .. STREAM_BODY })
	expect.equality(lines, STREAM_LINES)
	expect.equality(got.err, nil)
	expect.equality(got.response.status, 200)
	expect.equality(got.response.headers["content-type"], "application/json")
	-- The body left as lines; nothing is buffered up for the finish callback.
	expect.equality(got.response.body, "")
end

T["a final line with no trailing newline still arrives, before on_done"] = function()
	local order = {}
	with_system(streams({ STREAM_HEAD .. '{"a":1}\n{"b":2}' }), function()
		local done = false
		http.stream({ url = URL }, function(line)
			order[#order + 1] = line
		end, function()
			order[#order + 1] = "done"
			done = true
		end)
		wait_for(function()
			return done
		end)
	end)
	expect.equality(order, { '{"a":1}', '{"b":2}', "done" })
end

T["a 503 body is surfaced rather than streamed as lines"] = function()
	local lines, got = stream_over({ "HTTP/1.1 503 Service Unavailable\r\n\r\ndatabase is paused" })
	expect.equality(lines, {})
	-- No error: mapping status to a message is `lib/client.lua`'s job.
	expect.equality(got.err, nil)
	expect.equality(got.response.status, 503)
	expect.equality(got.response.body, "database is paused")
end

T["a non-2xx body split across chunks is reassembled"] = function()
	local lines, got = stream_over({ "HTTP/1.1 503 Service Unavailable\r\n\r\ndatabase ", "is paused" })
	expect.equality(lines, {})
	expect.equality(got.response.body, "database is paused")
end

T["a stream maps a non-zero exit code the same way a request does"] = function()
	local _, got = stream_over({}, { code = 7, stderr = "curl: (7) Failed to connect" })
	expect.equality(got.err, "connection refused")
	expect.equality(got.response, nil)
end

T["a garbage status line ends the stream with an error"] = function()
	local lines, got = stream_over({ "<html><head><title>Corporate Proxy</title>\r\n\r\n" })
	expect.equality(lines, {})
	expect.no_equality(got.err:find("unparseable status line", 1, true), nil)
	expect.equality(got.response, nil)
end

T["a stream that ends before its head completes is an error"] = function()
	local _, got = stream_over({ "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n" })
	expect.no_equality(got.err:find("before the head was complete", 1, true), nil)
	expect.equality(got.response, nil)
end

T["a stream spawns the streaming argv with the token on stdin"] = function()
	local seen
	local req = { url = URL, token = TOKEN }
	with_system(function(cmd, opts, on_exit)
		seen = { cmd = cmd, opts = opts }
		opts.stdout(nil, "HTTP/1.1 200 OK\r\n\r\n")
		opts.stdout(nil, nil)
		on_exit({ code = 0, stderr = "" })
		return { kill = function() end }
	end, function()
		local done = false
		http.stream(req, function() end, function()
			done = true
		end)
		wait_for(function()
			return done
		end)
	end)
	local built = http.build({ url = URL, token = TOKEN, stream = true })
	expect.equality(seen.cmd, built.argv)
	expect.equality(seen.opts.stdin, built.stdin)
	expect.equality(table.concat(seen.cmd, " "):find(TOKEN, 1, true), nil)
	-- `--no-buffer` yes, `--max-time` no: a follow is meant to last.
	expect.equality(vim.tbl_contains(seen.cmd, "--no-buffer"), true)
	expect.equality(vim.tbl_contains(seen.cmd, "--max-time"), false)
	-- `text = true` would rewrite CRLF and corrupt the framing; `timeout` would
	-- kill a healthy follow.
	expect.equality(seen.opts.text, nil)
	expect.equality(seen.opts.timeout, nil)
	-- The caller's table is left alone.
	expect.equality(req.stream, nil)
end

T["a line is delivered unscheduled while on_done is not"] = function()
	-- The one deliberate exception to the scheduling rule: lines come straight
	-- out of the stdout callback, which is why `on_line` may only touch plain
	-- tables. `on_done` keeps the usual main-loop guarantee.
	local sync, done = false, false
	with_system(streams({ STREAM_HEAD .. "one\n" }), function()
		http.stream({ url = URL }, function()
			sync = true
		end, function()
			done = true
		end)
		-- The stub ran the whole stream before returning.
		expect.equality(sync, true)
		expect.equality(done, false)
		wait_for(function()
			return done
		end)
	end)
end

T["kill() stops the lines and still finishes exactly once"] = function()
	local lines, calls, got = {}, 0, nil
	local emit, exit
	with_system(function(_, opts, on_exit)
		-- Hold both callbacks, so the kill can land between two chunks.
		emit, exit = opts.stdout, on_exit
		return { kill = function() end }
	end, function()
		local handle = http.stream({ url = URL }, function(line)
			lines[#lines + 1] = line
		end, function(err, response)
			calls = calls + 1
			got = { err = err, response = response }
		end)
		emit(nil, STREAM_HEAD .. "first\n")
		handle:kill()
		emit(nil, "second\n")
		-- curl dies of the SIGTERM afterwards; that must not become a second
		-- callback, nor an error.
		exit({ code = 143, stderr = "" })
		wait_for(function()
			return got ~= nil
		end)
		vim.wait(50)
	end)
	expect.equality(lines, { "first" })
	expect.equality(calls, 1)
	expect.equality(got.err, nil)
	expect.equality(got.response, nil)
end

T["kill() is idempotent and propagates to the process"] = function()
	local killed, signal = 0, nil
	with_system(function()
		return {
			kill = function(_, sig)
				killed = killed + 1
				signal = sig
			end,
		}
	end, function()
		local handle = http.stream({ url = URL }, function() end, function() end)
		handle:kill()
		expect.equality(killed, 1)
		expect.equality(signal, "sigterm")
		handle:kill()
		expect.equality(killed, 1)
	end)
end

T["stream validates its arguments"] = function()
	expect.error(function()
		http.stream("nope", function() end, function() end)
	end, "must be a table")
	expect.error(function()
		http.stream({ url = URL }, nil, function() end)
	end, "on_line")
	expect.error(function()
		http.stream({ url = URL }, function() end, nil)
	end, "on_done")
end

return T
