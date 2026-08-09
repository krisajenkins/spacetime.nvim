-- Tests for the deliberately-partial cli.toml reader.
--
-- No child Neovim: the module is pure Lua and touches nothing in `vim`. The
-- inputs are built inline rather than committed as a fixture — a real
-- `cli.toml` carries a live JWT, so the one file this parser exists for is the
-- one file that must never enter the repository.
local clitoml = require("spacetime.lib.clitoml")
local expect = MiniTest.expect

local T = MiniTest.new_set()

-- The shape of the real file, minus the tokens' real values.
local SAMPLE = table.concat({
	'default_server = "local"',
	'web_session_token = "web-tok"',
	'spacetimedb_token = "db-tok"',
	"",
	"[[server_configs]]",
	'nickname = "local"',
	'host = "127.0.0.1:3000"',
	'protocol = "http"',
	"",
	"[[server_configs]]",
	'nickname = "maincloud"',
	'host = "maincloud.spacetimedb.com"',
	'protocol = "https"',
}, "\n")

T["a file with both token keys yields spacetimedb_token"] = function()
	local config = clitoml.parse(SAMPLE)
	expect.equality(config.spacetimedb_token, "db-tok")
	-- The session token must not survive anywhere in the result, under any key:
	-- a caller dumping its config should not be able to print it.
	for _, value in pairs(config) do
		expect.no_equality(value, "web-tok")
	end
end

T["two [[server_configs]] blocks both survive, in order"] = function()
	local servers = clitoml.parse(SAMPLE).server_configs
	expect.equality(#servers, 2)
	expect.equality(servers[1], { nickname = "local", host = "127.0.0.1:3000", protocol = "http" })
	expect.equality(servers[2], { nickname = "maincloud", host = "maincloud.spacetimedb.com", protocol = "https" })
end

T["top-level keys parse before any table header"] = function()
	expect.equality(clitoml.parse(SAMPLE).default_server, "local")
end

T["comments and blank lines are skipped"] = function()
	local config = clitoml.parse(table.concat({
		"# a leading comment",
		"",
		'   # an indented comment with an = sign and a "quote"',
		'default_server = "local" # trailing, on a quoted value',
		"",
		"[[server_configs]]",
		'host = "h" # prod',
	}, "\n"))
	expect.equality(config.default_server, "local")
	expect.equality(#config.server_configs, 1)
	expect.equality(config.server_configs[1].host, "h")
end

T["a malformed line is skipped without error"] = function()
	local config
	expect.no_error(function()
		config = clitoml.parse(table.concat({
			'default_server = "local"',
			"this line has no equals sign",
			"server.nickname = 'dotted'",
			"inline = { nickname = 'x' }",
			"[[server_configs]]",
			'nickname = "unterminated',
			'host = "127.0.0.1:3000"',
		}, "\n"))
	end)
	expect.equality(config.default_server, "local")
	-- The unterminated string takes its own line with it and nothing else.
	expect.equality(config.server_configs[1], { host = "127.0.0.1:3000" })
end

T["keys after an unknown table header are ignored"] = function()
	local config = clitoml.parse(table.concat({
		"[[server_configs]]",
		'nickname = "local"',
		"[foo]",
		'host = "nope"',
		"[[bar]]",
		'default_server = "nope"',
	}, "\n"))
	expect.equality(config.default_server, nil)
	expect.equality(#config.server_configs, 1)
	expect.equality(config.server_configs[1], { nickname = "local" })
end

T["a # inside a quoted value is preserved"] = function()
	expect.equality(clitoml.parse('spacetimedb_token = "a#b" # note').spacetimedb_token, "a#b")
end

T["a bare value stays a string"] = function()
	expect.equality(clitoml.parse("default_server = 3000").default_server, "3000")
end

T["parse of an empty string yields an empty config"] = function()
	expect.equality(clitoml.parse(""), { server_configs = {} })
end

T["a missing file yields an empty table, not an error"] = function()
	local config
	expect.no_error(function()
		config = clitoml.read("/nonexistent/spacetime/cli.toml")
	end)
	expect.equality(config, { server_configs = {} })
end

T["read() parses a file written to a temp path"] = function()
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	file:write(SAMPLE)
	file:close()

	local config = clitoml.read(path)
	os.remove(path)

	expect.equality(config.spacetimedb_token, "db-tok")
	expect.equality(config.default_server, "local")
	expect.equality(#config.server_configs, 2)
	expect.equality(config.server_configs[2].nickname, "maincloud")
end

return T
