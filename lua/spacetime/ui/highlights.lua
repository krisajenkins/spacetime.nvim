-- Default highlight groups for every spacetime.nvim renderer.
--
-- Every group is defined as a `default = true` link to a standard group. That
-- matters twice over: a colourscheme that defines `SpacetimeHeader` itself wins
-- (Neovim never overwrites a non-default definition with a default one), and a
-- user who just wants a different colour can `:hi link SpacetimeHeader ...` or
-- `nvim_set_hl` without patching the plugin. Linking rather than hard-coding
-- colours also means the plugin inherits whatever palette is in force, light or
-- dark, with no palette of its own to keep in sync.
--
-- This module lives under `ui/` and may therefore touch `vim.api`; `lib/` is
-- pure logic and may not.
local M = {}

---The complete set of groups the plugin defines, mapped to their link targets.
---Exported so renderers and tests enumerate it rather than re-listing names.
---@type table<string, string>
M.links = {
	SpacetimeHeader = "Title", -- column headers, buffer titles
	SpacetimeDatabase = "Directory", -- database nodes
	SpacetimeTable = "Normal", -- user tables
	SpacetimeView = "Type", -- views
	SpacetimeSystemTable = "Comment", -- st_* system tables
	SpacetimeNull = "Comment", -- NULL cells
	SpacetimePrimaryKey = "Identifier", -- primary-key columns
	SpacetimeSpecial = "Special", -- identity / connection-id / timestamp newtypes
	SpacetimeTruncated = "NonText", -- the truncation ellipsis
	SpacetimeError = "ErrorMsg", -- in-buffer error text
	SpacetimePaused = "WarningMsg", -- the paused marker
}

---Define every group in `M.links` as a default link. Idempotent, and a no-op
---for any group the user or colourscheme has already defined themselves.
function M.apply()
	for name, target in pairs(M.links) do
		vim.api.nvim_set_hl(0, name, { link = target, default = true })
	end
end

---Apply the defaults now and re-apply them on every `ColorScheme`. `default`
---links already survive `:colorscheme`, so the autocommand is belt-and-braces
---against a colourscheme that clears the groups outright.
function M.register()
	M.apply()

	local group = vim.api.nvim_create_augroup("SpacetimeHighlights", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		desc = "Re-apply spacetime.nvim default highlight groups",
		callback = M.apply,
	})
end

return M
