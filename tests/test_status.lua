-- Tests for `:SpacetimeStatus`, the plugin's first user-visible command.
--
-- A child Neovim, because the command is registered by `plugin/spacetime.lua`
-- and the assertions are on what it actually echoes.
--
-- The environment is isolated inside the child before every case: `XDG_CONFIG_HOME`
-- points at a directory that does not exist, so `clitoml.read` returns an empty
-- config rather than the developer's real `~/.config/spacetime/cli.toml`, and
-- every `SPACETIMEDB_*` variable is set explicitly so an ambient one cannot
-- change the answer.
--
-- The load-bearing case is "the token appears nowhere in the output". Everything
-- else here is about the command staying useful when resolution fails; that one
-- is about it being safe to paste into a bug report.
local child, new_set = require("tests.helpers.child")()
local expect = MiniTest.expect

-- The same JWT `tests/test_identity.lua` uses: its payload derives offline to the
-- TUI's golden identity, so no network and no real credential is involved.
local PAYLOAD = "eyJpc3MiOiJodHRwczovL2F1dGguc3BhY2V0aW1lZGIuY29tIiwic3ViIjoidGVzdC1zdWJqZWN0LTAwMDEifQ"
local TOKEN = "hdr." .. PAYLOAD .. ".sig"
local TOKEN_IDENTITY = "c2005855e0ffa65fe854d934cff22cd1c9c60c2070d562b65f07f2c5f20dd8c1"

local LABELS = { "server", "identity", "token", "cli.toml", "project" }

local T = new_set({
	pre_case = function(c)
		c.lua([[
			vim.env.XDG_CONFIG_HOME = '/nonexistent-spacetime-test'
			vim.env.SPACETIMEDB_HOST = 'localhost'
			vim.env.SPACETIMEDB_PORT = nil
			vim.env.SPACETIMEDB_SERVER = nil
			vim.env.SPACETIMEDB_DATABASE = nil
			vim.env.SPACETIMEDB_TOKEN = nil
		]])
	end,
})

---Run the command in the child and return everything it echoed.
---@return string
local function status()
	return child.cmd_capture("SpacetimeStatus")
end

T["reports a configured token as present, never as itself"] = function()
	child.lua("vim.env.SPACETIMEDB_TOKEN = ...", { TOKEN })
	local out = status()

	expect.equality(out:match("token:%s+(%S+)"), "present")
	expect.equality(out:match("identity:%s+(%S+)"), TOKEN_IDENTITY)
end

T["the token appears nowhere in the output"] = function()
	child.lua("vim.env.SPACETIMEDB_TOKEN = ...", { TOKEN })
	local out = status()

	-- Plain-text `find`, not a pattern match: the point is that no substring of
	-- the credential survives, so the needle must be taken literally.
	expect.equality(out:find(TOKEN, 1, true), nil)
	expect.equality(out:find(PAYLOAD, 1, true), nil)

	-- And the command really did produce a report to search through.
	expect.equality(out:find("token:%s+present") ~= nil, true)
end

T["reports an absent token without erroring on the identity"] = function()
	local out = status()

	expect.equality(out:match("token:%s+(%S+)"), "absent")
	expect.equality(out:match("identity:%s+([^\n]+)"), "no token configured")
end

T["prints the five fields, once each, in order"] = function()
	child.lua("vim.env.SPACETIMEDB_TOKEN = ...", { TOKEN })
	local lines = child.lua_get("require('spacetime.status').lines(0)")

	expect.equality(#lines, #LABELS)
	for i, label in ipairs(LABELS) do
		expect.equality({ i, lines[i]:match("^([^:]+):") }, { i, label })
	end

	-- The gutter puts every value in the same column.
	for _, line in ipairs(lines) do
		expect.equality(line:match("^.-:%s") ~= nil, true)
	end
end

T["an unresolvable server nickname is reported, not raised"] = function()
	child.lua([[
		vim.env.SPACETIMEDB_HOST = nil
		vim.env.SPACETIMEDB_SERVER = 'nosuchserver'
	]])

	local out = status()

	expect.equality(out:find("nosuchserver", 1, true) ~= nil, true)
	expect.equality(out:match("identity:%s+([^\n]+)"), "unknown (no connection resolved)")
	expect.equality(out:match("token:%s+(%S+)"), "absent")
	-- The lines that never needed a connection are still there — they are the
	-- diagnosis.
	expect.equality(#child.lua_get("require('spacetime.status').lines(0)"), #LABELS)
end

T["no project files means project: none"] = function()
	-- The plugin's own repo has no spacetime.json, and the child starts in it.
	expect.equality(status():match("project:%s+([^\n]+)"), "none")
end

T["checkhealth mirrors the same fields and leaks nothing"] = function()
	child.lua("vim.env.SPACETIMEDB_TOKEN = ...", { TOKEN })
	-- `:checkhealth` renders into a buffer rather than echoing, so the report has
	-- to be read back out of it.
	child.cmd("checkhealth spacetime")
	local out = table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")

	expect.equality(out:find("token: present", 1, true) ~= nil, true)
	expect.equality(out:find(TOKEN, 1, true), nil)
	expect.equality(out:find(PAYLOAD, 1, true), nil)
end

return T
