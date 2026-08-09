-- A deliberately partial reader for one known file — `~/.config/spacetime/cli.toml`,
-- written by the SpacetimeDB CLI. **This is not a TOML implementation** and must
-- never be reused as one: it understands `key = value`, `[[server_configs]]`
-- blocks and `#` comments, and silently drops everything else TOML can express.
--
-- The one fact worth carrying away: the file holds **two** tokens, and only
-- `spacetimedb_token` authenticates against the HTTP API. `web_session_token` is
-- the web console's session and produces a 401 that reads like a login failure —
-- a wrong guess here is misdiagnosed as "your credentials expired". So this
-- module does not merely prefer the right key, it *only ever* recognises the
-- keys named in `SpacetimeCliConfig` below; `web_session_token` never reaches the
-- returned table at all, and so cannot be leaked by a caller that dumps its
-- config.
--
-- Everything the file says is returned verbatim as a string. Splitting `host`
-- into host/port, mapping `protocol` to TLS, and resolving `default_server` to a
-- server block all belong to `config.lua` — see ROADMAP.md, task 8.
--
-- Deliberate limitations, all of which are "skip the line", never an error:
--
-- * No type coercion. A bare value stays a **string**, so `port = 3000` yields
--   `"3000"` — no numbers, no booleans, no datetimes. Every key this module
--   recognises is a string in the real file, and a single value type keeps the
--   annotations honest.
-- * Basic strings unescape only `\\`, `\"`, `\n`, `\r` and `\t`. Any other
--   escape — `\uXXXX` included — is left verbatim, backslash and all.
-- * Multi-line strings (`"""`, `'''`), inline tables, arrays and dotted keys are
--   not understood, so lines using them are dropped.
-- * An unterminated quoted string drops its line rather than swallowing the rest
--   of the file.
--
-- This module lives under `lib/` and is pure logic: `io.open` in `read` is its
-- only I/O and it makes no `vim.*` calls at all.

---@class SpacetimeCliServerConfig
---@field nickname? string The name `default_server` and `--server` refer to.
---@field host? string May include a port, e.g. `"127.0.0.1:3000"`; splitting is `config.lua`'s job.
---@field protocol? string `"http"` or `"https"` as written in the file; not validated here.

---@class SpacetimeCliConfig
---@field default_server? string Nickname of the server the CLI defaults to.
---@field spacetimedb_token? string The HTTP API bearer token. Never `web_session_token`.
---@field server_configs SpacetimeCliServerConfig[] Always present; empty when the file has no blocks.

local M = {}

-- The escapes a TOML basic string may use that we can honour. Anything absent
-- (notably `\uXXXX`) is passed through with its backslash intact.
local ESCAPES = { ["\\"] = "\\", ['"'] = '"', n = "\n", r = "\r", t = "\t" }

---@param s string
---@return string
local function trim(s)
	return s:match("^%s*(.-)%s*$")
end

---Parse a TOML basic string whose opening quote is at index 1 of `text`.
---@param text string
---@return string|nil # `nil` if the string is unterminated.
local function basic_string(text)
	local out, i, n = {}, 2, #text
	while i <= n do
		local c = text:sub(i, i)
		if c == '"' then
			return table.concat(out)
		elseif c == "\\" then
			local escape = text:sub(i + 1, i + 1)
			out[#out + 1] = ESCAPES[escape] or ("\\" .. escape)
			i = i + 2
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return nil
end

---Parse the value half of a `key = value` line. `text` is already trimmed.
---@param text string
---@return string|nil # `nil` when the value is malformed or empty.
local function parse_value(text)
	local first = text:sub(1, 1)
	if first == '"' then
		return basic_string(text)
	elseif first == "'" then
		-- Literal string: no escapes at all, so it ends at the next quote.
		return text:match("^'([^']*)'")
	end

	-- A bare value runs to a trailing comment, if any, and keeps its type as a
	-- string. Empty (`key =`, or `key = # note`) counts as malformed.
	local value = trim(text:match("^[^#]*"))
	if value == "" then
		return nil
	end
	return value
end

---Parse the contents of a `cli.toml`. Never raises: unknown keys, unknown table
---headers and malformed lines are all skipped, so the result is always usable.
---@param text string
---@return SpacetimeCliConfig # `server_configs` is always a table, possibly empty.
function M.parse(text)
	---@type SpacetimeCliConfig
	local config = { server_configs = {} }

	-- Where `key = value` lines currently land: the top level until the first
	-- header, then either the newest server block or nowhere at all. Keys under
	-- an unrecognised header must leak neither upwards nor into the previous
	-- block, hence the explicit "other" state.
	local section = "top" ---@type "top"|"server"|"other"
	local block = nil ---@type SpacetimeCliServerConfig|nil

	-- The trailing newline makes the last line match like any other; a trailing
	-- `\r` is stripped so a CRLF file parses the same as an LF one.
	for raw in (text .. "\n"):gmatch("(.-)\n") do
		local line = trim((raw:gsub("\r$", "")))

		if line == "" or line:sub(1, 1) == "#" then -- luacheck: ignore 542
			-- Blank line or whole-line comment.
		elseif line:sub(1, 1) == "[" then
			if line:match("^%[%[%s*server_configs%s*%]%]$") then
				block = {}
				config.server_configs[#config.server_configs + 1] = block
				section = "server"
			else
				section = "other"
			end
		else
			local key, rest = line:match("^([^=]*)=(.*)$")
			if key then
				local value = parse_value(trim(rest))
				key = trim(key)
				if value ~= nil then
					if section == "top" then
						if key == "default_server" then
							config.default_server = value
						elseif key == "spacetimedb_token" then
							config.spacetimedb_token = value
						end
					elseif section == "server" and block then
						if key == "nickname" then
							block.nickname = value
						elseif key == "host" then
							block.host = value
						elseif key == "protocol" then
							block.protocol = value
						end
					end
				end
			end
		end
	end

	return config
end

---Read and parse a `cli.toml`. A missing, unreadable or malformed file is not an
---error — it yields an empty config, so callers get one shape to handle and
---decide for themselves whether "no token" is worth reporting.
---@param path string
---@return SpacetimeCliConfig
function M.read(path)
	local file = io.open(path, "r")
	if not file then
		return { server_configs = {} }
	end
	local text = file:read("*a")
	file:close()
	if not text then
		return { server_configs = {} }
	end
	return M.parse(text)
end

return M
