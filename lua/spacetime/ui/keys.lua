-- Buffer-local keymaps for the plugin's own buffers.
--
-- Three renderers bind keys — `ui/sidebar.lua`, `ui/rows.lua` and
-- `ui/schema.lua` — and each of them described its own `apply_keymaps` loop
-- before this module existed. One loop is now here, and the reason it is worth a
-- module of its own is the *unbinding*, which none of them did:
--
-- **The content buffer is shared.** The rows grid and the schema view paint into
-- the same `spacetime://content` buffer, so the keys one of them set are still
-- live when the other takes the buffer over. A `]p` left behind by the grid
-- would page a table that is no longer on screen, and a `s` would sort a layout
-- that no longer exists. So `M.apply` is "bind exactly these": whatever the last
-- call put in the buffer comes off first, and a view with no keys of its own
-- (the schema view) clears the buffer by asking for none.
--
-- What was applied is tracked here rather than read back from Neovim, because
-- `nvim_buf_get_keymap` cannot tell one of ours from one the user set: deleting
-- everything mapped in the buffer would take the user's own mappings with it.
--
-- This module lives under `ui/` and may therefore touch `vim.api`/`vim.keymap`;
-- `lib/` is pure logic and may not.

local M = {}

---One mapping. `keys` is a list because `<CR>` and `o` are the same action, and
---because |:help| renders them as one line.
---@class SpacetimeKeymap
---@field keys string[]
---@field desc string Shown in `:map` and printed by the sidebar's `?`.
---@field action fun()

-- Buffer -> the left-hand sides `M.apply` last bound there. Module-local: it is
-- bookkeeping, not state any renderer has business reading.
---@type table<integer, string[]>
local applied = {}

---Remove every mapping a previous |spacetime.ui.keys.apply()| put in `bufnr`.
---
---`pcall`: a buffer the user has wiped, or a mapping they have deleted by hand,
---is not an error worth reporting — and an unbind must never be the thing that
---raises out of a render.
---@param bufnr integer
function M.clear(bufnr)
	for _, lhs in ipairs(applied[bufnr] or {}) do
		pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
	end
	applied[bufnr] = nil
end

---Bind exactly `keymaps` in `bufnr`, and nothing else of ours.
---
---Idempotent, and safe to call on every render: the previous set is removed
---first, so re-applying the same table is a no-op and applying a different one
---leaves none of the old keys behind.
---@param bufnr integer
---@param keymaps SpacetimeKeymap[] Empty means "clear ours and bind nothing".
function M.apply(bufnr, keymaps)
	M.clear(bufnr)

	local bound = {} ---@type string[]
	for _, map in ipairs(keymaps) do
		for _, lhs in ipairs(map.keys) do
			vim.keymap.set("n", lhs, map.action, {
				buffer = bufnr,
				nowait = true,
				silent = true,
				desc = "spacetime: " .. map.desc,
			})
			bound[#bound + 1] = lhs
		end
	end
	applied[bufnr] = bound
end

return M
