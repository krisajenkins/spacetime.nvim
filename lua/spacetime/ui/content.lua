-- The content window's current view, whatever it happens to be.
--
-- Four modules paint `spacetime://content` — the row grid, the schema, the
-- reducers and the logs — and each of them knows how to re-run itself. What
-- none of them knows is which of the four is *on screen*, and `r` needs exactly
-- that: it refreshes what the user is looking at, not all four views in turn.
--
-- The answer is already recorded. Every view claims the buffer under its
-- `M.OWNER` before it paints (`ui/buffer.claim_content`), because a response
-- that lands after another view has taken the buffer over must not paint over
-- it. So the claim doubles as the name of the current view, and this module is
-- the one place that turns it back into a module.
--
-- It is a module of its own rather than a branch inside `ui/sidebar.lua` for the
-- dependency: the sidebar opens the four views and would happily require them
-- again, but a view that wanted to refresh a *sibling* would then have to reach
-- through the sidebar to do it. The lookup belongs beside the claim it reads.
--
-- Requires are inside the function body, as everywhere else under `ui/`: three
-- of the four views require this module's caller back.

local M = {}

---The modules that paint the content buffer, by `require` suffix.
---
---Order is not significant — at most one of them holds the claim — but it is the
---order `ui/sidebar.lua` opens them in, so a reader can check the list is
---complete against the four keys that open them (`<CR>`, `s`, `R`, `gl`).
local VIEWS = { "rows", "schema", "reducers", "logs" }

---Re-run whatever the content window is showing.
---
---Each view's own `refresh()` decides what that means: the grid refetches the
---page it is on, the schema and reducers views re-request the schema, and the
---logs view asks for its backlog again and restarts a follow. All four drop
---their cache entry first — the cache has no expiry, so a refresh that read it
---would paint the same rows again and call it fresh.
---
---A no-op, reported rather than raised, when the content window is showing the
---placeholder or nothing at all: `r` in a layout that has only just opened has
---no data view to refresh, and the tree it also refreshes is the whole of what
---is on screen.
---@return boolean refreshed False when no view holds the content buffer.
function M.refresh()
	local buffer = require("spacetime.ui.buffer")
	for _, name in ipairs(VIEWS) do
		local view = require("spacetime.ui." .. name)
		if buffer.owns_content(view.OWNER) then
			return view.refresh()
		end
	end
	return false
end

return M
