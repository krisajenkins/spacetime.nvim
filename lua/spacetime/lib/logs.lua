-- One NDJSON log line -> one entry, plus the level ordering the log filter
-- needs.
--
-- `GET /v1/database/{db}/logs` answers with newline-delimited JSON, one
-- upstream `Record` per line: `ts` (micros since the epoch), `message`, and the
-- optional `target`, `filename`, `line_number` and `function`. The level is an
-- internally-tagged plain string, never a tagged object, and absent fields are
-- omitted rather than sent as null — so a missing key and a present-but-null
-- key both have to mean "not there".
--
-- Two things the wire format forces on us:
--
--   * `ts` arrives as a **decimal string**, not a number. The real values are
--     16 digits, which is exactly `lib/json.lua`'s stringify threshold, so
--     every one comes back quoted. RFC3339 timestamps and a bare JSON number
--     are accepted too; all three normalise to micros.
--   * `function` is a Lua keyword, so that field is spelled `["function"]`
--     everywhere — constructor, index and annotation alike.
--
-- Parsing is **total**: `parse_line` never raises and never partially fails. A
-- blank, malformed or half-written line is `nil` (follow streams deliver
-- partial lines, and one of those must not kill the session), while a line that
-- is structurally a log record but carries a junk `ts` or an unheard-of level
-- still comes back as an entry — losing a message because its timestamp was
-- unreadable would be the worse failure.
--
-- This module lives under `lib/` and is pure logic: `spacetime.lib.json` is the
-- whole of its outside world.

local M = {}

---@class spacetime.LogEntry
---@field level string Canonical level, or the server's raw name if unrecognised.
---@field ts integer|nil Micros since the Unix epoch.
---@field target string|nil
---@field filename string|nil
---@field line_number integer|nil
---@field ["function"] string|nil
---@field message string

---Canonical level names, most severe first.
M.LEVELS = { "Panic", "Error", "Warn", "Info", "Debug", "Trace" }

-- Upstream's own severity numbers (`Trace` 0 … `Panic` 5), so an ordering
-- agreed here matches one computed server-side.
local RANK = { Trace = 0, Debug = 1, Info = 2, Warn = 3, Error = 4, Panic = 5 }

-- Lower-cased name -> canonical spelling, so "info", "INFO" and "Info" agree.
local CANONICAL = {}
for _, name in ipairs(M.LEVELS) do
	CANONICAL[name:lower()] = name
end

---Severity of a level name.
---@param level string|nil
---@return integer # Upstream severity: `Trace` 0 … `Panic` 5. Unrecognised sorts as `Info`.
function M.rank(level)
	if type(level) ~= "string" then
		return RANK.Info
	end
	local canonical = CANONICAL[level:lower()]
	return canonical and RANK[canonical] or RANK.Info
end

---Whether `level` is at least as severe as `min`.
---@param level string|nil
---@param min string
---@return boolean
function M.at_least(level, min)
	return M.rank(level) >= M.rank(min)
end

---Days from 1970-01-01 to a proleptic Gregorian date (Hinnant's
---`days_from_civil`).
---
---`os.time` would read its table as *local* time, which would make both the
---parse and its tests machine-dependent; this is a pure function of the date.
---@param y integer
---@param m integer 1-12.
---@param d integer 1-31.
---@return integer # Negative before 1970.
local function days_from_civil(y, m, d)
	y = y - (m <= 2 and 1 or 0)
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

---Parse an RFC3339 timestamp into micros since the epoch.
---
---The fraction is truncated to microsecond precision (and right-padded when
---shorter). A missing zone is read as UTC. Anything left over after the
---optional fraction and zone means this is not an RFC3339 string at all.
---@param s string
---@return integer|nil
local function from_rfc3339(s)
	local year, month, day, hour, minute, second, rest =
		s:match("^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
	if not year then
		return nil
	end

	local micros = 0
	local digits, after_fraction = rest:match("^%.(%d+)(.*)$")
	if digits then
		micros = tonumber((digits .. "000000"):sub(1, 6)) or 0
		rest = after_fraction
	end

	local offset = 0
	if rest ~= "" and rest ~= "Z" and rest ~= "z" then
		local sign, offset_hour, offset_minute = rest:match("^([+-])(%d%d):?(%d%d)$")
		if not sign then
			return nil
		end
		offset = ((tonumber(offset_hour) or 0) * 3600 + (tonumber(offset_minute) or 0) * 60)
		if sign == "-" then
			offset = -offset
		end
	end

	local days = days_from_civil(tonumber(year) or 0, tonumber(month) or 0, tonumber(day) or 0)
	local seconds = days * 86400 + (tonumber(hour) or 0) * 3600 + (tonumber(minute) or 0) * 60 + (tonumber(second) or 0)
	return (seconds - offset) * 1000000 + micros
end

---A decoded value as an integer, accepting the decimal string `lib/json.lua`
---hands back for a long run of digits.
---@param value any
---@return integer|nil
local function to_integer(value)
	if type(value) == "number" then
		return math.floor(value)
	end
	if type(value) == "string" and value:match("^%-?%d+$") then
		local n = tonumber(value)
		return n and math.floor(n) or nil
	end
	return nil
end

---A decoded `ts` as micros since the epoch: a number, a decimal string, or an
---RFC3339 string. Anything else — absent, `vim.NIL`, junk — is `nil`, which the
---caller keeps rather than treating as a parse failure.
---@param value any
---@return integer|nil
local function to_micros(value)
	local integer = to_integer(value)
	if integer then
		return integer
	end
	if type(value) == "string" then
		return from_rfc3339(value)
	end
	return nil
end

---A decoded value only if the server really sent a string. A missing key is
---`nil` and a JSON `null` is `vim.NIL`; neither is a string, so one test covers
---both without naming the sentinel.
---@param value any
---@return string|nil
local function to_optional_string(value)
	return type(value) == "string" and value or nil
end

---Canonical spelling of a level name.
---
---An unrecognised name is preserved verbatim so the log line still shows what
---the server said; `rank` sorts it as `Info`.
---@param level any
---@return string
local function canonical_level(level)
	if type(level) ~= "string" then
		return "Info"
	end
	return CANONICAL[level:lower()] or level
end

---Parse one NDJSON line into a log entry.
---
---Total by contract: no input raises. `nil` means "not a log line" — blank,
---malformed, or (the follow case) a line that has not finished arriving, since
---`json.decode` raises on truncated input.
---@param s string One NDJSON line.
---@return spacetime.LogEntry|nil # `nil` for a blank, malformed or partial line.
function M.parse_line(s)
	if type(s) ~= "string" then
		return nil
	end
	-- Trimming first also absorbs the stray `\r` of CRLF framing.
	local trimmed = s:match("^%s*(.-)%s*$")
	if trimmed == "" then
		return nil
	end

	local json = require("spacetime.lib.json")
	local ok, decoded = pcall(json.decode, trimmed)
	if not ok or type(decoded) ~= "table" then
		return nil
	end

	---@type table<string, any>
	local raw = decoded
	-- One discriminator for the lot: a string `message` is the only thing every
	-- record has, so this rejects `5`, `"text"`, `[1,2]`, `{}` and a null
	-- message together.
	if type(raw.message) ~= "string" then
		return nil
	end

	return {
		level = canonical_level(raw.level),
		ts = to_micros(raw.ts),
		target = to_optional_string(raw.target),
		filename = to_optional_string(raw.filename),
		line_number = to_integer(raw.line_number),
		["function"] = to_optional_string(raw["function"]),
		message = raw.message,
	}
end

---Parse a whole NDJSON body, dropping the lines that do not parse.
---@param text string A whole NDJSON body, `\n` or `\r\n` separated.
---@return spacetime.LogEntry[] # In arrival order; unparseable lines are silently dropped.
function M.parse_lines(text)
	local entries = {}
	if type(text) ~= "string" then
		return entries
	end
	for line in text:gmatch("[^\n]+") do
		local entry = M.parse_line(line)
		if entry then
			entries[#entries + 1] = entry
		end
	end
	return entries
end

return M
