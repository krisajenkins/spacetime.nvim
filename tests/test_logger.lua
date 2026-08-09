-- Tests for spacetime.logger.
--
-- The logger keeps its threshold in module state, so each case starts from a
-- fresh require. Nothing here needs a real editor: vim.notify is stubbed with a
-- recorder and restored afterwards, following the stub -> assert -> restore
-- shape of tests/test_health.lua.
local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			package.loaded["spacetime.logger"] = nil
		end,
	},
})
local expect = MiniTest.expect

-- A three-segment base64url token. Every segment is comfortably longer than the
-- length floor the JWT pattern applies, so it matches as a JWT.
local JWT = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ0ZXN0LTAwMDEifQ.c2lnbmF0dXJlLXZhbHVl"

-- Swap vim.notify for a recorder, run `fn` against a freshly loaded logger and
-- return the recorded { msg, level } entries. vim.notify is restored even if
-- `fn` throws.
local function with_captured_notify(fn)
	local records = {}
	local original = vim.notify

	vim.notify = function(msg, level)
		table.insert(records, { msg = msg, level = level })
	end

	package.loaded["spacetime.logger"] = nil
	local ok, err = pcall(fn, require("spacetime.logger"))

	vim.notify = original
	package.loaded["spacetime.logger"] = nil

	if not ok then
		error(err)
	end
	return records
end

-- A fresh logger for the pure functions, which need no notify stub.
local function fresh_logger()
	package.loaded["spacetime.logger"] = nil
	return require("spacetime.logger")
end

T["log keeps every argument, including nils"] = function()
	local records = with_captured_notify(function(logger)
		logger.info("a", nil, "c")
	end)

	expect.equality(#records, 1)
	expect.equality(records[1].msg, "[spacetime] a nil c")
	expect.equality(records[1].level, vim.log.levels.INFO)
end

T["level filtering suppresses below-threshold calls"] = function()
	local records = with_captured_notify(function(logger)
		logger.set_level(vim.log.levels.WARN)
		logger.debug("hidden")
		logger.info("hidden")
		logger.warn("shown")
		logger.error("shown")
	end)

	expect.equality(#records, 2)
	expect.equality(records[1].level, vim.log.levels.WARN)
	expect.equality(records[2].level, vim.log.levels.ERROR)
end

T["get_level() reports the level set by set_level()"] = function()
	local logger = fresh_logger()

	expect.equality(logger.get_level(), vim.log.levels.INFO)
	logger.set_level(vim.log.levels.DEBUG)
	expect.equality(logger.get_level(), vim.log.levels.DEBUG)
end

T["redact() masks an Authorization bearer header"] = function()
	local logger = fresh_logger()

	expect.equality(logger.redact("Authorization: Bearer " .. JWT), "Authorization: Bearer <redacted>")
	expect.equality(logger.redact("authorization: bearer " .. JWT), "authorization: bearer <redacted>")
end

T["redact() masks a bare JWT"] = function()
	local logger = fresh_logger()

	expect.equality(logger.redact("got token " .. JWT .. " for user"), "got token <redacted> for user")
end

T["redact() masks spacetimedb_token in cli.toml"] = function()
	local logger = fresh_logger()

	expect.equality(logger.redact('spacetimedb_token = "abcd1234"'), 'spacetimedb_token = "<redacted>"')
end

T["redact() masks web_session_token in cli.toml"] = function()
	local logger = fresh_logger()

	expect.equality(logger.redact('web_session_token = "abcd1234"'), 'web_session_token = "<redacted>"')
end

T["redact() leaves ordinary text alone"] = function()
	local logger = fresh_logger()

	-- The last one is the guard against the JWT pattern eating module paths.
	local untouched = {
		"connected to localhost:3000",
		"no token found",
		"spacetime.nvim 1.2.3",
		'require("spacetime.lib.http") failed',
	}
	for _, s in ipairs(untouched) do
		expect.equality(logger.redact(s), s)
	end
end

T["every log path redacts, even a table argument"] = function()
	local records = with_captured_notify(function(logger)
		logger.error({ headers = { Authorization = "Bearer " .. JWT } })
	end)

	expect.equality(#records, 1)
	expect.equality(records[1].msg:find("<redacted>", 1, true) ~= nil, true)
	expect.equality(records[1].msg:find("eyJhbGciOiJFUzI1NiJ9", 1, true), nil)
end

T["redact() masks a token nested in an inspected table"] = function()
	local records = with_captured_notify(function(logger)
		logger.set_level(vim.log.levels.DEBUG)
		logger.debug({ spacetimedb_token = "abcd1234" })
	end)

	expect.equality(#records, 1)
	expect.equality(records[1].msg:find("abcd1234", 1, true), nil)
	expect.equality(records[1].msg:find("<redacted>", 1, true) ~= nil, true)
end

return T
