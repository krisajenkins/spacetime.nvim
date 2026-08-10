-- A module's reducers, normalised for display.
--
-- `lib/schema.lua` has already turned both wire versions into one model; this
-- module turns that model's `reducers` list into the rows a view paints, and
-- nothing else. It is **pure** — no `vim.*` call at all — so the layout of the
-- reducers view can be tested without an editor, and `ui/reducers.lua` is left
-- with the buffer work.
--
-- Two things this file exists to get right:
--
-- 1. **Unknown visibility means callable, and renders no marker.** `visibility`
--    is a v10 field; on a v9 fallback it is `nil` for every reducer. Marking
--    those `Private` would tell the user their reducers cannot be called when
--    all we actually know is that the server is too old to say. So `show_access`
--    is `true` only when at least one reducer carries a visibility, and a v9
--    schema lists its reducers with no marker at all (`lib/schema.is_callable`
--    reads the same field the same way).
-- 2. **A `Private` reducer is listed, not hidden.** It is part of the module; it
--    is simply not yours to call. `is_private` is what tells the view to grey
--    the row out — see ROADMAP.md, "Deferred past v1", where `:SpacetimeCall`
--    offers the callable ones and needs the rest to still be visible.
--
-- The return clause of a signature is omitted entirely when the schema carried
-- neither type, which is every v9 reducer: an invented `-> ok ?` would be a
-- claim about the module rather than a report of what the server said.

local M = {}

---One reducer, as a view lays it out.
---@class SpacetimeReducerRow
---@field access string The visibility as the server spelt it; `""` when unknown.
---@field signature string `book (book)(instanceId: U64) -> ok {} / err String`.
---@field is_private boolean Grey this row out. Never true for an unknown visibility.

---Every reducer of a module, in the order the schema holds them.
---@class SpacetimeReducerList
---@field show_access boolean Did the server tell us any visibility at all?
---@field rows SpacetimeReducerRow[]

---One reducer's signature, both spellings of its name included.
---@param reducer SpacetimeSchemaReducer
---@param schema SpacetimeSchema
---@return string
function M.signature(reducer, schema)
	local value = require("spacetime.lib.value")

	local params = {}
	for i, param in ipairs(reducer.params or {}) do
		local label = value.label(param.type, schema)
		params[i] = param.name and (param.name .. ": " .. label) or label
	end

	local out = require("spacetime.lib.schema").display_name(reducer.name, reducer.canonical)
		.. "("
		.. table.concat(params, ", ")
		.. ")"

	local returns = {}
	if reducer.ok_return_type ~= nil then
		returns[#returns + 1] = "ok " .. value.label(reducer.ok_return_type, schema)
	end
	if reducer.err_return_type ~= nil then
		returns[#returns + 1] = "err " .. value.label(reducer.err_return_type, schema)
	end
	if #returns > 0 then
		out = out .. " -> " .. table.concat(returns, " / ")
	end
	return out
end

---Every reducer of `schema`, ready to be laid out.
---
---Tolerant of a half-built model: a schema with no `reducers` yields an empty
---list rather than raising, because the one caller that reads a *cached* model
---cannot be sure what is under the key.
---@param schema SpacetimeSchema|table
---@return SpacetimeReducerList
function M.list(schema)
	if type(schema) ~= "table" then
		return { show_access = false, rows = {} }
	end

	local reducers = type(schema.reducers) == "table" and schema.reducers or {}

	local show_access = false
	for _, reducer in ipairs(reducers) do
		if type(reducer.visibility) == "string" then
			show_access = true
		end
	end

	local rows = {} ---@type SpacetimeReducerRow[]
	for i, reducer in ipairs(reducers) do
		rows[i] = {
			access = reducer.visibility or "",
			signature = M.signature(reducer, schema),
			-- `nil` visibility is not `Private`; see point 1 of the module header.
			is_private = reducer.visibility == "Private",
		}
	end

	return { show_access = show_access, rows = rows }
end

return M
