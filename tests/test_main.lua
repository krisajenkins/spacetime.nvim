-- Tests for the top-level spacetime module: its setup() contract and config
-- handling. Reload the module per case so config from one test can't leak into
-- the next.
local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			package.loaded["spacetime"] = nil
			package.loaded["spacetime.logger"] = nil
		end,
	},
})
local expect = MiniTest.expect

T["exposes setup()"] = function()
	local spacetime = require("spacetime")
	expect.equality(type(spacetime.setup), "function")
end

T["setup() works with no arguments"] = function()
	local spacetime = require("spacetime")
	expect.no_error(function()
		spacetime.setup()
	end)
end

T["setup() rejects a non-table argument"] = function()
	local spacetime = require("spacetime")
	expect.error(function()
		---@diagnostic disable-next-line: param-type-mismatch
		spacetime.setup("nope")
	end)
end

T["setup() rejects a non-numeric log_level"] = function()
	local spacetime = require("spacetime")
	expect.error(function()
		---@diagnostic disable-next-line: assign-type-mismatch
		spacetime.setup({ log_level = "debug" })
	end)
end

T["setup() does not store log_level as config"] = function()
	local spacetime = require("spacetime")
	spacetime.setup({ log_level = vim.log.levels.DEBUG })
	expect.equality(spacetime.config.log_level, nil)
end

T["setup() rejects a non-string identity"] = function()
	local spacetime = require("spacetime")
	expect.error(function()
		---@diagnostic disable-next-line: assign-type-mismatch
		spacetime.setup({ identity = 42 })
	end)
end

-- Unlike log_level, the identity override is stored: it is read whenever an
-- identity is needed, not consumed once at setup time.
T["setup() stores the identity override"] = function()
	local spacetime = require("spacetime")
	spacetime.setup({ identity = "c200deadbeef" })
	expect.equality(spacetime.config.identity, "c200deadbeef")
end

return T
