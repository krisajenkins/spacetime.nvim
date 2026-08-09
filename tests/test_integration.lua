-- Integration tests: load the plugin in a real (child) Neovim the way a user's
-- plugin manager would, and assert the load-time wiring holds.
local child, new_set = require("tests.helpers.child")()

local T = new_set()

T["plugin/spacetime.lua loads and sets its guard"] = function()
	child.cmd("runtime! plugin/spacetime.lua")
	child.lua([[ expect.equality(vim.g.loaded_spacetime, 1) ]])
end

T["the module can be required and set up"] = function()
	child.lua([[
    local spacetime = require('spacetime')
    spacetime.setup()
    expect.equality(type(spacetime.config), 'table')
  ]])
end

T[":checkhealth spacetime runs"] = function()
	-- Exercise the real health entry point end to end; it must not throw, and it
	-- must produce a report buffer.
	child.lua([[ expect.no_error(function() vim.cmd('checkhealth spacetime') end) ]])
	child.lua([[ expect.equality(vim.bo.filetype, 'checkhealth') ]])
end

return T
