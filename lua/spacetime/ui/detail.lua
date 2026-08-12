-- The fetch the two detail views share.
--
-- `ui/schema.lua` and `ui/reducers.lua` are the same machine pointed at two
-- readings of one response: both want the database's schema, both want it under
-- the same `state` key as everything else that asks, and both want the tree
-- repainted afterwards. `ui/sections.lua` is where they share the *layout*; this
-- is where they share the *request*, so the caching rule cannot come to mean two
-- different things depending on which view you opened first.
--
-- It lives under `ui/` rather than `lib/` because it calls `ui/sidebar.render`,
-- not because it paints anything itself: what to do with the answer is entirely
-- the caller's, through the two functions it passes in.
--
-- Three things this file exists to get right:
--
-- 1. **One key, so one request.** `state.key("schema", db)` is the same key the
--    sidebar's own expansion fetch uses, so expanding a database and describing
--    one of its tables in the same breath costs one request between them,
--    whichever order they happen in.
-- 2. **The tree is repainted on the way out.** One key means one request, so
--    this fetch may have *superseded* the sidebar's. The answer is in the cache
--    either way, so repainting the tree fills the node in rather than leaving it
--    reading `loading…` for a request that was taken over.
-- 3. **A response that lost its token paints nothing.** It belongs to a database
--    the user has moved away from, and painting it now would undo what they did.
--    `still_showing` is the second half of that guard: the token can be live
--    while the *view object* has been replaced, and a response must never mutate
--    a view it does not belong to.

local M = {}

---What `M.fetch_schema` needs of a view, and what it writes back into one.
---
---Structural rather than a class either view inherits: `SpacetimeSchemaDisplay`
---and `SpacetimeReducersDisplay` are both already this, plus whatever else their
---own layout wants.
---@class SpacetimeDetailDisplay
---@field connection SpacetimeConnection
---@field database string
---@field status "loading"|"ready"|"error"
---@field error? string Set when `status == "error"`.
---@field schema? SpacetimeSchema Set when `status == "ready"`.

---Fetch `current.database`'s schema into `current`, then repaint.
---
---`current` is mutated in place with the outcome — `status`, and one of `schema`
---or `error` — and `render` is called once, whichever way it went. Nothing is
---raised at the user: a failure is a `status` for the caller's `build` to turn
---into buffer text.
---@param current SpacetimeDetailDisplay The view to fill in. Mutated in place.
---@param still_showing fun(): boolean Is `current` still the view on screen?
---@param render fun() Repaint the caller's view.
function M.fetch_schema(current, still_showing, render)
	local state = require("spacetime.state")
	local key = state.key("schema", current.database)
	local client = require("spacetime.lib.client").new(current.connection)

	state.request(key, function(seq)
		return client:schema(current.database, nil, function(err, schema)
			-- Point 3 of the module header: the token first, then the view.
			if not state.finish(key, seq) then
				return
			end
			if not still_showing() then
				return
			end

			if err then
				current.status = "error"
				current.error = err.message
			elseif schema then
				current.status = "ready"
				current.schema = schema
				state.cache_set(key, schema)
				-- Point 2 of the module header.
				require("spacetime.ui.sidebar").render()
			else
				current.status = "error"
				current.error = "no schema"
			end
			render()
		end)
	end)
end

return M
