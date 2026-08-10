-- Tests for the scratch-buffer primitives and the sidebar/content layout.
--
-- All of it runs in a child Neovim: every assertion here is about real editor
-- state — buffer options, window handles, window geometry and which window has
-- focus — none of which the headless runner can be asked to fake convincingly.
--
-- The layout is torn down by restarting the child between cases (the standard
-- hook), so no case has to unpick another's windows. Where a window does need
-- closing mid-case it is closed with `nvim_win_close`, never `:q`: the child
-- would exit if the quit hit the last window, and the test would hang (see
-- tests/CLAUDE.md).
local child, new_set = require("tests.helpers.child")()
local expect = MiniTest.expect

local T = new_set({
	pre_case = function(c)
		c.lua([[ B = require('spacetime.ui.buffer') ]])
	end,
})

--------------------------------------------------------------------------------
-- Scratch buffers
--------------------------------------------------------------------------------

T["the buffer getter is idempotent for one name"] = function()
	local first = child.lua_get([[B.get('spacetime://sidebar')]])
	local second = child.lua_get([[B.get('spacetime://sidebar')]])
	expect.equality(first, second)
end

T["different names get different buffers"] = function()
	child.lua([[
    expect.no_equality(B.get('spacetime://sidebar'), B.get('spacetime://content'))
  ]])
end

T["a new buffer is a hidden, unmodifiable, unswapped scratch buffer"] = function()
	child.lua([[
    local bufnr = B.get('spacetime://content')
    expect.equality(vim.bo[bufnr].buftype, 'nofile')
    expect.equality(vim.bo[bufnr].bufhidden, 'hide')
    expect.equality(vim.bo[bufnr].swapfile, false)
    expect.equality(vim.bo[bufnr].modifiable, false)
    expect.equality(vim.bo[bufnr].filetype, B.CONTENT_FILETYPE)
    expect.equality(vim.bo[bufnr].buflisted, false)
  ]])
end

T["the filetype is overridable per buffer"] = function()
	expect.equality(
		child.lua_get([[vim.bo[B.get('spacetime://tree', { filetype = 'spacetimetree' })].filetype]]),
		"spacetimetree"
	)
end

T["a name outside the spacetime:// scheme is rejected"] = function()
	child.lua([[ expect.error(function() B.get('/tmp/not-ours') end) ]])
end

T["set_lines writes to a non-modifiable buffer and leaves it non-modifiable"] = function()
	child.lua([[
    local bufnr = B.get('spacetime://content')
    expect.equality(vim.bo[bufnr].modifiable, false)

    B.set_lines(bufnr, { 'one', 'two' })

    expect.equality(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'one', 'two' })
    expect.equality(vim.bo[bufnr].modifiable, false)
  ]])
end

T["set_lines restores modifiable on a modifiable buffer too"] = function()
	child.lua([[
    local bufnr = B.get('spacetime://content')
    vim.bo[bufnr].modifiable = true

    B.set_lines(bufnr, { 'one' })

    expect.equality(vim.bo[bufnr].modifiable, true)
  ]])
end

-- The pcall-safe cleanup: a write that raises must still put `modifiable` back,
-- or the buffer is left editable and the error is the least of the damage.
T["a failing write raises but does not leave the buffer modifiable"] = function()
	child.lua([[
    local bufnr = B.get('spacetime://content')
    expect.error(function() B.set_lines(bufnr, { true }) end)
    expect.equality(vim.bo[bufnr].modifiable, false)
  ]])
end

T["set_lines can replace a single line"] = function()
	child.lua([[
    local bufnr = B.get('spacetime://content')
    B.set_lines(bufnr, { 'one', 'two', 'three' })
    B.set_lines(bufnr, { 'TWO' }, 1, 2)
    expect.equality(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'one', 'TWO', 'three' })
  ]])
end

T["there is exactly one extmark namespace, reused"] = function()
	child.lua([[
    local ns = B.namespace()
    expect.equality(B.namespace(), ns)
    expect.equality(vim.api.nvim_get_namespaces().spacetime, ns)
  ]])
end

--------------------------------------------------------------------------------
-- The layout
--------------------------------------------------------------------------------

T["open_layout() twice yields the same two window handles"] = function()
	child.lua([[ SIDEBAR, CONTENT = B.open_layout() ]])
	local again = child.lua_get([[{ B.open_layout() }]])
	expect.equality(again, child.lua_get([[{ SIDEBAR, CONTENT }]]))
	-- And no third window has been stacked up behind them.
	expect.equality(child.lua_get([[#vim.api.nvim_tabpage_list_wins(0)]]), 2)
end

T["closing the sidebar and re-running recreates only the sidebar"] = function()
	child.lua([[ SIDEBAR, CONTENT = B.open_layout() ]])

	-- Two windows are open, so closing one cannot exit the child.
	child.lua([[ vim.api.nvim_win_close(SIDEBAR, true) ]])
	expect.equality(child.lua_get([[#vim.api.nvim_tabpage_list_wins(0)]]), 1)

	child.lua([[ SIDEBAR2, CONTENT2 = B.open_layout() ]])
	expect.equality(child.lua_get([[CONTENT2 == CONTENT]]), true)
	expect.equality(child.lua_get([[SIDEBAR2 == SIDEBAR]]), false)
	expect.equality(child.lua_get([[#vim.api.nvim_tabpage_list_wins(0)]]), 2)
end

-- `:only` from the sidebar is the awkward case: the sole surviving window is
-- the sidebar, so the content window cannot simply be "the current one".
T["re-running after :only in the sidebar recreates the content window"] = function()
	child.lua([[ SIDEBAR = B.open_layout() ]])
	child.lua([[ vim.cmd('only') ]])

	child.lua([[ SIDEBAR2, CONTENT2 = B.open_layout() ]])
	expect.equality(child.lua_get([[SIDEBAR2 == SIDEBAR]]), true)
	expect.equality(child.lua_get([[CONTENT2 ~= SIDEBAR2]]), true)
	expect.equality(
		child.lua_get([[vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(CONTENT2))]]),
		"spacetime://content"
	)
end

T["the two windows show the two spacetime buffers"] = function()
	child.lua([[ SIDEBAR, CONTENT = B.open_layout() ]])
	expect.equality(
		child.lua_get([[vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(SIDEBAR))]]),
		"spacetime://sidebar"
	)
	expect.equality(
		child.lua_get([[vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(CONTENT))]]),
		"spacetime://content"
	)
end

T["focus is left on the sidebar"] = function()
	child.lua([[ SIDEBAR = B.open_layout() ]])
	expect.equality(child.lua_get([[vim.api.nvim_get_current_win() == SIDEBAR]]), true)
end

T["the sidebar defaults to the left, 30 columns wide"] = function()
	child.lua([[ SIDEBAR = B.open_layout() ]])
	-- Column 0 is the far left of the tabpage.
	expect.equality(child.lua_get([==[vim.api.nvim_win_get_position(SIDEBAR)[2]]==]), 0)
	expect.equality(child.lua_get([[vim.api.nvim_win_get_width(SIDEBAR)]]), 30)
end

T["side = 'right' puts the sidebar against the right edge"] = function()
	child.lua([[
    require('spacetime').setup({ side = 'right', width = 25 })
    SIDEBAR, CONTENT = B.open_layout()
  ]])
	expect.equality(child.lua_get([[vim.api.nvim_win_get_width(SIDEBAR)]]), 25)
	-- The sidebar's own columns plus its offset account for the whole screen,
	-- and the content window is to its left.
	expect.equality(child.lua_get([[vim.api.nvim_win_get_position(SIDEBAR)[2] + 25 == vim.o.columns]]), true)
	expect.equality(child.lua_get([==[vim.api.nvim_win_get_position(CONTENT)[2]]==]), 0)
end

T["a percentage width resolves against the screen width"] = function()
	child.lua([[
    require('spacetime').setup({ width = '25%' })
    SIDEBAR = B.open_layout()
  ]])
	expect.equality(
		child.lua_get([[vim.api.nvim_win_get_width(SIDEBAR)]]),
		child.lua_get([[math.floor(vim.o.columns * 25 / 100)]])
	)
end

T["the sidebar carries the four window options"] = function()
	child.lua([[ SIDEBAR = B.open_layout() ]])
	child.lua([[
    expect.equality(vim.wo[SIDEBAR].winfixwidth, true)
    expect.equality(vim.wo[SIDEBAR].number, false)
    expect.equality(vim.wo[SIDEBAR].relativenumber, false)
    expect.equality(vim.wo[SIDEBAR].signcolumn, 'no')
    expect.equality(vim.wo[SIDEBAR].wrap, false)
  ]])
end

-- The decision of record: `:Spacetime` rearranges the current tabpage rather
-- than opening one of its own, and the current window is what gets displaced.
T["the layout is built in the current tabpage"] = function()
	child.lua([[ B.open_layout() ]])
	expect.equality(child.lua_get([[#vim.api.nvim_list_tabpages()]]), 1)
end

return T
