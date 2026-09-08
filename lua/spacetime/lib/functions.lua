-- A module's callable functions — its reducers and its procedures — normalised
-- for display.
--
-- `lib/schema.lua` has already turned both wire versions into one model; this
-- module turns that model's `reducers` and `procedures` lists into the rows a
-- view paints, and nothing else. It is **pure** — no `vim.*` call at all — so the
-- layout of the functions view can be tested without an editor, and
-- `ui/functions.lua` is left with the buffer work.
--
-- The two kinds are kept apart all the way through rather than merged into one
-- list with a `kind` column, because they are not interchangeable: a procedure
-- is not automatically transactional and returns one value where a reducer
-- returns an `ok`/`err` pair. A user reading the view needs to know which of the
-- two a name is before they call it.
--
-- Four things this file exists to get right:
--
-- 1. **Unknown visibility means callable, and renders no marker.** `visibility`
--    is a v10 field; on a v9 fallback it is `nil` for every reducer. Marking
--    those `Private` would tell the user their reducers cannot be called when
--    all we actually know is that the server is too old to say. So `show_access`
--    is `true` only when at least one function carries a visibility, and a v9
--    schema lists its reducers with no marker at all (`lib/schema.is_callable`
--    reads the same field the same way). A procedure only ever arrives on v10,
--    so it always carries one.
-- 2. **A `Private` function is listed, not hidden.** It is part of the module; it
--    is simply not yours to call. `is_private` is what tells the view to grey
--    the row out — see ROADMAP.md, "Deferred past v1", where `:SpacetimeCall`
--    offers the callable ones and needs the rest to still be visible.
-- 3. **A signature names its function canonically, and once.** Everywhere else a
--    dual-spelled name is rendered as the pair `onConnect (on_connect)`, through
--    `lib/schema.display_name`. A signature is not a label, though: it reads as
--    the call you would make, and a parenthesised alias sitting where the
--    argument list belongs reads as one. The canonical name is the one that
--    spelling is stable under — it is what the module's own case-conversion
--    policy produced, what SQL joins on, and what `:SpacetimeCall` will send —
--    so it is the one spelling here. Nothing is lost: the schema view still
--    shows both.
-- 4. **The return clause reports, it does not invent.** A reducer's is the
--    `ok`/`err` pair, a procedure's is the single value it hands back, and where
--    the schema carried neither — which is every v9 reducer — the clause is
--    omitted entirely. An invented `-> ok ?` would be a claim about the module
--    rather than a report of what the server said.

local M = {}

---One function — a reducer or a procedure — as a view lays it out.
---@class SpacetimeFunctionRow
---@field access string The visibility as the server spelt it; `""` when unknown.
---@field signature string `on_connect(instanceId: U64) -> ok {} | err String`.
---@field is_private boolean Grey this row out. Never true for an unknown visibility.

---Every callable function of a module, split by kind.
---
---`show_access` is shared rather than per-kind so that the two sections agree
---about whether there is an access column at all: it is a fact about the server
---that answered, not about either list.
---@class SpacetimeFunctionList
---@field show_access boolean Did the server tell us any visibility at all?
---@field reducers SpacetimeFunctionRow[]
---@field procedures SpacetimeFunctionRow[]

---One function's signature, under its canonical name.
---
---The canonical spelling alone, not the `name (canonical)` pair
---`lib/schema.display_name` renders — see point 3 of the module header.
---
---Which return clause is printed follows from which fields the entry carries:
---`return_type` is a procedure's single value, `ok_return_type` and
---`err_return_type` are a reducer's pair, and none of the three is a v9 reducer,
---which gets no clause at all.
---@param fn SpacetimeSchemaReducer|SpacetimeSchemaProcedure
---@param schema SpacetimeSchema
---@return string
function M.signature(fn, schema)
	local value = require("spacetime.lib.value")

	local params = {}
	for i, param in ipairs(fn.params or {}) do
		local label = value.label(param.type, schema)
		params[i] = param.name and (param.name .. ": " .. label) or label
	end

	-- Both schema versions set `canonical`; the fallback is for the half-built
	-- models `M.list` below already tolerates, where a name is better than none.
	local name = fn.canonical
	if type(name) ~= "string" or name == "" then
		name = type(fn.name) == "string" and fn.name or ""
	end

	local out = name .. "(" .. table.concat(params, ", ") .. ")"

	local returns = {}
	if fn.return_type ~= nil then
		returns[#returns + 1] = value.label(fn.return_type, schema)
	end
	if fn.ok_return_type ~= nil then
		returns[#returns + 1] = "ok " .. value.label(fn.ok_return_type, schema)
	end
	if fn.err_return_type ~= nil then
		returns[#returns + 1] = "err " .. value.label(fn.err_return_type, schema)
	end
	if #returns > 0 then
		out = out .. " -> " .. table.concat(returns, " | ")
	end
	return out
end

---One kind's rows, in the order the schema holds them.
---@param entries table[]
---@param schema SpacetimeSchema
---@return SpacetimeFunctionRow[]
local function rows_of(entries, schema)
	local rows = {} ---@type SpacetimeFunctionRow[]
	for i, fn in ipairs(entries) do
		rows[i] = {
			access = fn.visibility or "",
			signature = M.signature(fn, schema),
			-- `nil` visibility is not `Private`; see point 1 of the module header.
			is_private = fn.visibility == "Private",
		}
	end
	return rows
end

---Every callable function of `schema`, ready to be laid out.
---
---Tolerant of a half-built model: a schema with no `reducers` or no `procedures`
---yields an empty list for that kind rather than raising, because the one caller
---that reads a *cached* model cannot be sure what is under either key.
---@param schema SpacetimeSchema|table
---@return SpacetimeFunctionList
function M.list(schema)
	if type(schema) ~= "table" then
		return { show_access = false, reducers = {}, procedures = {} }
	end

	local reducers = type(schema.reducers) == "table" and schema.reducers or {}
	local procedures = type(schema.procedures) == "table" and schema.procedures or {}

	local show_access = false
	for _, entries in ipairs({ reducers, procedures }) do
		for _, fn in ipairs(entries) do
			if type(fn.visibility) == "string" then
				show_access = true
			end
		end
	end

	return {
		show_access = show_access,
		reducers = rows_of(reducers, schema),
		procedures = rows_of(procedures, schema),
	}
end

return M
