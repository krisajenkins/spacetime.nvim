-- Tests for the single-chunk BLAKE3 implementation.
--
-- No child Neovim: the module is pure Lua and touches nothing in `vim`.
--
-- The gate is the official BLAKE3 test vectors. Their input is the byte pattern
-- `i % 251` — 251 being the largest prime below 256, so the sequence does not
-- align with the 64-byte block boundary and a block-indexing bug cannot hide
-- behind a repeating pattern. The expected values below are the first 32 bytes
-- of each vector's extended output.
local blake3 = require("spacetime.lib.blake3")
local expect = MiniTest.expect

local T = MiniTest.new_set()

---The official vector input: `n` bytes of the repeating pattern 0, 1, ..., 250.
---@param n integer
---@return string
local function pattern(n)
	local out = {}
	for i = 0, n - 1 do
		out[i + 1] = string.char(i % 251)
	end
	return table.concat(out)
end

-- Lengths chosen to straddle every boundary that matters: empty, sub-word,
-- one byte short of a block, exactly a block, one byte over, two blocks minus
-- one, and the largest input a single chunk holds.
local VECTORS = {
	[0] = "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262",
	[1] = "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213",
	[2] = "7b7015bb92cf0b318037702a6cdd81dee41224f734684c2c122cd6359cb1ee63",
	[3] = "e1be4d7a8ab5560aa4199eea339849ba8e293d55ca0a81006726d184519e647f",
	[63] = "e9bc37a594daad83be9470df7f7b3798297c3d834ce80ba85d6e207627b7db7b",
	[64] = "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98",
	[65] = "de1e5fa0be70df6d2be8fffd0e99ceaa8eb6e8c93a63f2d8d1c30ecb6b263dee",
	[127] = "d81293fda863f008c09e92fc382a81f5a0b4a1251cba1634016a0f86a6bd640d",
	[1023] = "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11",
}

for _, n in ipairs({ 0, 1, 2, 3, 63, 64, 65, 127, 1023 }) do
	T[("matches the official test vector for %d bytes"):format(n)] = function()
		expect.equality(blake3.hex(pattern(n)), VECTORS[n])
	end
end

T["hash() returns 32 raw bytes, not hex"] = function()
	expect.equality(#blake3.hash(pattern(0)), 32)
	expect.equality(#blake3.hash(pattern(1023)), 32)
end

T["hex() is the hex rendering of hash()"] = function()
	local digest = blake3.hash(pattern(65))
	local rendered = digest:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end)
	expect.equality(rendered, blake3.hex(pattern(65)))
end

T["the largest single-chunk input is accepted"] = function()
	expect.no_error(function()
		blake3.hash(pattern(blake3.MAX_INPUT_BYTES))
	end)
end

T["one byte past a chunk raises rather than returning a wrong digest"] = function()
	expect.error(function()
		blake3.hash(pattern(blake3.MAX_INPUT_BYTES + 1))
	end)
end

T["a non-string input raises"] = function()
	expect.error(function()
		---@diagnostic disable-next-line: param-type-mismatch
		blake3.hash(42)
	end)
end

-- The identity derivation of task 10 hashes `0xc200` followed by a 26-byte
-- prefix that routinely contains NULs, so the input must be treated as bytes
-- throughout rather than as a C string.
T["embedded NUL bytes are hashed, not treated as a terminator"] = function()
	local with_nuls = "\xc2\x00" .. string.rep("\0", 26)
	expect.equality(#blake3.hash(with_nuls), 32)
	expect.no_equality(blake3.hex(with_nuls), blake3.hex("\xc2"))
end

return T
