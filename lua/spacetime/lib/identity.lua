-- The account identity, derived from the token's OIDC claims.
--
-- `/v1/identity/{hex}/databases` is the only way to list a user's databases, so
-- the plugin needs the account's 32-byte identity before it can show anything.
-- Maincloud tokens are OIDC: the JWT payload carries `iss` and `sub` and **no**
-- `hex_identity`, so the identity has to be computed rather than read (ROADMAP.md,
-- verified fact 3):
--
--     h        = blake3(iss .. "|" .. sub)[1..26]
--     identity = 0xc200 ++ blake3(0xc200 ++ h)[1..4] ++ h
--
-- Those are **byte** counts, not hex characters: 2 + 4 + 26 = 32 bytes, rendered
-- as 64 hex characters. The constant prefix is why every identity you will ever
-- see starts `c200`.
--
-- Older self-hosted tokens do carry a `hex_identity` claim, and when they do it
-- is used verbatim — no derivation, and deliberately no blake3 call at all, so a
-- bug in the hash cannot break a token that never needed it.
--
-- This module lives under `lib/` and is pure: `vim.base64` and `vim.split` are
-- the only `vim.*` calls it makes, plus `spacetime.lib.json` for the payload.
-- `blake3` and `json` are required lazily, inside the functions, so tests can
-- swap them out through `package.loaded` before first use.

local M = {}

-- The version/tag prefix every SpacetimeDB identity carries, as raw bytes.
local PREFIX = string.char(0xc2, 0x00)

-- Byte lengths of the two derived pieces. The hash prefix is 26 bytes and the
-- checksum 4, which with the 2-byte PREFIX makes a 32-byte identity.
local HASH_BYTES = 26
local CHECKSUM_BYTES = 4

---Render raw bytes as lowercase hex.
---
---Not `blake3.hex`, which hashes its argument rather than rendering it, and not
---`bit.tohex`, which prints big-endian and would silently byte-swap the result.
---@param bytes string
---@return string
local function to_hex(bytes)
	local out = {}
	for i = 1, #bytes do
		out[i] = string.format("%02x", bytes:byte(i))
	end
	return table.concat(out)
end

---Decode one base64url segment, as found in a JWT.
---
---Two things differ from plain base64, and `vim.base64.decode` rejects both:
---the `-_` alphabet, and the missing `=` padding that JWT segments always omit.
---A remainder of 1 is impossible in valid base64, so it is rejected rather than
---padded.
---
---Exported for the tests, which pin the alphabet translation and the repad.
---@param segment string
---@return string|nil bytes `nil` when the segment is not valid base64url.
function M.base64url_decode(segment)
	-- The parens matter: `gsub` returns two values, and the second would become
	-- the second argument of the next `gsub` in the chain.
	local s = (segment:gsub("%-", "+"):gsub("_", "/"))

	local rem = #s % 4
	if rem == 1 then
		return nil
	elseif rem == 2 then
		s = s .. "=="
	elseif rem == 3 then
		s = s .. "="
	end

	local ok, raw = pcall(vim.base64.decode, s)
	if not ok then
		return nil
	end
	return raw
end

---Build the full identity from the 26-byte hash prefix, checksum included.
---@param id_hash string 26 raw bytes.
---@return string hex 64 lowercase hex characters.
function M.from_id_hash(id_hash)
	local blake3 = require("spacetime.lib.blake3")

	-- The checksum is blake3 over exactly the 28 bytes `0xc200 ++ h`.
	local checksum = blake3.hash(PREFIX .. id_hash):sub(1, CHECKSUM_BYTES)
	return to_hex(PREFIX .. checksum .. id_hash)
end

---Derive the identity from a token's `iss` and `sub` claims.
---@param iss string The issuer claim, e.g. `"https://auth.spacetimedb.com"`.
---@param sub string The subject claim.
---@return string hex 64 lowercase hex characters.
function M.from_claims(iss, sub)
	local blake3 = require("spacetime.lib.blake3")

	local id_hash = blake3.hash(iss .. "|" .. sub):sub(1, HASH_BYTES)
	return M.from_id_hash(id_hash)
end

---The identity a JWT stands for: its legacy `hex_identity` claim if it has one,
---otherwise derived from `iss`/`sub`.
---
---Every malformed input — a string that is not a JWT, a payload that is not
---base64url, JSON that is not an object, claims that are neither shape — comes
---back as `nil, message` rather than raising, because the callers are UI paths.
---Only a non-string argument raises, matching `blake3.hash`.
---
---Sync functions in this codebase return `value, err`; the `(err, value)` order
---described in `tests/CLAUDE.md` applies to async callbacks only.
---@param token string A JWT: `header.payload.signature`.
---@return string|nil identity 64 lowercase hex characters, or the legacy claim verbatim.
---@return string|nil err The reason, when `identity` is `nil`.
function M.from_token(token)
	if type(token) ~= "string" then
		error("spacetime.lib.identity: token must be a string", 2)
	end

	local parts = vim.split(token, ".", { plain = true })
	if #parts < 2 or parts[2] == "" then
		return nil, "not a JWT: no payload segment"
	end

	local raw = M.base64url_decode(parts[2])
	if not raw then
		return nil, "JWT payload is not valid base64url"
	end

	local ok, claims = pcall(require("spacetime.lib.json").decode, raw)
	if not ok or type(claims) ~= "table" then
		return nil, "JWT payload is not a JSON object"
	end

	-- A legacy self-hosted token already knows its identity. Take it exactly as
	-- written — no `0x` stripping, no case folding — and never touch blake3.
	if type(claims.hex_identity) == "string" then
		return claims.hex_identity
	end

	if type(claims.iss) ~= "string" or type(claims.sub) ~= "string" then
		return nil, "JWT payload has neither hex_identity nor iss/sub claims"
	end

	-- `blake3.hash` raises above one chunk, so a pathologically long claim pair
	-- surfaces as an error message rather than as a crash in a UI path.
	local derived
	ok, derived = pcall(M.from_claims, claims.iss, claims.sub)
	if not ok then
		return nil, tostring(derived)
	end
	return derived
end

---The identity to use: the configured override if there is one, else whatever
---the token's claims say.
---
---The override is the escape hatch of |spacetime-opt-identity| — it skips the
---derivation entirely, so a blake3 bug can never fully block a user.
---@param token string|nil The bearer token, as resolved from the config chain.
---@param override string|nil `require("spacetime").config.identity`, if set.
---@return string|nil identity
---@return string|nil err The reason, when `identity` is `nil`.
function M.resolve(token, override)
	if type(override) == "string" and override ~= "" then
		return override
	end
	if type(token) ~= "string" or token == "" then
		return nil, "no token configured"
	end
	return M.from_token(token)
end

return M
