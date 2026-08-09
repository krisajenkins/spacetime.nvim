-- The SQL response envelope, and the `SELECT` builder that produces the queries
-- behind it.
--
-- `POST /v1/database/{db}/sql` answers with an **array** of statement results,
-- one per statement in the body. In practice it also answers with a bare object
-- when there is a single statement, with `[]` when there is nothing to say, and
-- — for a mutation — with a result that has `rows` and `stats` but **no
-- `schema`** at all. `parse` flattens all four shapes into one table so nothing
-- above this module has to know which arrived.
--
-- Rows are *positional* arrays (ROADMAP.md, verified fact 8): column `i` of a
-- row lines up with `schema.elements[i]`, sums arrive as `[variant_index,
-- payload]`, and a JSON `null` is `vim.NIL` rather than absent. So the column
-- list is built with `ipairs` and never `pairs`, and rows are handed back
-- verbatim — no copying, filtering or renumbering, because dropping a `vim.NIL`
-- would shorten the row and shift every column after it.
--
-- Failures come back as `nil, message` rather than raising: a bad response is
-- rendered in the results buffer, and a stack trace is not a result.
--
-- This module lives under `lib/` and is pure logic. It touches no `vim.api`,
-- `vim.fn`, `vim.ui` or `vim.notify`; `vim.NIL` (a sentinel value, not a call)
-- and `spacetime.lib.json` are the whole of its outside world.

local M = {}

---@class SpacetimeSqlColumn
---@field name string Column name; `"column_<n>"` (1-based) when the server sends `{"none":[]}`.
---@field algebraic_type? any Raw AlgebraicType JSON, kept verbatim for `lib/value.lua`.

---@class SpacetimeSqlResult
---@field columns SpacetimeSqlColumn[] In `schema.elements` order; empty for mutation responses.
---@field rows any[][] Positional row arrays exactly as decoded; empty when there are none.
---@field duration_micros number From `total_duration_micros`; `0` when absent.

---Whether `value` is a table the server actually sent, rather than a missing
---key or a JSON `null` decoded to `vim.NIL`.
---@param value any
---@return boolean
local function present(value)
	return type(value) == "table" and value ~= vim.NIL
end

---The columns described by one statement result's `schema`.
---
---A mutation response has no `schema` key at all, which is not an error — it
---simply has no columns.
---@param schema any The raw `schema` object, or `nil`/`vim.NIL` when absent.
---@return SpacetimeSqlColumn[]
local function columns_of(schema)
	local columns = {}
	if not present(schema) then
		return columns
	end

	local elements = schema.elements
	if not present(elements) then
		return columns
	end

	-- `ipairs`, never `pairs`: rows are positional, so this order *is* the
	-- column order and a rehash would scramble the table.
	for i, element in ipairs(elements) do
		---@type any
		local raw = present(element) and element.name or nil

		-- Names arrive as an Option: `{"some": "code"}` or `{"none": []}`. An
		-- unnamed column still needs a heading, so it gets its position. Older
		-- servers have been seen sending a bare string, which is taken as-is.
		local name
		if present(raw) and type(raw.some) == "string" then
			name = raw.some
		elseif type(raw) == "string" then
			name = raw
		else
			name = "column_" .. i
		end

		local atype = present(element) and element.algebraic_type or nil
		columns[i] = {
			name = name,
			-- Kept verbatim, unexamined: `lib/value.lua` owns AlgebraicType.
			algebraic_type = atype ~= vim.NIL and atype or nil,
		}
	end

	return columns
end

---Parse a SQL response body into columns, rows and a duration.
---
---Tolerates the array wrapper, a bare object, an empty array and a missing
---`schema`. A multi-statement body yields an array of results; only the first
---is returned, because the UI runs one statement at a time.
---@param body string Raw response body from `POST /v1/database/{db}/sql`.
---@return SpacetimeSqlResult|nil
---@return string|nil # Message when the body is not a decodable SQL envelope.
function M.parse(body)
	local json = require("spacetime.lib.json")

	local ok, decoded = pcall(json.decode, body)
	if not ok then
		return nil, "spacetime.lib.sql: malformed JSON response: " .. tostring(decoded)
	end
	if type(decoded) ~= "table" then
		return nil, "spacetime.lib.sql: unexpected SQL response shape"
	end

	-- Array wrapper or bare object, in one line: `decoded[1]` is a table only in
	-- the wrapped case. `[]` decodes to `{}` and falls through with no `schema`
	-- and no `rows`, which is exactly the empty result we want.
	local result = (type(decoded[1]) == "table") and decoded[1] or decoded

	return {
		columns = columns_of(result.schema),
		rows = type(result.rows) == "table" and result.rows or {},
		-- `tonumber` also covers `lib/json.lua` having stringified a value of 16
		-- digits or more.
		duration_micros = tonumber(result.total_duration_micros) or 0,
	}
end

---Quote an SQL identifier: wrap it in `"` and double any embedded `"`.
---
---This doubling is the whole injection defence for table names —
---`t"; DROP TABLE x; --` becomes the single identifier `"t""; DROP TABLE x; --"`,
---which is a table that does not exist rather than a second statement.
---@param name string
---@return string # `name` wrapped in `"` with embedded `"` doubled.
function M.quote_ident(name)
	if type(name) ~= "string" then
		error("spacetime.lib.sql: table name must be a string", 2)
	end
	-- The parens matter: `gsub` returns a count too, which would otherwise
	-- become a second value in the concatenation's argument list.
	return '"' .. (name:gsub('"', '""')) .. '"'
end

---Render a row count as SQL, rejecting anything that is not a plain
---non-negative integer.
---
---The other injection seam: `LIMIT`/`OFFSET` take no identifier quoting, so a
---caller-supplied count must never be concatenated unchecked. `n ~= n` rejects
---NaN and the `math.huge` bound rejects the infinities, both of which pass a
---bare `math.floor` round-trip.
---@param n any
---@param what string `"limit"` or `"offset"`, for the message.
---@return string
local function count(n, what)
	if type(n) ~= "number" or n ~= n or n < 0 or n >= math.huge or n ~= math.floor(n) then
		-- Level 3: the caller of `select_all`, not `select_all` itself.
		error("spacetime.lib.sql: " .. what .. " must be a non-negative integer", 3)
	end
	return string.format("%d", n)
end

---Build `SELECT * FROM "table" LIMIT n [OFFSET m]`.
---@param table_name string
---@param limit integer Required; must be a non-negative integer.
---@param offset? integer Omitted from the SQL when nil or 0.
---@return string
function M.select_all(table_name, limit, offset)
	local sql = "SELECT * FROM " .. M.quote_ident(table_name) .. " LIMIT " .. count(limit, "limit")
	-- `OFFSET 0` is a no-op that only makes the query harder to read.
	if offset ~= nil and offset ~= 0 then
		sql = sql .. " OFFSET " .. count(offset, "offset")
	end
	return sql
end

return M
