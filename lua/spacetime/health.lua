-- Health check for spacetime.nvim, surfaced via `:checkhealth spacetime`.
--
-- Neovim auto-discovers `lua/<plugin>/health.lua` on the runtimepath and calls
-- its exported `check()`, so no manual registration is needed.

local M = {}

-- Minimum supported versions. These mirror the Requirements section of the
-- README/vimdoc. They may tighten as the plugin grows; keep them in sync.
local MIN_NVIM = { 0, 11, 0 }
local MIN_SPACETIME = { 2, 0, 0 }

-- vim.health's `start/ok/warn/error/info` API is Neovim 0.10+; our 0.11 minimum
-- guarantees it, so no `report_*` fallback is needed.
local health = vim.health
-- The report functions accept an optional advice arg (string|string[]); LLS's
-- bundled stub mistypes several as single-arg, so pin the shim's signature.
---@type table<string, fun(msg: string, advice?: string[])>
local h = {
	start = health.start,
	ok = health.ok,
	warn = health.warn,
	error = health.error,
	info = health.info,
}

-- Format a {major, minor, patch} table as "x.y.z".
local function version_string(v)
	return string.format("%d.%d.%d", v[1] or 0, v[2] or 0, v[3] or 0)
end

-- Return true when `parsed` (a vim.version() result) is older than the
-- {major, minor, patch} `minimum`.
local function is_older(parsed, minimum)
	return vim.version.cmp(parsed, minimum) < 0
end

local function check_neovim()
	local v = vim.version()
	local current = string.format("%d.%d.%d", v.major, v.minor, v.patch)
	if is_older({ v.major, v.minor, v.patch }, MIN_NVIM) then
		h.warn(string.format("Neovim %s is older than the minimum supported %s", current, version_string(MIN_NVIM)))
	else
		h.ok("Neovim " .. current)
	end
end

local function check_spacetime()
	-- vim.fn.exepath takes a single {name} argument; LLS's bundled vim stub
	-- mistypes it as zero-arg, so silence that false positive.
	---@diagnostic disable-next-line: redundant-parameter
	local cli_path = vim.fn.exepath("spacetime")
	if cli_path == "" then
		h.error("spacetime executable not found on PATH", {
			"Install the SpacetimeDB CLI: https://spacetimedb.com/install",
		})
		return
	end

	-- `spacetime --version` prints several lines; the one we want reads
	-- "spacetimedb tool version 2.8.0; ...".
	local output = vim.fn.systemlist({ cli_path, "--version" })
	local version = nil
	for _, line in ipairs(output or {}) do
		version = line:match("tool version (%d+%.%d+%.%d+)") or line:match("(%d+%.%d+%.%d+)")
		if version then
			break
		end
	end

	if not version then
		h.warn("Found spacetime at " .. cli_path .. " but could not parse its version")
		return
	end

	local parsed = vim.version.parse(version)
	if parsed and is_older(parsed, MIN_SPACETIME) then
		h.warn(
			string.format(
				"spacetime %s at %s is older than the minimum supported %s",
				version,
				cli_path,
				version_string(MIN_SPACETIME)
			)
		)
	else
		h.ok(string.format("spacetime %s (%s)", version, cli_path))
	end
end

local function check_curl()
	-- curl carries every HTTP request the plugin makes, so it is a hard
	-- requirement rather than an optional extra.
	-- vim.fn.exepath takes a single {name} argument; LLS's bundled vim stub
	-- mistypes it as zero-arg, so silence that false positive.
	---@diagnostic disable-next-line: redundant-parameter
	local curl_path = vim.fn.exepath("curl")
	if curl_path == "" then
		h.error("curl executable not found on PATH", {
			"Install curl with your system package manager",
		})
		return
	end

	-- `curl --version` opens with "curl 8.7.1 (x86_64-apple-darwin25.0) libcurl/...".
	local output = vim.fn.systemlist({ curl_path, "--version" })
	local version = nil
	for _, line in ipairs(output or {}) do
		version = line:match("^curl (%S+)")
		if version then
			break
		end
	end

	if not version then
		h.warn("Found curl at " .. curl_path .. " but could not parse its version")
		return
	end

	h.ok(string.format("curl %s (%s)", version, curl_path))
end

function M.check()
	h.start("spacetime")
	check_neovim()
	check_spacetime()
	check_curl()
end

return M
