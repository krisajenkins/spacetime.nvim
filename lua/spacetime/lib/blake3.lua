-- BLAKE3, single-chunk only, in pure Lua on LuaJIT's `bit` library.
--
-- It exists for one reason: the account identity is derived from the OIDC
-- claims in the CLI's token — `identity = 0xc200 ++ blake3(0xc200 ++ h)[..4] ++ h`
-- where `h = blake3("{iss}|{sub}")[..26]` (ROADMAP.md, task 10). Both inputs are
-- a few dozen bytes, so the chunk-chaining and tree-hashing machinery that
-- BLAKE3 needs above 1024 bytes would be dead code — and half-implemented dead
-- code is exactly how a hash quietly starts returning the wrong answer.
--
-- So the limit is enforced rather than assumed: `hash` raises above
-- `MAX_INPUT_BYTES` (1023, one chunk). A wrong digest is the failure mode that
-- matters here, because it surfaces much later as an empty database list that
-- looks identical to an auth failure. Loud and early beats silent and wrong.
--
-- Consequently this implements only the default hash mode: no keyed hashing, no
-- key derivation, no parent nodes, and no XOF output beyond the first 32 bytes.
-- The PARENT, KEYED_HASH and DERIVE_KEY flags are therefore absent by design.
--
-- `M.hash` returns **raw bytes**, not hex, because the caller slices them with
-- `string.sub`. `M.hex` is the human-readable rendering, used by the tests to
-- check against the official vectors.
--
-- Arithmetic notes, since pure-Lua 32-bit maths is where this kind of code goes
-- wrong: every word is held in `bit`'s *signed* 32-bit representation, so
-- negative numbers are normal and expected. Addition wraps via `tobit`, never
-- via `%` or `math.floor`. Byte extraction uses `rshift` (logical), never
-- `arshift`. Message and output words are little-endian; `bit.tohex` is not used
-- anywhere because it prints big-endian and would silently byte-swap the digest.
--
-- This module lives under `lib/` and is pure: it makes no `vim.*` calls at all.

local bit = require("bit")
local band, bor, bxor, ror, rshift, tobit = bit.band, bit.bor, bit.bxor, bit.ror, bit.rshift, bit.tobit

local M = {}

--- Largest input this single-chunk implementation accepts, in bytes.
M.MAX_INPUT_BYTES = 1023

-- The SHA-256 initialisation vector, reused verbatim by BLAKE3.
local IV = {
	0x6A09E667,
	0xBB67AE85,
	0x3C6EF372,
	0xA54FF53A,
	0x510E527F,
	0x9B05688C,
	0x1F83D9AB,
	0x5BE0CD19,
}

-- Message word permutation applied between rounds (0-based source indices).
local MSG_PERMUTATION = { 2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8 }

local CHUNK_START = 1
local CHUNK_END = 2
local ROOT = 8

local BLOCK_LEN = 64

-- Scratch tables, reused across blocks and calls. The module is synchronous and
-- has no coroutines, so a single set is safe and keeps the GC out of the hot loop.
local state = {} -- 16 words
local msg = {} -- 16 words, permuted in place between rounds
local permuted = {} -- 16 words, the scratch half of the permutation swap
local cv = {} -- 8 words, the running chaining value
local block = {} -- 64 bytes, zero-padded

---The BLAKE3 quarter-round, mixing two message words into four state words.
---Indices are 1-based into `state`.
---@param a integer
---@param b integer
---@param c integer
---@param d integer
---@param mx integer
---@param my integer
local function g(a, b, c, d, mx, my)
	local va, vb, vc, vd = state[a], state[b], state[c], state[d]

	va = tobit(va + vb + mx)
	vd = ror(bxor(vd, va), 16)
	vc = tobit(vc + vd)
	vb = ror(bxor(vb, vc), 12)

	va = tobit(va + vb + my)
	vd = ror(bxor(vd, va), 8)
	vc = tobit(vc + vd)
	vb = ror(bxor(vb, vc), 7)

	state[a], state[b], state[c], state[d] = va, vb, vc, vd
end

---One of the seven rounds: four column mixes, then four diagonal mixes.
local function round()
	-- Columns.
	g(1, 5, 9, 13, msg[1], msg[2])
	g(2, 6, 10, 14, msg[3], msg[4])
	g(3, 7, 11, 15, msg[5], msg[6])
	g(4, 8, 12, 16, msg[7], msg[8])
	-- Diagonals.
	g(1, 6, 11, 16, msg[9], msg[10])
	g(2, 7, 12, 13, msg[11], msg[12])
	g(3, 8, 9, 14, msg[13], msg[14])
	g(4, 5, 10, 15, msg[15], msg[16])
end

---Compress one 64-byte block into `state`, leaving the full 16-word result there.
---Reads the message from `msg` (which it consumes by permuting) and the chaining
---value from `cv`.
---@param counter integer Chunk counter; always 0 here, so both halves are 0.
---@param block_len integer Number of real bytes in the block, 0..64.
---@param flags integer CHUNK_START / CHUNK_END / ROOT, or-ed together.
local function compress(counter, block_len, flags)
	state[1], state[2], state[3], state[4] = cv[1], cv[2], cv[3], cv[4]
	state[5], state[6], state[7], state[8] = cv[5], cv[6], cv[7], cv[8]
	state[9], state[10], state[11], state[12] = IV[1], IV[2], IV[3], IV[4]
	-- Single-chunk: the counter never exceeds 32 bits, so the high word is 0.
	state[13], state[14] = tobit(counter), 0
	state[15], state[16] = block_len, flags

	for _ = 1, 6 do
		round()
		for i = 1, 16 do
			permuted[i] = msg[MSG_PERMUTATION[i] + 1]
		end
		for i = 1, 16 do
			msg[i] = permuted[i]
		end
	end
	round()

	-- Feed-forward. The upper half is only needed by the extended output, which
	-- this module does not expose, but the xor is part of the definition.
	for i = 1, 8 do
		state[i] = bxor(state[i], state[i + 8])
		state[i + 8] = bxor(state[i + 8], cv[i])
	end
end

---Load `block` (64 bytes, already zero-padded) into `msg` as little-endian words.
local function load_msg()
	for i = 1, 16 do
		local o = (i - 1) * 4
		msg[i] = tobit(block[o + 1] + block[o + 2] * 0x100 + block[o + 3] * 0x10000 + block[o + 4] * 0x1000000)
	end
end

---Hash a string with BLAKE3 (hash mode, default 32-byte output).
---Single-chunk only: inputs above `M.MAX_INPUT_BYTES` raise rather than
---returning a wrong digest.
---@param input string
---@return string digest 32 raw bytes.
function M.hash(input)
	if type(input) ~= "string" then
		error("spacetime.lib.blake3: input must be a string", 2)
	end
	if #input > M.MAX_INPUT_BYTES then
		error(
			("spacetime.lib.blake3: input is %d bytes; single-chunk BLAKE3 accepts at most %d"):format(
				#input,
				M.MAX_INPUT_BYTES
			),
			2
		)
	end

	for i = 1, 8 do
		cv[i] = IV[i]
	end

	-- An empty input still has exactly one block — 64 zero bytes with a length of
	-- 0 — and an input that is a positive multiple of 64 ends on its last full
	-- block rather than gaining an empty one.
	local len = #input
	local block_count = math.max(1, math.ceil(len / BLOCK_LEN))

	for index = 1, block_count do
		local offset = (index - 1) * BLOCK_LEN
		local block_len = math.min(BLOCK_LEN, len - offset)

		for i = 1, BLOCK_LEN do
			block[i] = 0
		end
		if block_len > 0 then
			-- string.byte returns block_len values; the padding above covers the rest.
			local bytes = { input:byte(offset + 1, offset + block_len) }
			for i = 1, block_len do
				block[i] = bytes[i]
			end
		end
		load_msg()

		local flags = 0
		if index == 1 then
			flags = bor(flags, CHUNK_START)
		end
		if index == block_count then
			-- Single chunk, so the chunk's end is also the root of the tree.
			flags = bor(flags, CHUNK_END, ROOT)
		end

		compress(0, block_len, flags)

		if index < block_count then
			for i = 1, 8 do
				cv[i] = state[i]
			end
		end
	end

	local out = {}
	for i = 1, 8 do
		local w = state[i]
		local o = (i - 1) * 4
		out[o + 1] = band(w, 0xff)
		out[o + 2] = band(rshift(w, 8), 0xff)
		out[o + 3] = band(rshift(w, 16), 0xff)
		out[o + 4] = rshift(w, 24)
	end
	return string.char(unpack(out))
end

---Same as `M.hash`, rendered as 64 lowercase hex characters.
---@param input string
---@return string hex
function M.hex(input)
	local digest = M.hash(input)
	local out = {}
	for i = 1, #digest do
		out[i] = string.format("%02x", digest:byte(i))
	end
	return table.concat(out)
end

return M
