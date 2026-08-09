-- Shared child-Neovim scaffolding for integration tests.
--
-- Most integration tests open with the same boilerplate: create a child
-- Neovim, then a `new_set` whose `pre_case` restarts the child on
-- `scripts/minimal_init.lua`, clears `readonly` and installs the `expect`
-- global, with `post_once = child.stop`.
-- This helper packages that up.
--
-- Usage:
--   local child, new_set = require("tests.helpers.child")()
--
--   local T = new_set()                          -- just the standard hooks
--
--   local T = new_set({                          -- standard hooks + extra setup
--     pre_case = function(c)                      -- runs AFTER the standard block;
--       c.lua([[ M = require('spacetime') ]])     -- `c` is the child handle
--     end,
--   })
--
--   local T = new_set({ post_once = function() ... end })  -- override cleanup
--
-- `pre_case` extra steps are appended to (not replacing) the standard block, so
-- files that add options, requires or helper functions still get the common
-- setup for free. `post_once` defaults to `child.stop`.

local MiniTest = require("mini.test")

---Build a child Neovim handle plus a `new_set` factory bound to it.
---@return table child      The `MiniTest.new_child_neovim()` handle.
---@return fun(opts?: table): table new_set  Factory installing the standard hooks.
local function make()
	local child = MiniTest.new_child_neovim()

	---@param opts? { pre_case?: fun(child: table), post_once?: fun() }
	---@return table
	local function new_set(opts)
		opts = opts or {}
		return MiniTest.new_set({
			hooks = {
				pre_case = function()
					child.restart({ "-u", "scripts/minimal_init.lua" })
					child.bo.readonly = false
					child.lua([[ expect = require('mini.test').expect ]])
					if opts.pre_case then
						opts.pre_case(child)
					end
				end,
				post_once = opts.post_once or child.stop,
			},
		})
	end

	return child, new_set
end

return make
