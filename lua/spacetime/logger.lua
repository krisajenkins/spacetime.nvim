-- Level-filtered vim.notify wrapper.
--
-- Every log call funnels through one private `log()` so that redaction cannot
-- be forgotten: the bearer token is the one genuinely sensitive value this
-- plugin handles, and a DEBUG-level vim.inspect of a request table is the
-- obvious way to leak it. Redaction therefore runs on the *formatted* string,
-- after vim.inspect, not on the arguments.
local M = {}

local log_level = vim.log.levels.INFO

-- Build a case-insensitive Lua pattern from a literal word: "bearer" becomes
-- "[bB][eE][aA][rR][eE][rR]". Lua patterns have no (?i) flag.
local function ci(word)
	return (word:gsub("%a", function(c)
		return "[" .. c:lower() .. c:upper() .. "]"
	end))
end

-- A base64url character, and a segment with a length floor so ordinary dotted
-- text ("spacetime.lib.http", "1.2.3") is never mistaken for a JWT segment.
local B64URL = "[%w_%-]"
local SEGMENT = B64URL:rep(10) .. B64URL .. "*" -- at least 10 base64url chars

-- Ordered { pattern, replacement } rules, applied in sequence. Bearer comes
-- first so a bearer JWT is masked once, as a header value.
local REDACTIONS = {
	-- Authorization: Bearer <token> (header name and keyword in any case).
	-- The token charset excludes quotes and commas so a vim.inspect'ed
	-- `Authorization = "Bearer ..."` keeps its closing quote.
	{ "(" .. ci("bearer") .. "%s+)[^%s\"',]+", "%1<redacted>" },
	-- A bare JWT: three base64url segments separated by dots.
	{ SEGMENT .. "%." .. SEGMENT .. "%." .. SEGMENT, "<redacted>" },
	-- cli.toml token keys, in TOML form and in vim.inspect form: `k = "v"` and
	-- `["k"] = "v"` both match via the ["%]%s]* run.
	{ '(spacetimedb_token["%]%s]*=%s*)"[^"]*"', '%1"<redacted>"' },
	{ '(web_session_token["%]%s]*=%s*)"[^"]*"', '%1"<redacted>"' },
}

---Mask secrets in a string: bearer tokens, bare JWTs and the cli.toml token keys.
---@param s string
---@return string redacted The string with every recognised secret replaced by `<redacted>`
function M.redact(s)
	for _, rule in ipairs(REDACTIONS) do
		s = s:gsub(rule[1], rule[2])
	end
	return s
end

-- Join every argument with a space. Counted with select('#', ...) rather than
-- ipairs, which stops at the first nil and would silently drop later values.
local function format_args(...)
	local n = select("#", ...)
	local parts = {}
	for i = 1, n do
		local v = select(i, ...)
		parts[i] = type(v) == "string" and v or vim.inspect(v)
	end
	return table.concat(parts, " ")
end

-- The single funnel: filter by level, format, redact, notify.
local function log(level, ...)
	if log_level > level then
		return
	end
	vim.notify(M.redact("[spacetime] " .. format_args(...)), level)
end

---@param ... any Values to log; non-strings are vim.inspect'ed
function M.debug(...)
	log(vim.log.levels.DEBUG, ...)
end

---@param ... any Values to log; non-strings are vim.inspect'ed
function M.info(...)
	log(vim.log.levels.INFO, ...)
end

---@param ... any Values to log; non-strings are vim.inspect'ed
function M.warn(...)
	log(vim.log.levels.WARN, ...)
end

---@param ... any Values to log; non-strings are vim.inspect'ed
function M.error(...)
	log(vim.log.levels.ERROR, ...)
end

---@return number level The current log level (a `vim.log.levels` value)
function M.get_level()
	return log_level
end

---@param level number A `vim.log.levels` value
function M.set_level(level)
	log_level = level
end

return M
