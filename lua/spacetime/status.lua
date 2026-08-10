-- `:SpacetimeStatus` — the resolved connection, in five lines.
--
-- This is the plugin's diagnostic front door: run it, paste the output into a
-- bug report. Everything it prints is therefore chosen to be *safe to paste*.
--
-- **The bearer token never appears in the output.** The `token` line is the
-- literal string `present` or `absent` and nothing else — not a prefix, not a
-- length, not a fingerprint. That is a hard rule rather than a nicety: a token
-- pasted into an issue is a live credential for the account. `tests/test_status.lua`
-- pins it by asserting the token string appears nowhere in the captured output.
--
-- Note what is *not* done here: the assembled lines are deliberately not passed
-- through `logger.redact` as a safety net. Its bare-JWT rule is a three-dotted-
-- segment pattern, which a hostname can match; a redactor that mangles the
-- diagnosis is worse than none. The token simply never enters a field value.
--
-- Nothing here aborts. A config that will not resolve at all still produces
-- `cli.toml` and `project` lines, and an identity that cannot be derived puts
-- the reason on its own line — those are exactly the cases someone is running
-- this command to diagnose.
--
-- `fields()` is the single source of truth shared with `:checkhealth spacetime`,
-- so the two renderings cannot drift. The module sits in `lua/spacetime/` rather
-- than `lib/` because it reads `vim.env`, `vim.uv` and echoes through `vim.api`.

---One line of the status report.
---@class SpacetimeStatusField
---@field label string The field name, without its trailing colon.
---@field value string Already rendered, and never the bearer token.
---@field ok boolean `false` when the value is a failure message rather than an answer.

local M = {}

-- Width of the label gutter, colon included: `"server:"` padded to 13 puts every
-- value in column 15.
local LABEL_WIDTH = 13

-- The project files, in overlay order — the same pair `config.read_project_config`
-- reads, listed here so the report can name the files that actually exist.
local PROJECT_FILES = { "spacetime.json", "spacetime.local.json" }

---Where the SpacetimeDB CLI's `cli.toml` is, and whether it is really there.
---
---A missing file is not a failure: the plugin works fine on env vars alone, and
---saying so is more useful than warning about it.
---@return string
local function cli_toml_value()
	local path = require("spacetime.config").cli_config_path(vim.env)
	if not path then
		return "none (neither XDG_CONFIG_HOME nor HOME is set)"
	end
	if not vim.uv.fs_stat(path) then
		return path .. " (not found)"
	end
	return path
end

---The project files governing `bufnr`, and the database they name.
---
---Both files are listed when both exist, `spacetime.local.json` last because it
---is the overlay that wins.
---@param bufnr integer
---@return string
local function project_value(bufnr)
	local config = require("spacetime.config")

	local root = config.find_vcs_root(config.start_dir(bufnr))
	if not root then
		return "none"
	end

	local found = {}
	for _, name in ipairs(PROJECT_FILES) do
		local path = root .. "/" .. name
		if vim.uv.fs_stat(path) then
			found[#found + 1] = path
		end
	end
	if #found == 0 then
		return "none"
	end

	local value = table.concat(found, ", ")
	local project = config.read_project_config(root)
	if project and project.database then
		value = value .. (" (database: %s)"):format(project.database)
	end
	return value
end

---The status report as label/value pairs, in the order they are printed.
---
---Shared with `spacetime.health` so the command and `:checkhealth` cannot drift.
---@param bufnr? integer Defaults to the current buffer.
---@return SpacetimeStatusField[]
function M.fields(bufnr)
	bufnr = bufnr or 0

	local fields = {}
	---@param label string
	---@param value string
	---@param ok? boolean Defaults to `true`.
	local function add(label, value, ok)
		fields[#fields + 1] = { label = label, value = value, ok = ok ~= false }
	end

	local conn, err = require("spacetime.config").current(bufnr)
	if conn then
		-- The nickname is what the user asked for; the host is the fallback when
		-- they named an address by hand. TLS needs no line of its own — the URL's
		-- scheme carries it, and the port is always explicit there.
		add("server", ("%s (%s)"):format(conn.server or conn.host, conn.url))

		local opts = require("spacetime").config --[[@as SpacetimeSetupOptions]]
		local id, id_err = require("spacetime.lib.identity").resolve(conn.token, opts.identity)
		add("identity", id or id_err or "unknown", id ~= nil)

		add("token", (type(conn.token) == "string" and conn.token ~= "") and "present" or "absent")
	else
		-- An unresolvable config (an unknown nickname, say) is precisely what this
		-- command exists to show, so the error goes on the `server` line and the
		-- two lines that depend on a connection say so plainly.
		add("server", err or "could not be resolved", false)
		add("identity", "unknown (no connection resolved)", false)
		add("token", "absent")
	end

	-- Neither of these needs a connection, so they are reported either way.
	add("cli.toml", cli_toml_value())
	add("project", project_value(bufnr))

	return fields
end

---The status report as printable lines, label gutter and all.
---@param bufnr? integer Defaults to the current buffer.
---@return string[]
function M.lines(bufnr)
	local out = {}
	for i, field in ipairs(M.fields(bufnr)) do
		out[i] = ("%-" .. LABEL_WIDTH .. "s %s"):format(field.label .. ":", field.value)
	end
	return out
end

---Print the status report.
---
---`nvim_echo` with `history = true`, deliberately: this is command output, not a
---log, so it must land in `:messages` where it can be copied out — and it must
---not go through `vim.notify`, which a notification plugin may collapse or expire.
---@param bufnr? integer Defaults to the current buffer.
function M.show(bufnr)
	vim.api.nvim_echo({ { table.concat(M.lines(bufnr), "\n") } }, true, {})
end

return M
