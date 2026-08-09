-- Tests for the pure half of the transport.
--
-- No child Neovim and no process: `build` and `parse_head` are argv/stdin in,
-- data out. The argv assertions are exact-equality on purpose — the element
-- order is part of the contract, and a stray `--location` or a leaked token
-- should fail here rather than in a live request.
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

return T
