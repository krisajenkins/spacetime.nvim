-- Tests for connection resolution and per-project config discovery.
--
-- No child Neovim: `resolve` is pure, and the discovery half only needs
-- `vim.fn`/`vim.uv`/`vim.fs`, all of which the runner already has.
--
-- Two deliberate choices here. Every cli.toml input is an inline TOML string fed
-- through `clitoml.parse`, never a fixture file — the real file carries a live
-- JWT, so it must never enter the repository, and no token in this file is real.
-- And the discovery cases build real directory trees under `tempname()` rather
-- than stubbing the filesystem, because a `.git` *file* (as worktrees and
-- submodules have) is the case most likely to be got wrong, and only a real file
-- proves the existence-not-directory rule.
local config = require("spacetime.config")
local clitoml = require("spacetime.lib.clitoml")
local expect = MiniTest.expect

local T = MiniTest.new_set()

-- The shape of a real cli.toml: a remote default over https with no port in the
-- host, plus a local server with one.
local CLI_TOML = table.concat({
	'default_server = "maincloud"',
	'spacetimedb_token = "cfg-tok"',
	"",
	"[[server_configs]]",
	'nickname = "maincloud"',
	'host = "maincloud.spacetimedb.com"',
	'protocol = "https"',
	"",
	"[[server_configs]]",
	'nickname = "local"',
	'host = "127.0.0.1:3000"',
	'protocol = "http"',
}, "\n")

-- One block per source of a nickname, so the resolved host names the winner.
local PRECEDENCE_TOML = table.concat({
	'default_server = "cfgdefault"',
	"",
	"[[server_configs]]",
	'nickname = "opts"',
	'host = "opts.example.com:80"',
	'protocol = "http"',
	"",
	"[[server_configs]]",
	'nickname = "env"',
	'host = "env.example.com:80"',
	'protocol = "http"',
	"",
	"[[server_configs]]",
	'nickname = "project"',
	'host = "project.example.com:80"',
	'protocol = "http"',
	"",
	"[[server_configs]]",
	'nickname = "cfgdefault"',
	'host = "cfgdefault.example.com:80"',
	'protocol = "http"',
}, "\n")

---@param text string
---@return SpacetimeCliConfig
local function cli(text)
	return clitoml.parse(text)
end

---The (host, port, tls) triple a case is really asserting on.
---@param conn SpacetimeConnection|nil
---@return table
local function address(conn)
	if not conn then
		return { host = nil, port = nil, tls = nil }
	end
	return { host = conn.host, port = conn.port, tls = conn.tls }
end

---@param haystack string|nil
---@param needle string
---@return boolean
local function contains(haystack, needle)
	return type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- split_host_port
-- ---------------------------------------------------------------------------

T["an address with a port keeps that port"] = function()
	expect.equality({ config.split_host_port("127.0.0.1:3000", 80) }, { "127.0.0.1", 3000 })
end

T["an address without a port takes the protocol default, not 3000"] = function()
	expect.equality({ config.split_host_port("example.com", 443) }, { "example.com", 443 })
	expect.equality({ config.split_host_port("example.com", 80) }, { "example.com", 80 })
end

T["an explicit port overrides the protocol default"] = function()
	expect.equality({ config.split_host_port("example.com:8443", 443) }, { "example.com", 8443 })
end

T["a bracketed IPv6 address keeps its brackets and reads its port"] = function()
	expect.equality({ config.split_host_port("[::1]:3000", 80) }, { "[::1]", 3000 })
end

T["a bracketed IPv6 address with no port takes the default"] = function()
	expect.equality({ config.split_host_port("[::1]", 443) }, { "[::1]", 443 })
end

T["a non-numeric port tail leaves the whole string as the host"] = function()
	expect.equality({ config.split_host_port("host:abc", 80) }, { "host:abc", 80 })
end

T["an out-of-range port tail leaves the whole string as the host"] = function()
	expect.equality({ config.split_host_port("host:99999", 80) }, { "host:99999", 80 })
end

-- ---------------------------------------------------------------------------
-- cli_config_path
-- ---------------------------------------------------------------------------

T["XDG_CONFIG_HOME wins when it is set"] = function()
	local env = { XDG_CONFIG_HOME = "/custom/xdg", HOME = "/home/alice" }
	expect.equality(config.cli_config_path(env), "/custom/xdg/spacetime/cli.toml")
end

T["an absent or empty XDG_CONFIG_HOME falls back to ~/.config, never ~/Library"] = function()
	-- The whole point of this resolver: the SpacetimeDB CLI uses the XDG path on
	-- macOS too, so an OS-specific config directory would silently miss the file.
	expect.equality(config.cli_config_path({ HOME = "/home/alice" }), "/home/alice/.config/spacetime/cli.toml")
	expect.equality(
		config.cli_config_path({ XDG_CONFIG_HOME = "", HOME = "/home/alice" }),
		"/home/alice/.config/spacetime/cli.toml"
	)
end

T["neither XDG_CONFIG_HOME nor HOME yields no path at all"] = function()
	expect.equality(config.cli_config_path({}), nil)
end

-- ---------------------------------------------------------------------------
-- resolve: address
-- ---------------------------------------------------------------------------

T["the cli.toml default server is used when nothing else is given"] = function()
	local conn = config.resolve(nil, nil, nil, cli(CLI_TOML))
	expect.equality(address(conn), { host = "maincloud.spacetimedb.com", port = 443, tls = true })
end

T["an explicit localhost:3000 beats a maincloud default"] = function()
	-- The regression this rule exists for: passing the dev defaults by hand must
	-- reach a local server, not be swallowed by the config's default_server.
	local conn = config.resolve({ host = "localhost", port = 3000 }, nil, nil, cli(CLI_TOML))
	expect.equality(address(conn), { host = "localhost", port = 3000, tls = false })
end

T["a host on its own ignores the config's port"] = function()
	local conn = config.resolve({ host = "10.0.0.5" }, nil, nil, cli(CLI_TOML))
	expect.equality(address(conn), { host = "10.0.0.5", port = 3000, tls = false })
end

T["tls on its own counts as an explicit address"] = function()
	local conn = config.resolve({ tls = true }, nil, nil, cli(CLI_TOML))
	expect.equality(address(conn), { host = "localhost", port = 3000, tls = true })
end

T["nothing anywhere resolves to localhost:3000 without tls"] = function()
	local conn = config.resolve()
	expect.equality(address(conn), { host = "localhost", port = 3000, tls = false })
end

T["a nickname selects a server other than the default"] = function()
	local conn = config.resolve({ server = "local" }, nil, nil, cli(CLI_TOML))
	expect.equality(address(conn), { host = "127.0.0.1", port = 3000, tls = false })
end

T["an unknown nickname is an error naming it and the available servers"] = function()
	local conn, err = config.resolve({ server = "nope" }, nil, nil, cli(CLI_TOML))
	expect.equality(conn, nil)
	expect.equality(contains(err, "nope"), true)
	expect.equality(contains(err, "maincloud, local"), true)
end

T["an unknown nickname with no servers configured says so"] = function()
	local _, err = config.resolve({ server = "nope" }, nil, nil, cli(""))
	expect.equality(contains(err, "(none configured)"), true)
end

T["a nickname with no cli config at all is an error"] = function()
	local conn, err = config.resolve({ server = "local" })
	expect.equality(conn, nil)
	expect.equality(contains(err, "no SpacetimeDB CLI config"), true)
	expect.equality(contains(err, "~/.config/spacetime/cli.toml"), true)
end

T["an absent default_server falls back to the local nickname"] = function()
	local conn = config.resolve(
		nil,
		nil,
		nil,
		cli(table.concat({
			"[[server_configs]]",
			'nickname = "local"',
			'host = "127.0.0.1:3000"',
			'protocol = "http"',
		}, "\n"))
	)
	expect.equality(address(conn), { host = "127.0.0.1", port = 3000, tls = false })
end

T["a default_server naming a missing block falls back to localhost, keeping the token"] = function()
	-- Unlike a bad nickname, a stale default_server is the CLI's own business and
	-- must not stop us connecting locally — but its token is still ours to use.
	local conn = config.resolve(
		nil,
		nil,
		nil,
		cli(table.concat({
			'default_server = "missing"',
			'spacetimedb_token = "cfg-tok"',
			"",
			"[[server_configs]]",
			'nickname = "local"',
			'host = "127.0.0.1:3000"',
			'protocol = "http"',
		}, "\n"))
	)
	expect.equality(address(conn), { host = "localhost", port = 3000, tls = false })
	expect.equality(conn and conn.token, "cfg-tok")
end

T["an empty host is an error"] = function()
	local conn, err = config.resolve({ host = "   " })
	expect.equality(conn, nil)
	expect.equality(err, "host must not be empty")
end

T["a zero port is an error"] = function()
	local conn, err = config.resolve({ host = "localhost", port = 0 })
	expect.equality(conn, nil)
	expect.equality(err, "port must be a non-zero port number")
end

T["an out-of-range port is an error"] = function()
	local _, err = config.resolve({ port = 99999 })
	expect.equality(err, "port must be a non-zero port number")
end

T["a numeric SPACETIMEDB_PORT is coerced, a junk one is treated as unset"] = function()
	expect.equality(address(config.resolve(nil, { SPACETIMEDB_PORT = "8080" })).port, 8080)
	expect.equality(address(config.resolve(nil, { SPACETIMEDB_PORT = "not-a-port" })).port, 3000)
end

T["the url carries the scheme and always an explicit port"] = function()
	expect.equality(config.resolve({ host = "example.com", port = 443, tls = true }).url, "https://example.com:443")
	expect.equality(config.resolve({ host = "example.com", port = 80 }).url, "http://example.com:80")
end

-- ---------------------------------------------------------------------------
-- resolve: precedence, between every adjacent pair
-- ---------------------------------------------------------------------------

T["a server from opts beats one from the environment"] = function()
	local conn = config.resolve({ server = "opts" }, { SPACETIMEDB_SERVER = "env" }, nil, cli(PRECEDENCE_TOML))
	expect.equality(conn.host, "opts.example.com")
	expect.equality(conn.server, "opts")
end

T["a server from the environment beats one from the project file"] = function()
	local conn = config.resolve(nil, { SPACETIMEDB_SERVER = "env" }, { server = "project" }, cli(PRECEDENCE_TOML))
	expect.equality(conn.host, "env.example.com")
end

T["a server from the project file beats cli.toml's default_server"] = function()
	local conn = config.resolve(nil, nil, { server = "project" }, cli(PRECEDENCE_TOML))
	expect.equality(conn.host, "project.example.com")
end

T["an unknown nickname from the project file is still a hard error"] = function()
	-- A malformed project file falls through, but one naming a server we cannot
	-- resolve must not quietly connect somewhere else instead.
	local conn, err = config.resolve(nil, nil, { server = "ghost" }, cli(PRECEDENCE_TOML))
	expect.equality(conn, nil)
	expect.equality(contains(err, "ghost"), true)
end

T["a database from opts beats one from the environment"] = function()
	local conn = config.resolve({ database = "from-opts" }, { SPACETIMEDB_DATABASE = "from-env" })
	expect.equality(conn.database, "from-opts")
end

T["a database from the environment beats one from the project file"] = function()
	local conn = config.resolve(nil, { SPACETIMEDB_DATABASE = "from-env" }, { database = "from-project" })
	expect.equality(conn.database, "from-env")
end

T["a database from the project file is used when nothing higher supplies one"] = function()
	local conn = config.resolve(nil, nil, { database = "from-project" })
	expect.equality(conn.database, "from-project")
end

T["a token from opts beats the environment, which beats cli.toml"] = function()
	local cfg = cli(CLI_TOML)
	local env = { SPACETIMEDB_TOKEN = "env-tok" }
	expect.equality(config.resolve({ token = "opts-tok" }, env, nil, cfg).token, "opts-tok")
	expect.equality(config.resolve(nil, env, nil, cfg).token, "env-tok")
	expect.equality(config.resolve(nil, nil, nil, cfg).token, "cfg-tok")
end

-- ---------------------------------------------------------------------------
-- Layout options
-- ---------------------------------------------------------------------------

T["both layout options are optional"] = function()
	expect.no_error(function()
		config.validate_layout({})
	end)
end

T["either side is accepted"] = function()
	expect.no_error(function()
		config.validate_layout({ side = "left" })
		config.validate_layout({ side = "right" })
	end)
end

T["an unknown side is rejected"] = function()
	expect.error(function()
		---@diagnostic disable-next-line: assign-type-mismatch
		config.validate_layout({ side = "middle" })
	end, "side")
end

T["a column count and a percentage are both accepted widths"] = function()
	expect.no_error(function()
		config.validate_layout({ width = 30 })
		config.validate_layout({ width = "20%" })
		config.validate_layout({ width = "100%" })
	end)
end

T["a non-positive width is rejected"] = function()
	expect.error(function()
		config.validate_layout({ width = 0 })
	end, "width")
	expect.error(function()
		config.validate_layout({ width = -10 })
	end, "width")
end

T["a malformed percentage is rejected"] = function()
	-- No `%`, a percentage of nothing, one over 100, and a bare unit — each is a
	-- plausible typo, and none of them may quietly become a column count.
	for _, bad in ipairs({ "20", "0%", "120%", "20 %", "%", "20%%", "twenty%" }) do
		expect.error(function()
			config.validate_layout({ width = bad })
		end, "width")
	end
end

T["a width in columns is used as given"] = function()
	expect.equality(config.sidebar_columns(30, 200), 30)
end

T["a percentage width resolves against the columns available"] = function()
	expect.equality(config.sidebar_columns("20%", 200), 40)
	expect.equality(config.sidebar_columns("25%", 81), 20) -- rounds down
end

T["a width is clamped to the minimum, never to zero"] = function()
	-- A tiny terminal is the case that matters: 5% of 40 columns is 2, and a
	-- window that narrow (or, one rounding away, 0) is unusable.
	expect.equality(config.sidebar_columns("5%", 40), config.MIN_SIDEBAR_WIDTH)
	expect.equality(config.sidebar_columns(1, 200), config.MIN_SIDEBAR_WIDTH)
end

T["a width wider than the screen leaves a column for the content window"] = function()
	expect.equality(config.sidebar_columns("100%", 200), 199)
	expect.equality(config.sidebar_columns(500, 200), 199)
end

-- ---------------------------------------------------------------------------
-- Project discovery, against real directory trees
-- ---------------------------------------------------------------------------

local root

---@param path string
---@param text string
local function write(path, text)
	local file = assert(io.open(path, "w"))
	file:write(text)
	file:close()
end

local T_project = MiniTest.new_set({
	hooks = {
		pre_case = function()
			local dir = vim.fs.normalize(vim.fn.tempname())
			vim.fn.mkdir(dir, "p")
			-- Resolve symlinks up front: on macOS the temp directory lives under
			-- `/tmp`, which is a link to `/private/tmp`, and a buffer name comes
			-- back already resolved. Comparing the two forms would fail on the
			-- prefix rather than on anything this module does.
			root = vim.fs.normalize(vim.uv.fs_realpath(dir) or dir)
		end,
		post_case = function()
			vim.fn.delete(root, "rf")
		end,
	},
})
T["project files"] = T_project

T_project["the local file wins per key and the base file fills the rest"] = function()
	write(root .. "/spacetime.json", '{"server":"base-srv","database":"base-db"}')
	write(root .. "/spacetime.local.json", '{"database":"local-db"}')
	expect.equality(config.read_project_config(root), { server = "base-srv", database = "local-db" })
end

T_project["the local file alone supplies the config"] = function()
	write(root .. "/spacetime.local.json", '{"server":"local-srv","database":"local-db"}')
	expect.equality(config.read_project_config(root), { server = "local-srv", database = "local-db" })
end

T_project["the base file alone supplies the config"] = function()
	-- spacetime.local.json is .gitignore'd in most real repos, so absent is the
	-- normal case rather than an exception.
	write(root .. "/spacetime.json", '{"server":"base-srv"}')
	expect.equality(config.read_project_config(root), { server = "base-srv" })
end

T_project["neither file present contributes nothing"] = function()
	expect.equality(config.read_project_config(root), nil)
end

T_project["malformed JSON in the local file leaves the base file in use"] = function()
	write(root .. "/spacetime.json", '{"server":"base-srv"}')
	write(root .. "/spacetime.local.json", "{ this is not json")
	expect.equality(config.read_project_config(root), { server = "base-srv" })
end

T_project["malformed JSON in both files contributes nothing"] = function()
	write(root .. "/spacetime.json", "{ nope")
	write(root .. "/spacetime.local.json", "also nope")
	expect.equality(config.read_project_config(root), nil)
end

T_project["a top-level array or null is ignored"] = function()
	write(root .. "/spacetime.json", '["server","database"]')
	write(root .. "/spacetime.local.json", "null")
	expect.equality(config.read_project_config(root), nil)
end

T_project["the CLI's own build keys never reach the result"] = function()
	write(
		root .. "/spacetime.json",
		'{"server":"base-srv","module-path":"server","generate":[{"lang":"rust"}],"dev":{"run":"x"}}'
	)
	expect.equality(config.read_project_config(root), { server = "base-srv" })
end

T_project["a non-string server is ignored"] = function()
	write(root .. "/spacetime.json", '{"server":42,"database":"base-db"}')
	expect.equality(config.read_project_config(root), { database = "base-db" })
end

-- ---------------------------------------------------------------------------
-- VCS root discovery
-- ---------------------------------------------------------------------------

T_project[".git as a regular file resolves as the root"] = function()
	-- Worktrees and submodules write a `gitdir:` pointer file, so anything that
	-- tests for a *directory* walks straight past a perfectly good repo.
	write(root .. "/.git", "gitdir: /elsewhere/.git/worktrees/wt\n")
	expect.equality(config.find_vcs_root(root), root)
end

T_project[".git as a directory resolves as the root"] = function()
	vim.fn.mkdir(root .. "/.git", "p")
	expect.equality(config.find_vcs_root(root), root)
end

T_project[".jj on its own resolves as the root"] = function()
	vim.fn.mkdir(root .. "/.jj", "p")
	expect.equality(config.find_vcs_root(root), root)
end

T_project["a colocated .jj and .git resolve to that one level"] = function()
	vim.fn.mkdir(root .. "/.jj", "p")
	vim.fn.mkdir(root .. "/.git", "p")
	expect.equality(config.find_vcs_root(root), root)
end

T_project["a nested subdirectory walks up to the root"] = function()
	vim.fn.mkdir(root .. "/.jj", "p")
	vim.fn.mkdir(root .. "/a/b/c", "p")
	expect.equality(config.find_vcs_root(root .. "/a/b/c"), root)
end

T_project["a spacetime.json below the root is ignored"] = function()
	vim.fn.mkdir(root .. "/.jj", "p")
	vim.fn.mkdir(root .. "/sub", "p")
	write(root .. "/sub/spacetime.json", '{"database":"sub-db"}')
	expect.equality(config.read_project_config(config.find_vcs_root(root .. "/sub")), nil)
end

T_project["a tree with no marker terminates and finds nothing"] = function()
	vim.fn.mkdir(root .. "/a/b", "p")
	expect.equality(config.find_vcs_root(root .. "/a/b"), nil)
end

-- ---------------------------------------------------------------------------
-- start_dir
-- ---------------------------------------------------------------------------

T_project["an unnamed buffer falls back to the working directory"] = function()
	local bufnr = vim.api.nvim_create_buf(false, true)
	expect.equality(config.start_dir(bufnr), vim.fs.normalize(vim.fn.getcwd()))
	vim.api.nvim_buf_delete(bufnr, { force = true })
end

T_project["a named buffer yields its own directory"] = function()
	vim.fn.mkdir(root .. "/sub", "p")
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, root .. "/sub/file.lua")
	expect.equality(config.start_dir(bufnr), root .. "/sub")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end

T_project["a URI-named buffer falls back to the working directory"] = function()
	-- Our own `spacetime://` buffers have no directory of their own.
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, "spacetime://database/table")
	expect.equality(config.start_dir(bufnr), vim.fs.normalize(vim.fn.getcwd()))
	vim.api.nvim_buf_delete(bufnr, { force = true })
end

return T
