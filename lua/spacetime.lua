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

local M = {}

-- Default configuration. Kept separate from M.config so setup() can deep-merge
-- user options over a pristine copy without the defaults drifting.
local defaults = {}

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
