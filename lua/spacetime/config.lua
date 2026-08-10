-- Which server, database and token does a given buffer mean?
--
-- Five sources answer that, and the whole point of this module is that they are
-- consulted in one fixed order (highest first):
--
--     :SpacetimeConnect > setup() opts > env > spacetime.local.json >
--     spacetime.json > cli.toml
--
-- Only the first of those is an *action* rather than a configuration, which is
-- why it sits on top: a user who typed `:SpacetimeConnect maincloud` a moment
-- ago has said something more recent than any file did. See `select_server`.
--
-- The two halves are deliberately separated. `resolve()` is **pure** — options,
-- environment, project config and cli.toml in, a connection out — so every
-- precedence rule is testable without a filesystem, a `$HOME`, or a real token.
-- The discovery half (`start_dir`, `find_vcs_root`, `read_project_config`) is the
-- only part that touches the world, and it is the reason this module sits in
-- `lua/spacetime/` rather than `lua/spacetime/lib/`: it needs `vim.fn`, `vim.uv`
-- and `vim.fs`.
--
-- Two rules here are load-bearing and easy to get wrong:
--
-- * **A port default of 443/80 comes from the protocol, not from 3000.** 3000 is
--   the local-server default and only applies when the *user* named a host by
--   hand; a cli.toml entry of `maincloud.spacetimedb.com` over https means 443.
-- * **Any explicit host/port/tls suppresses cli.toml and the project file
--   entirely**, even when the values equal the defaults — so `host = "localhost",
--   port = 3000` reaches a local server rather than being silently replaced by
--   the config's `default_server`.
--
-- An unknown *nickname*, by contrast, is a hard error whatever supplied it —
-- including `spacetime.json`. "A malformed project file is not an error" covers
-- an absent or unparseable file (we fall through); a file that names a server we
-- cannot resolve must not quietly connect somewhere else instead.
--
-- The resolution rules are ported from the SpacetimeDB TUI's `src/config.rs`,
-- whose tests are the specification; see ROADMAP.md, task 8.
--
-- The file has a second, much smaller job at the bottom: validating the two
-- *layout* options `setup()` accepts (`side` and `width`) and turning a width
-- into a column count. They live here, beside the connection options, so that
-- every `setup()` option is validated in one place — and both functions are
-- pure, so `ui/buffer.lua` gets its clamping rules tested without a window.

---Connection options as accepted from `setup()`, i.e. `require("spacetime").config`.
---@class SpacetimeConnectionOpts
---@field host? string Hostname only; a port here is not parsed out.
---@field port? integer
---@field tls? boolean Only `true` counts as a choice; `false` reads as "unset".
---@field server? string A cli.toml `nickname`, not a hostname.
---@field database? string
---@field token? string

---The subset of `spacetime.json` / `spacetime.local.json` that concerns us.
---`module-path`, `generate` and `dev` belong to the CLI's build flow.
---@class SpacetimeProjectConfig
---@field server? string A cli.toml nickname, resolved *through* the chain.
---@field database? string

---A fully resolved connection: everything the HTTP layer needs.
---@class SpacetimeConnection
---@field host string
---@field port integer
---@field tls boolean
---@field url string Base URL, always with an explicit port, e.g. `https://maincloud.spacetimedb.com:443`.
---@field server? string The nickname that was asked for, if any.
---@field database? string
---@field token? string

---How `:Spacetime` arranges its two windows, as accepted from `setup()`.
---@class SpacetimeLayoutOpts
---@field side? "left"|"right" Which side of the tabpage the sidebar takes.
---@field width? integer|string Columns (`30`), or a percentage of the screen (`"20%"`).

---A cli.toml `[[server_configs]]` block with its address split out.
---@class SpacetimeResolvedServer
---@field nickname string
---@field host string
---@field port integer
---@field tls boolean

local M = {}

-- Where the SpacetimeDB CLI keeps its config on *every* platform, used only in
-- the "no config to resolve against" error message.
local DEFAULT_CLI_CONFIG_PATH = "~/.config/spacetime/cli.toml"

-- The local-server defaults, which apply only once a host, port or TLS flag has
-- been given by hand.
local DEFAULT_HOST = "localhost"
local DEFAULT_PORT = 3000

-- The nickname the CLI itself falls back to when `cli.toml` has no
-- `default_server` key.
local FALLBACK_NICKNAME = "local"

-- The project files, in overlay order: later files win key by key.
local PROJECT_FILES = { "spacetime.json", "spacetime.local.json" }

---Split `"host:port"`, defaulting the port when the address carries none.
---
---A bracketed IPv6 literal keeps its brackets (`"[::1]:3000"` → `"[::1]"`, 3000)
---because that is the form a URL needs. Everything else splits on the **last**
---colon, so an unbracketed IPv6 literal still yields something usable. A tail
---that is not a plausible port is not an error: the whole string becomes the
---host, so `"host:99999"` is a hostname rather than a bad port.
---@param addr string
---@param default_port integer Used when the address has no usable `:port` tail.
---@return string host
---@return integer port
function M.split_host_port(addr, default_port)
	---@param text string
	---@return integer|nil
	local function port_of(text)
		local digits = text:match("^(%d+)$")
		local port = digits and tonumber(digits)
		if port and port >= 1 and port <= 65535 then
			return math.floor(port)
		end
		return nil
	end

	if addr:sub(1, 1) == "[" then
		local close = addr:find("]", 1, true)
		if close then
			-- The brackets belong to the host; only a `:NNN` tail after them is a port.
			local host = addr:sub(1, close)
			local rest = addr:sub(close + 1)
			local port = rest:sub(1, 1) == ":" and port_of(rest:sub(2)) or nil
			return host, port or default_port
		end
	end

	local host, tail = addr:match("^(.*):([^:]*)$")
	if host then
		local port = port_of(tail)
		if port then
			return host, port
		end
	end
	return addr, default_port
end

---Locate the SpacetimeDB CLI's `cli.toml`.
---
---The CLI stores it under `~/.config/spacetime/` on **every** platform, honouring
---`XDG_CONFIG_HOME` — in particular it does *not* use macOS's
---`~/Library/Application Support`, so the path must never be derived from an
---OS-specific config-directory helper. `env` is injected so tests never read the
---real environment, and read by key only.
---@param env? table Defaults to `vim.env`.
---@return string|nil # `nil` when neither `XDG_CONFIG_HOME` nor `HOME` is usable.
function M.cli_config_path(env)
	env = env or vim.env

	local xdg = env.XDG_CONFIG_HOME
	local base
	if type(xdg) == "string" and xdg ~= "" then
		base = xdg
	else
		local home = env.HOME
		if type(home) ~= "string" or home == "" then
			return nil
		end
		base = home .. "/.config"
	end

	return base .. "/spacetime/cli.toml"
end

---Resolve every usable `[[server_configs]]` block to a concrete address.
---Blocks missing a nickname or a host are skipped: they can never be selected.
---@param cli_cfg SpacetimeCliConfig
---@return SpacetimeResolvedServer[]
local function resolved_servers(cli_cfg)
	local servers = {}
	for _, block in ipairs(cli_cfg.server_configs or {}) do
		if block.nickname and block.host then
			-- The protocol supplies the default port: 443 for https, 80 for http.
			-- Not 3000 — that is the local-server default, not a fallback.
			local tls = block.protocol == "https"
			local host, port = M.split_host_port(block.host, tls and 443 or 80)
			servers[#servers + 1] = { nickname = block.nickname, host = host, port = port, tls = tls }
		end
	end
	return servers
end

---@param servers SpacetimeResolvedServer[]
---@param nickname string
---@return SpacetimeResolvedServer|nil
local function find_server(servers, nickname)
	for _, server in ipairs(servers) do
		if server.nickname == nickname then
			return server
		end
	end
	return nil
end

---Resolve a connection from the four sources. Pure: it reads nothing but its
---arguments, so the precedence rules are testable in isolation.
---
---Address resolution, highest first:
---
---1. an explicit `host`/`port`/`tls`, which ignores cli.toml and the project file
---   entirely — even when the values equal the defaults;
---2. a nickname (from opts, env or the project file) looked up in cli.toml, where
---   *not found* is a hard error rather than a silent fallback;
---3. cli.toml's `default_server`, or the conventional `"local"` when that key is
---   absent — a `default_server` naming a missing block is not an error;
---4. `localhost:3000` without TLS.
---@param opts? SpacetimeConnectionOpts From `setup()`; highest precedence.
---@param env? table Read by key: `SPACETIMEDB_HOST`, `_PORT`, `_SERVER`, `_DATABASE`, `_TOKEN`.
---@param project_cfg? SpacetimeProjectConfig From `spacetime.json` / `spacetime.local.json`.
---@param cli_cfg? SpacetimeCliConfig `nil` means "no CLI config was found at all".
---@return SpacetimeConnection|nil # `nil` on error.
---@return string|nil # The error message, when the connection is `nil`.
function M.resolve(opts, env, project_cfg, cli_cfg)
	opts = opts or {}
	env = env or {}
	project_cfg = project_cfg or {}

	local host = opts.host or env.SPACETIMEDB_HOST

	-- An env port is a string, and one that is not all digits is treated as
	-- unset rather than as an error: the environment is ambient, so a stray value
	-- there should not stop the plugin loading. An explicit `opts.port` is a
	-- choice, and a bad one is reported below.
	local port = opts.port
	if port == nil and type(env.SPACETIMEDB_PORT) == "string" and env.SPACETIMEDB_PORT:match("^%d+$") then
		port = tonumber(env.SPACETIMEDB_PORT)
	end

	-- `tls` is a flag, so `false` is indistinguishable from unset; only `true`
	-- counts as the user having chosen a server by hand. There is no env var for
	-- it, and the project file never carries one.
	local tls = opts.tls == true

	local nickname = opts.server or env.SPACETIMEDB_SERVER or project_cfg.server
	local database = opts.database or env.SPACETIMEDB_DATABASE or project_cfg.database
	local token = opts.token or env.SPACETIMEDB_TOKEN or (cli_cfg and cli_cfg.spacetimedb_token)

	if host ~= nil or port ~= nil or tls then
		host, port = host or DEFAULT_HOST, port or DEFAULT_PORT
	elseif nickname then
		if not cli_cfg then
			local path = M.cli_config_path(env) or DEFAULT_CLI_CONFIG_PATH
			local message = 'server "%s" was given, but no SpacetimeDB CLI config (%s) was found to resolve it against'
			return nil, message:format(nickname, path)
		end

		local servers = resolved_servers(cli_cfg)
		local server = find_server(servers, nickname)
		if not server then
			local names = vim.tbl_map(function(s)
				return s.nickname
			end, servers)
			local listed = #names > 0 and table.concat(names, ", ") or "(none configured)"
			return nil, ('server "%s" not found in cli.toml; available servers: %s'):format(nickname, listed)
		end
		host, port, tls = server.host, server.port, server.tls
	else
		-- A `default_server` naming a block that is not there is not an error —
		-- the CLI itself just falls through — but the token is still resolved.
		local server = cli_cfg and find_server(resolved_servers(cli_cfg), cli_cfg.default_server or FALLBACK_NICKNAME)
		if server then
			host, port, tls = server.host, server.port, server.tls
		else
			host, port = DEFAULT_HOST, DEFAULT_PORT
		end
	end

	if type(host) ~= "string" or host:match("^%s*$") then
		return nil, "host must not be empty"
	end
	if type(port) ~= "number" or port ~= math.floor(port) or port < 1 or port > 65535 then
		return nil, "port must be a non-zero port number"
	end

	-- The port is always explicit in the URL: it costs nothing and it makes the
	-- resolved connection self-describing in `:SpacetimeStatus` and in logs.
	local url = ("%s://%s:%d"):format(tls and "https" or "http", host, port)
	return {
		host = host,
		port = math.floor(port),
		tls = tls,
		url = url,
		server = nickname,
		database = database,
		token = token,
	}
end

---The directory to start the VCS-root walk from.
---
---A buffer with no file — and one whose name is a URI, which includes our own
---`spacetime://` buffers — has no directory of its own, so the working directory
---stands in for it.
---@param bufnr? integer Defaults to the current buffer.
---@return string
function M.start_dir(bufnr)
	local cwd = vim.fs.normalize(vim.fn.getcwd())

	local name = vim.api.nvim_buf_get_name(bufnr or 0)
	if name == "" or name:match("^%a[%w+.-]*://") then
		return cwd
	end

	local dir = vim.fs.dirname(vim.fn.fnamemodify(name, ":p"))
	if not dir or dir == "" then
		return cwd
	end
	return vim.fs.normalize(dir)
end

---Walk up from `dir` to the nearest directory holding a `.jj` or a `.git`.
---
---**Existence is the test, never directory-ness**: `.git` is a regular *file* in
---worktrees and submodules, and a `stat.type == "directory"` check would walk
---straight past those. The first hit wins, so a colocated jj repo (which has
---both markers) resolves at one level rather than twice.
---@param dir string
---@return string|nil # `nil` when the walk reaches the filesystem root unmatched.
function M.find_vcs_root(dir)
	local current = vim.fs.normalize(dir)
	while true do
		if vim.uv.fs_stat(current .. "/.jj") or vim.uv.fs_stat(current .. "/.git") then
			return current
		end
		-- At the filesystem root `dirname` returns its argument, which is what
		-- guarantees this loop terminates.
		local parent = vim.fs.dirname(current)
		if not parent or parent == current then
			return nil
		end
		current = parent
	end
end

---@param path string
---@return string|nil
local function read_file(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local text = file:read("*a")
	file:close()
	return text
end

---Read one project file and keep only the two keys that concern us.
---Anything unreadable, unparseable or of the wrong shape contributes nothing —
---never an error, never a notification.
---@param path string
---@return SpacetimeProjectConfig|nil
local function read_project_file(path)
	local text = read_file(path)
	if not text then
		return nil
	end

	local ok, decoded = pcall(require("spacetime.lib.json").decode, text)
	-- A JSON array decodes to a table too, but it has no `server` key, so it
	-- falls out below rather than needing a check of its own. `vim.NIL` (from a
	-- top-level `null`) is a userdata and fails the type test.
	if not ok or type(decoded) ~= "table" then
		return nil
	end

	local out = {}
	if type(decoded.server) == "string" then
		out.server = decoded.server
	end
	if type(decoded.database) == "string" then
		out.database = decoded.database
	end
	return out
end

---Read `spacetime.json` from `root`, then overlay `spacetime.local.json` on top
---of it key by key — the local file is `.gitignore`d in most real repos, so it
---is usually absent and its absence is entirely normal.
---@param root string
---@return SpacetimeProjectConfig|nil # `nil` when neither file contributed anything.
function M.read_project_config(root)
	local out = {}
	for _, name in ipairs(PROJECT_FILES) do
		local fields = read_project_file(root .. "/" .. name)
		if fields then
			out.server = fields.server or out.server
			out.database = fields.database or out.database
		end
	end

	if out.server == nil and out.database == nil then
		return nil
	end
	return out
end

---The project config governing `bufnr`, if its repo has one.
---@param bufnr? integer Defaults to the current buffer.
---@return SpacetimeProjectConfig|nil
function M.project_config(bufnr)
	local root = M.find_vcs_root(M.start_dir(bufnr))
	if not root then
		return nil
	end
	return M.read_project_config(root)
end

---Below this a sidebar shows nothing useful, and it is also the guard that stops
---a percentage of a narrow terminal rounding down to zero columns.
M.MIN_SIDEBAR_WIDTH = 10

---Is this a usable sidebar width — a positive column count, or `"N%"` with N in
---1..100?
---@param width any
---@return boolean
local function valid_width(width)
	if type(width) == "number" then
		return width > 0
	end
	if type(width) == "string" then
		local pct = tonumber(width:match("^(%d+)%%$"))
		return pct ~= nil and pct > 0 and pct <= 100
	end
	return false
end

---Validate the layout half of `setup()`'s options.
---
---Raises through `vim.validate`, exactly as the rest of `setup()` does, so a
---misconfigured layout fails at `setup()` time rather than the first time
---`:Spacetime` tries to build a window out of it. Both fields are optional.
---@param opts SpacetimeLayoutOpts
function M.validate_layout(opts)
	vim.validate("side", opts.side, function(side)
		return side == "left" or side == "right"
	end, true, '"left" or "right"')
	vim.validate("width", opts.width, valid_width, true, 'a positive number of columns or a percentage such as "20%"')
end

---Resolve a configured width to a concrete column count.
---
---Pure: the total is passed in (`vim.o.columns` at the call site) rather than
---read, so the clamping is testable without a UI. The clamp is the point — a
---percentage of a narrow terminal rounds towards zero, and a 0-width window is
---one the user can neither see nor close.
---@param width integer|string A column count, or a percentage such as `"20%"`.
---@param total integer The columns available, i.e. `vim.o.columns`.
---@return integer
function M.sidebar_columns(width, total)
	local columns
	if type(width) == "string" then
		local pct = tonumber(width:match("^(%d+)%%$")) or 0
		columns = math.floor(total * pct / 100)
	else
		columns = math.floor(width)
	end

	-- Leave at least one column for the content window, but never drop below the
	-- floor: on a terminal too narrow for both, Neovim's own minimums decide.
	return math.max(math.min(columns, total - 1), M.MIN_SIDEBAR_WIDTH)
end

--------------------------------------------------------------------------------
-- The session's own choice of server
--------------------------------------------------------------------------------

-- The nickname `:SpacetimeConnect` selected, for the rest of the session.
--
-- Not stored in `require("spacetime").config` with the rest: that table is what
-- `setup()` was given, and a command must not rewrite the user's configuration
-- behind their back. This is a session fact, and it dies with the session.
local session_server = nil ---@type string|nil

---The nickname |:SpacetimeConnect| selected, or `nil` when none has been.
---@return string|nil
function M.selected_server()
	return session_server
end

---Fold the session's choice into the sources `resolve` reads.
---
---A named server has to beat *every* address source, `setup()` and the
---environment alike — point 1 of `resolve` gives an explicit `host`/`port`/`tls`
---outright victory, so leaving either in place would let a `SPACETIMEDB_HOST` in
---the user's shell silently win and make the command look broken. What survives
---is what a nickname says nothing about: the database and the token.
---
---The project config is passed through untouched, because its `server` loses to
---`opts.server` in `resolve` already, while its `database` is still the right
---answer to "which database does this repository mean".
---@param opts SpacetimeConnectionOpts
---@param env table
---@return SpacetimeConnectionOpts opts
---@return table env
local function with_session_server(opts, env)
	if session_server == nil then
		return opts, env
	end
	return {
		server = session_server,
		database = opts.database,
		token = opts.token,
	}, {
		SPACETIMEDB_DATABASE = env.SPACETIMEDB_DATABASE,
		SPACETIMEDB_TOKEN = env.SPACETIMEDB_TOKEN,
	}
end

---The connection for `bufnr`: `resolve()` fed from the real environment, the
---buffer's project config and the user's `cli.toml`.
---@param bufnr? integer Defaults to the current buffer.
---@return SpacetimeConnection|nil
---@return string|nil # The error message, when the connection is `nil`.
function M.current(bufnr)
	local path = M.cli_config_path(vim.env)
	local cli_cfg = path and require("spacetime.lib.clitoml").read(path) or { server_configs = {} }
	local opts = require("spacetime").config --[[@as SpacetimeConnectionOpts]]
	-- Bound to locals rather than passed inline: a multi-return expands only in
	-- the last argument position, and these are the first two of four.
	local session_opts, session_env = with_session_server(opts, vim.env)
	return M.resolve(session_opts, session_env, M.project_config(bufnr), cli_cfg)
end

---Select `nickname` for the rest of the session. What |:SpacetimeConnect| does.
---
---Validated by trying it: the nickname is applied, the connection re-resolved,
---and the previous selection put back if that failed. Two things fall out of
---doing it that way rather than by looking the nickname up here. The message is
---`resolve`'s own, so an unknown nickname is reported in one wording with one
---list of the nicknames that do exist, wherever the complaint comes from — and a
---typo can never disconnect you, because the selection only changes when the new
---one resolves.
---@param nickname string A `cli.toml` `[[server_configs]]` nickname.
---@param bufnr? integer Buffer whose project config the check resolves against.
---@return SpacetimeConnection|nil connection
---@return string|nil err
function M.select_server(nickname, bufnr)
	local previous = session_server
	session_server = nickname

	local connection, err = M.current(bufnr)
	if not connection then
		session_server = previous
	end
	return connection, err
end

---Forget the session's choice, back to what the configuration resolves to.
---What |:SpacetimeConnect!| does.
---@return boolean cleared `false` when nothing was selected in the first place.
function M.clear_server()
	local had = session_server ~= nil
	session_server = nil
	return had
end

return M
