-- Tests for the JWT-claims-to-identity derivation.
--
-- No child Neovim: the module is pure, and `vim.base64` / `vim.split` are
-- available in the test process itself.
--
-- Two golden vectors gate the derivation. Getting it wrong is expensive to
-- notice later: a wrong identity means `/v1/identity/{hex}/databases` returns an
-- empty list, which looks exactly like an auth failure.
local identity = require("spacetime.lib.identity")
local expect = MiniTest.expect

local T = MiniTest.new_set()

-- The TUI's own test vector (`spacetimedb-tui`, `src/api/client.rs`).
local TUI_ISS = "https://auth.spacetimedb.com"
local TUI_SUB = "test-subject-0001"
local TUI_IDENTITY = "c2005855e0ffa65fe854d934cff22cd1c9c60c2070d562b65f07f2c5f20dd8c1"

-- This account's real identity, as recorded in ROADMAP.md and visible in
-- `tests/fixtures/sql_bigint.json` and `tests/fixtures/logs.ndjson`.
local ACCOUNT_IDENTITY = "c2005efe02e92547ddd4bd106e84a281ead78a30fa26f42e619d70b20917c3dd"

---Build a JWT-shaped string around a payload, the way a real token is encoded:
---base64url, with the padding stripped.
---@param json string
---@return string
local function jwt(json)
	local payload = (vim.base64.encode(json):gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
	return "hdr." .. payload .. ".sig"
end

---@param hex string
---@return string bytes
local function unhex(hex)
	return (hex:gsub("%x%x", function(pair)
		return string.char(tonumber(pair, 16))
	end))
end

T["from_claims() matches the TUI's golden vector"] = function()
	expect.equality(identity.from_claims(TUI_ISS, TUI_SUB), TUI_IDENTITY)
end

T["from_token() derives the TUI's golden vector from a real JWT payload"] = function()
	-- The payload segment as a token actually carries it: 86 characters, so
	-- `#s % 4 == 2` and the decoder has to add "==" before Neovim will take it.
	local token = "hdr."
		.. "eyJpc3MiOiJodHRwczovL2F1dGguc3BhY2V0aW1lZGIuY29tIiwic3ViIjoidGVzdC1zdWJqZWN0LTAwMDEifQ"
		.. ".sig"
	expect.equality(identity.from_token(token), TUI_IDENTITY)
end

-- The second golden vector. Its `sub` claim lives only inside the account's
-- private token, so it is pinned by rebuilding instead: take the recorded
-- identity's last 26 bytes as `h` and re-derive the prefix and checksum. Only
-- the real checksum reproduces bytes 3-6, so this still fails if the hash or the
-- byte layout is wrong.
T["from_id_hash() rebuilds this account's real identity"] = function()
	local id_hash = unhex(ACCOUNT_IDENTITY):sub(7)
	expect.equality(#id_hash, 26)
	expect.equality(identity.from_id_hash(id_hash), ACCOUNT_IDENTITY)
end

T["a legacy hex_identity claim short-circuits without calling blake3"] = function()
	local saved = package.loaded["spacetime.lib.blake3"]
	package.loaded["spacetime.lib.blake3"] = {
		hash = function()
			error("blake3 must not be called")
		end,
		MAX_INPUT_BYTES = 1023,
	}

	local ok, result = pcall(identity.from_token, "hdr.eyJoZXhfaWRlbnRpdHkiOiJkZWFkYmVlZiJ9.sig")

	package.loaded["spacetime.lib.blake3"] = saved

	expect.equality(ok, true)
	expect.equality(result, "deadbeef")
end

T["unpadded payloads of either remainder decode"] = function()
	-- 64 bytes of JSON encode to 86 base64 characters (`% 4 == 2`); one more byte
	-- of `sub` makes it 87 (`% 4 == 3`). Between them they cover both repad arms.
	local p64 = ('{"iss":"%s","sub":"%s"}'):format(TUI_ISS, TUI_SUB)
	local p65 = ('{"iss":"%s","sub":"%s"}'):format(TUI_ISS, TUI_SUB .. "2")
	expect.equality(#p64, 64)
	expect.equality(#p65, 65)

	for _, payload in ipairs({ p64, p65 }) do
		local token = jwt(payload)
		local segment = vim.split(token, ".", { plain = true })[2]

		-- Why the repad exists at all: Neovim rejects the segment as written.
		expect.equality(pcall(vim.base64.decode, segment), false)

		expect.equality(identity.base64url_decode(segment), payload)
		expect.equality(#(identity.from_token(token) or ""), 64)
	end

	expect.equality(identity.from_token(jwt(p64)), TUI_IDENTITY)
end

T["base64url_decode() translates the -_ alphabet"] = function()
	expect.equality(identity.base64url_decode("-_8"), string.char(0xfb, 0xff))
end

T["malformed tokens return nil and a reason"] = function()
	local cases = {
		["no separator at all"] = "not-a-jwt",
		["a payload that is not base64"] = "hdr.@@@.sig",
		["an empty payload segment"] = "hdr..sig",
		["a payload length of 4n+1"] = "hdr.aaaaa.sig",
		["JSON without usable claims"] = jwt('{"aud":"x"}'),
		["a payload that is not JSON"] = jwt("not json"),
	}

	for name, token in pairs(cases) do
		local result, err = identity.from_token(token)
		expect.equality({ name, result }, { name, nil })
		expect.equality({ name, type(err) }, { name, "string" })
	end
end

T["from_token() raises on a non-string argument"] = function()
	expect.error(function()
		---@diagnostic disable-next-line: param-type-mismatch
		identity.from_token(nil)
	end)
end

T["resolve() prefers the configured override to the token"] = function()
	expect.equality(identity.resolve(nil, "c200deadbeef"), "c200deadbeef")
	expect.equality(identity.resolve(jwt('{"hex_identity":"c200aa"}'), "c200deadbeef"), "c200deadbeef")
end

T["resolve() without a token or an override explains itself"] = function()
	local result, err = identity.resolve(nil, nil)
	expect.equality(result, nil)
	expect.equality(err, "no token configured")

	result, err = identity.resolve("", "")
	expect.equality(result, nil)
	expect.equality(err, "no token configured")
end

return T
