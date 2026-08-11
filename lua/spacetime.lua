local logger = require("spacetime.logger")

--- Options accepted by |spacetime.setup()|. Every field is optional; unset
--- fields keep their defaults. Annotate your own config with this type to get
--- completion and typo-checking from lua-language-server:
---     ---@type SpacetimeSetupOptions
---     local opts = { log_level = vim.log.levels.DEBUG }
---     require("spacetime").setup(opts)
---@class SpacetimeSetupOptions
---@field log_level? number Log level, e.g. `vim.log.levels.INFO` (the default)
---@field identity? string Hex identity override, skipping derivation from the token's claims
---@field side? "left"|"right" Which side `:Spacetime` opens its sidebar on (default `"left"`)
---@field width? integer|string Sidebar width in columns, or a percentage such as `"20%"` (default `30`)
---@field log_lines? integer Log backlog `:SpacetimeLogs` asks for (default `200`)
---@field icons? "emoji"|"ascii"|"none" Kind and access icons in the sidebar (default `"emoji"`)

local M = {}

-- Default configuration. Kept separate from M.config so setup() can deep-merge
-- user options over a pristine copy without the defaults drifting.
local defaults = {
	side = "left",
	width = 30,
	icons = "emoji",
}

-- Runtime configuration, seeded with defaults and overridden by setup().
M.config = vim.deepcopy(defaults)

---Set up spacetime.nvim with the given options.
---@param opts? SpacetimeSetupOptions Configuration options
function M.setup(opts)
	opts = opts or {}

	-- Validate options up front so misconfiguration (e.g. a string log_level,
	-- which silently breaks the logger's numeric comparisons) fails loudly.
	vim.validate("opts", opts, "table")
	vim.validate("log_level", opts.log_level, "number", true)
	-- Unlike log_level, `identity` is stored config: it is read on every request
	-- that needs the account identity, not acted on once here.
	vim.validate("identity", opts.identity, "string", true)
	-- Stored config too, read by `ui/logs.lua` on every `:SpacetimeLogs`. Zero is
	-- allowed and means "no backlog", which is what a follow of only new lines
	-- will want (roadmap task 32); a fraction or a negative would go straight into
	-- a `num_lines=` query string, so both are refused here.
	vim.validate("log_lines", opts.log_lines, function(lines)
		return type(lines) == "number" and lines >= 0 and lines == math.floor(lines)
	end, true, "a whole number of lines, zero or more")
	-- Stored config too, read by `ui/tree.lua` on every sidebar render. Validated
	-- against the table that *defines* the modes rather than against a re-spelt
	-- list, so the two cannot drift apart; `ui/tree.lua` is pure, so requiring it
	-- here costs nothing.
	vim.validate("icons", opts.icons, function(icons)
		return require("spacetime.ui.tree").ICONS[icons] ~= nil
	end, true, '"emoji", "ascii" or "none"')
	-- The layout options are checked in spacetime.config, beside the width
	-- resolution that consumes them; required lazily so setup() stays cheap for
	-- a user who never opens a window.
	require("spacetime.config").validate_layout(opts)

	-- Deep-merge user options over a fresh copy of the defaults, so dict-tables
	-- merge recursively and a partial override keeps its unset siblings.
	-- log_level is a setup-time action, not stored config.
	M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
	M.config.log_level = nil

	if opts.log_level then
		logger.set_level(opts.log_level)
	end
end

return M
