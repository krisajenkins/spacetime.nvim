-- Big-integer-preserving JSON decode.
--
-- `vim.json.decode` corrupts large integers. Lua numbers are IEEE-754 doubles
-- with a 53-bit mantissa, so a U64 primary key above 2^53 comes back quietly
-- wrong and a real U128 `connection_id` comes back as `9223372036854775808`.
-- `vim.fn.json_decode` is byte-identical in this respect — there is no built-in
-- escape.
--
-- Rather than vendor a decoder, we keep Neovim's (it is the only one to hand
-- that decodes JSON `null` to `vim.NIL` rather than `nil`, which matters more
-- than the integers: SQL rows are positional arrays, so a dropped null shortens
-- the row and shifts every column after it) and run a text pre-pass first. The
-- pre-pass wraps long bare integer literals in quotes, so they arrive as exact
-- decimal strings and everything else decodes as usual. See ROADMAP.md, "Why a
-- small pre-pass of our own, and no vendored library".
--
-- The rule is deliberately blunt: an unbroken run of **16 or more decimal
-- digits** outside a string literal becomes a string, with a leading `-`
-- included inside the quotes. Sixteen is the shortest run that can exceed 2^53,
-- so the consequence is that some exactly-representable values are stringified
-- too — `1234567890123456` is 16 digits and below 2^53, and still comes back as
-- `"1234567890123456"`. Consumers of integer columns must therefore accept
-- either a number or a decimal string.
--
-- This module lives under `lib/` and is pure logic: `vim.json.decode` is the
-- only `vim.*` call it may make.
local M = {}

-- The shortest digit run that can exceed 2^53. Matched with a single C-level
-- pattern search, which is what keeps the pass linear: we look for a candidate
-- first and only then walk string literals far enough to decide whether that
-- candidate sits inside one. A payload with no long run (the schema response,
-- for instance) is returned untouched.
local RUN = string.rep("%d", 16)

local QUOTE = 34 -- string.byte('"')
local ZERO, NINE = 48, 57

---Index just past the string literal whose opening quote is at `q`.
---@param text string
---@param q integer Index of the opening quote.
---@param n integer `#text`.
---@return integer # One past the closing quote, or `n + 1` if unterminated.
local function skip_string(text, q, n)
	local i = q + 1
	while true do
		local j = text:find('[\\"]', i)
		if not j then
			-- Unterminated (e.g. a trailing backslash). Say "to the end" and let
			-- vim.json.decode report the syntax error.
			return n + 1
		end
		if text:byte(j) == QUOTE then
			return j + 1
		end
		i = j + 2 -- step over the escaped character, so \" is not read as the close
	end
end

---Quote every bare integer literal of 16 or more digits that lies outside a
---string literal, keeping a leading `-` inside the quotes. Floats and exponents
---are left alone, as are digits inside strings.
---
---Internal: exported only so the tests can assert on the rewritten JSON, which
---gives far better failure output than asserting on decoded tables.
---@param text string
---@return string # `text` itself when there is nothing to rewrite.
function M.quote_big_integers(text)
	local n = #text
	local out, last = nil, 1
	local scan = 1 -- where to look for the next candidate run
	local safe = 1 -- text:sub(safe) is known to start outside any string literal

	while true do
		local c = text:find(RUN, scan)
		if not c then
			break
		end

		-- Walk string literals forward from `safe` until one spans `c` (the
		-- candidate is string data) or the next one starts after it.
		local inside = false
		local p = safe
		while p <= c do
			local q = text:find('"', p, true)
			if not q or q > c then
				safe = c
				break
			end
			local after = skip_string(text, q, n)
			safe = after
			if after > c then
				inside = true
				break
			end
			p = after
		end

		if inside then
			scan = safe
		else
			-- Expand the candidate to the whole digit run.
			local s = c
			while s > 1 do
				local b = text:byte(s - 1)
				if not b or b < ZERO or b > NINE then
					break
				end
				s = s - 1
			end
			local e = c
			while e < n do
				local b = text:byte(e + 1)
				if not b or b < ZERO or b > NINE then
					break
				end
				e = e + 1
			end

			-- `sub` yields "" off either end, which never matches a guard char.
			local prev = text:sub(s - 1, s - 1)
			local nxt = text:sub(e + 1, e + 1)
			-- A neighbouring '.', 'e' or 'E' means these digits are the fraction,
			-- the exponent, or the integer part of a float — all of which stay
			-- numbers.
			local ok = prev ~= "." and prev ~= "e" and prev ~= "E" and nxt ~= "." and nxt ~= "e" and nxt ~= "E"
			local start = s
			if ok and prev == "-" then
				local prev2 = text:sub(s - 2, s - 2)
				if prev2 == "e" or prev2 == "E" then
					ok = false -- a negative exponent, not a negative integer
				else
					start = s - 1 -- -"123" is not valid JSON; the minus goes inside
				end
			end

			if ok then
				out = out or {}
				out[#out + 1] = text:sub(last, start - 1)
				out[#out + 1] = '"' .. text:sub(start, e) .. '"'
				last = e + 1
			end

			scan = e + 1
			if safe < scan then
				safe = scan
			end
		end
	end

	if not out then
		return text
	end
	out[#out + 1] = text:sub(last)
	return table.concat(out)
end

---Decode JSON, preserving integers too large for a Lua number as exact decimal
---strings. Otherwise identical to `vim.json.decode` with its default options:
---JSON `null` decodes to `vim.NIL`, so positional row arrays keep their length.
---
---Malformed input raises, exactly as `vim.json.decode` does; callers that want
---to recover should `pcall`.
---@param text string
---@return any
function M.decode(text)
	return vim.json.decode(M.quote_big_integers(text))
end

---A decoded value as an integer, accepting either spelling `M.decode` may have
---produced: a Lua number, or the exact decimal string a run of 16 or more
---digits comes back as.
---
---Anything else — absent, `vim.NIL`, a non-numeric string, a float dressed as
---text — is `nil`, which the caller reports in its own terms rather than
---guessing at.
---
---It lives here, rather than in either of the two modules that need it, because
---the choice is this module's doing: the pre-pass above is the reason an integer
---field can arrive as a string at all, so the coercion that undoes it belongs
---beside the rule that creates it.
---@param value any
---@return integer|nil
function M.to_integer(value)
	if type(value) == "number" then
		return math.floor(value)
	end
	if type(value) == "string" and value:match("^%-?%d+$") then
		local n = tonumber(value)
		return n and math.floor(n) or nil
	end
	return nil
end

return M
