-- Highlight-group tests. These run in a child Neovim because the assertions are
-- about global editor state: the groups plugin/spacetime.lua registers at load
-- time, and how they behave across a `:colorscheme` change.
local child, new_set = require("tests.helpers.child")()
local expect = MiniTest.expect

local T = new_set()

-- Asserts each documented group resolves to exactly `{ link = <target>,
-- default = true }`. Exact-table equality is the whole assertion: nvim_get_hl
-- does not resolve a link, so a group defined with a colour instead of a link
-- would come back as `{ fg = ... }` and fail, and dropping `default` would mean
-- the plugin had overridden the user rather than deferring to them.
local EXPECT_ALL_LINKED = [[
  for name, target in pairs(require('spacetime.ui.highlights').links) do
    expect.equality(vim.api.nvim_get_hl(0, { name = name }), { link = target, default = true })
  end
]]

T["registers every documented group as a link at load time"] = function()
	child.lua(EXPECT_ALL_LINKED)
end

T["the documented group list is exactly the eleven UI groups"] = function()
	expect.equality(child.lua_get([[require('spacetime.ui.highlights').links]]), {
		SpacetimeHeader = "Title",
		SpacetimeDatabase = "Directory",
		SpacetimeTable = "Normal",
		SpacetimeView = "Type",
		SpacetimeSystemTable = "Comment",
		SpacetimeNull = "Comment",
		SpacetimePrimaryKey = "Identifier",
		SpacetimeSpecial = "Special",
		SpacetimeTruncated = "NonText",
		SpacetimeError = "ErrorMsg",
		SpacetimePaused = "WarningMsg",
	})
end

T["the defaults survive a colourscheme change"] = function()
	child.cmd("colorscheme habamax")
	child.lua(EXPECT_ALL_LINKED)
end

T["a user's own definition wins over the default"] = function()
	child.lua([[
    vim.api.nvim_set_hl(0, 'SpacetimeHeader', { link = 'Comment' })
    require('spacetime.ui.highlights').apply()
    expect.equality(vim.api.nvim_get_hl(0, { name = 'SpacetimeHeader' }), { link = 'Comment' })
  ]])
end

T["a ColorScheme autocommand re-applies the defaults"] = function()
	expect.equality(
		child.lua_get([[#vim.api.nvim_get_autocmds({ group = 'SpacetimeHighlights', event = 'ColorScheme' })]]),
		1
	)
end

return T
