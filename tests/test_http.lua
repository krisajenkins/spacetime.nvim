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

return T
