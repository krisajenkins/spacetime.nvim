-- Shared fixture reader for tests that work on the captured live responses in
-- `tests/fixtures/`.
--
-- The test runner starts Neovim at the repo root, so a repo-relative path is
-- all that is needed. Reading the bytes with `io` rather than through Neovim
-- keeps this usable from plain (non-child) test sets.
--
-- Usage:
--   local read = require("tests.helpers.fixtures").read
--   local text = read("schema_v10.json")

local M = {}

---Read a file from `tests/fixtures/` and return its contents verbatim.
---Raises if the fixture is missing, so a typo fails loudly rather than
---presenting itself as an empty payload.
---@param name string Fixture file name, e.g. `"sql_bigint.json"`.
---@return string
function M.read(name)
	local path = "tests/fixtures/" .. name
	local file = assert(io.open(path, "r"), "fixture not readable: " .. path)
	local text = assert(file:read("*a"), "fixture not readable: " .. path)
	file:close()
	return text
end

return M
