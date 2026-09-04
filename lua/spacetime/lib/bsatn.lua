-- A hex-encoded BSATN value plus its `AlgebraicType`, decoded into the untagged
-- SATS shape `lib/value.lua` already knows how to render.
--
-- One thing in a schema does not arrive as JSON: a column's default. Both wire
-- versions carry it as BSATN — SpacetimeDB's binary encoding — hex-encoded into
-- a string, `"01"` for `Option::<u16>::None` and `"00000000"` for a `u32` zero.
-- Printed raw that is worse than useless, because `01` reads as the number one.
--
-- Rather than grow a second renderer, this module decodes the bytes into exactly
-- the value shape the JSON API would have sent for the same value — a product as
-- a positional array, a sum as `[tag, payload]` — so `lib/value.format` renders
-- a default through the same code path as a cell in the row grid, and `None`
-- prints as `none` in both places.
--
-- Three things this file exists to get right:
--
-- 1. **Integers are decimal *strings*, at every width.** BSATN is fixed-width
--    little-endian, so a `u64` default is eight bytes that a Lua number cannot
--    hold exactly above 2^53. `lib/value.lua` already accepts a digit string
--    wherever it accepts an integer — that is how `lib/json.lua` preserves big
--    integers — so converting the bytes to decimal by hand is both exact and
--    free of a special case at the 2^53 cliff.
-- 2. **Decoding must terminate on any input.** The bytes are attacker-shaped in
--    the same sense any wire payload is: a truncated value, a sum tag the type
--    does not have, an array count of four billion. Every read is bounds
--    checked, an array count is capped at the bytes left to read, and a `Ref`
--    cycle bottoms out on a depth budget rather than recursing forever.
-- 3. **A failure is a `nil, err`, never a raise and never a guess.** The caller
--    shows the raw hex instead, which is the honest fallback: a default we
--    cannot read is still a fact about the column.
--
-- This module lives under `lib/` and is pure logic: `spacetime.lib.schema`, for
-- `Ref` resolution, is the whole of its outside world.

local M = {}

-- Structural nesting and `Ref` hops share one budget. Unlike `lib/value.lua`,
-- which counts them apart so a plain alias does not look nested, nothing here
-- renders — the budget exists only so a self-referential type whose cycle reads
-- no bytes (a product of a ref to itself) cannot spin.
local MAX_DEPTH = 32

-- The BSATN widths, in bytes, and whether the tag is signed.
---@type table<string, {[1]: integer, [2]: boolean}>
local INTEGERS = {
	U8 = { 1, false },
	U16 = { 2, false },
	U32 = { 4, false },
	U64 = { 8, false },
	U128 = { 16, false },
	U256 = { 32, false },
	I8 = { 1, true },
	I16 = { 2, true },
	I32 = { 4, true },
	I64 = { 8, true },
	I128 = { 16, true },
	I256 = { 32, true },
}

--------------------------------------------------------------------------------
-- Reader
--------------------------------------------------------------------------------

---@class spacetime.BsatnReader
---@field bytes string The decoded payload.
---@field pos integer 1-based index of the next unread byte.

---Fail the whole decode. Thrown with level 0 and a table, so the `pcall` in
---`M.decode` can tell a decode failure from a genuine Lua bug.
---@param message string
local function fail(message)
	error({ bsatn = message }, 0)
end

---@param rd spacetime.BsatnReader
---@return integer
local function remaining(rd)
	return #rd.bytes - rd.pos + 1
end

---@param rd spacetime.BsatnReader
---@param count integer
---@return string
local function take(rd, count)
	if count > remaining(rd) then
		fail("truncated")
	end
	local from = rd.pos
	rd.pos = from + count
	return rd.bytes:sub(from, from + count - 1)
end

--------------------------------------------------------------------------------
-- Scalars
--------------------------------------------------------------------------------

---Big-endian bytes as a decimal digit string, by long multiplication in base 10.
---
---Exact at any width: nothing here ever becomes a Lua number.
---@param be integer[] Byte values, most significant first.
---@return string
local function decimal_of(be)
	local digits = { 0 }
	for _, byte in ipairs(be) do
		local carry = byte
		for i = 1, #digits do
			local sum = digits[i] * 256 + carry
			digits[i] = sum % 10
			carry = math.floor(sum / 10)
		end
		while carry > 0 do
			digits[#digits + 1] = carry % 10
			carry = math.floor(carry / 10)
		end
	end

	-- A carry never pushes a zero, so the seeded `0` is the only digit that can
	-- lead, and it does so only for the value zero itself.
	local out = {}
	for i = #digits, 1, -1 do
		out[#out + 1] = tostring(digits[i])
	end
	return table.concat(out)
end

---@param rd spacetime.BsatnReader
---@param width integer
---@param signed boolean
---@return string # Decimal digits, with a leading `-` when negative.
local function decode_integer(rd, width, signed)
	local raw = take(rd, width)

	-- BSATN is little-endian; the decimal conversion wants the other order.
	local be = {}
	for i = width, 1, -1 do
		be[#be + 1] = raw:byte(i)
	end

	local negative = signed and be[1] >= 0x80
	if negative then
		-- Two's complement, in place: invert every byte and add one.
		local carry = 1
		for i = width, 1, -1 do
			local sum = (255 - be[i]) + carry
			be[i] = sum % 256
			carry = math.floor(sum / 256)
		end
	end

	local digits = decimal_of(be)
	return negative and ("-" .. digits) or digits
end

---IEEE 754 from its sign, exponent and mantissa fields, assembled by the two
---callers below because a 64-bit float's bit pattern does not fit a Lua number.
---@param sign integer `1` or `-1`.
---@param exponent integer Raw biased exponent.
---@param mantissa integer Raw fraction bits.
---@param max_exponent integer The all-ones exponent: 255 for f32, 2047 for f64.
---@param bias integer Subtracted from the exponent to place the mantissa's LSB.
---@param implicit integer The implicit leading bit: 2^23 for f32, 2^52 for f64.
---@return number
local function ieee754(sign, exponent, mantissa, max_exponent, bias, implicit)
	if exponent == 0 then
		if mantissa == 0 then
			return sign * 0.0
		end
		return sign * math.ldexp(mantissa, 1 - bias)
	end
	if exponent == max_exponent then
		if mantissa == 0 then
			return sign * math.huge
		end
		return 0 / 0
	end
	return sign * math.ldexp(mantissa + implicit, exponent - bias)
end

---@param rd spacetime.BsatnReader
---@return number
local function decode_f32(rd)
	local b = { take(rd, 4):byte(1, 4) }
	local sign = b[4] >= 0x80 and -1 or 1
	local exponent = (b[4] % 128) * 2 + math.floor(b[3] / 128)
	local mantissa = (b[3] % 128) * 65536 + b[2] * 256 + b[1]
	return ieee754(sign, exponent, mantissa, 255, 150, 8388608)
end

---@param rd spacetime.BsatnReader
---@return number
local function decode_f64(rd)
	local b = { take(rd, 8):byte(1, 8) }
	local sign = b[8] >= 0x80 and -1 or 1
	local exponent = (b[8] % 128) * 16 + math.floor(b[7] / 16)
	local mantissa = b[7] % 16
	for i = 6, 1, -1 do
		mantissa = mantissa * 256 + b[i]
	end
	return ieee754(sign, exponent, mantissa, 2047, 1075, 4503599627370496)
end

---The `u32` that prefixes a string's bytes and an array's elements.
---@param rd spacetime.BsatnReader
---@return integer
local function decode_length(rd)
	local b1, b2, b3, b4 = take(rd, 4):byte(1, 4)
	return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

--------------------------------------------------------------------------------
-- The type walk
--------------------------------------------------------------------------------

---@param value any
---@return any[]
local function list(value)
	return type(value) == "table" and value or {}
end

---The single key of a tagged `AlgebraicType`, with its payload — the same shape
---`lib/value.lua` reads, and for the same reason: a JSON `null` decodes to
---`vim.NIL`, which the `type` guard rejects without naming the sentinel.
---@param atype any
---@return string|nil tag
---@return any payload
local function type_tag(atype)
	if type(atype) ~= "table" then
		return nil, nil
	end
	local tag = next(atype)
	if type(tag) ~= "string" then
		return nil, nil
	end
	return tag, atype[tag]
end

---@type fun(rd: spacetime.BsatnReader, atype: any, model: any, depth: integer): any
local decode_value

---@param rd spacetime.BsatnReader
---@param product any The payload of a `{"Product": …}` type.
---@param model any
---@param depth integer
---@return any[]
local function decode_product(rd, product, model, depth)
	local out = {}
	local elements = list(type(product) == "table" and product.elements or nil)
	for i, element in ipairs(elements) do
		local etype = type(element) == "table" and element.algebraic_type or nil
		out[i] = decode_value(rd, etype, model, depth + 1)
	end
	return out
end

---@param rd spacetime.BsatnReader
---@param sum any The payload of a `{"Sum": …}` type.
---@param model any
---@param depth integer
---@return any[] # `{tag, payload}`, the wire shape `lib/value.lua` reads.
local function decode_sum(rd, sum, model, depth)
	local tag = take(rd, 1):byte()
	local variant = list(type(sum) == "table" and sum.variants or nil)[tag + 1]
	if type(variant) ~= "table" then
		fail("sum tag " .. tag .. " is not in the type")
	end
	return { tag, decode_value(rd, variant.algebraic_type, model, depth + 1) }
end

---@param rd spacetime.BsatnReader
---@param element_type any
---@param model any
---@param depth integer
---@return any[]
local function decode_array(rd, element_type, model, depth)
	local count = decode_length(rd)
	-- Every element of a well-formed array reads at least one byte, so a count
	-- past the bytes left is a corrupt payload. Checking it up front is also
	-- what stops a zero-width element type — a unit product — from turning a
	-- bogus count into a loop that never ends.
	if count > remaining(rd) then
		fail("array of " .. count .. " is longer than the value")
	end

	local out = {}
	for i = 1, count do
		out[i] = decode_value(rd, element_type, model, depth + 1)
	end
	return out
end

decode_value = function(rd, atype, model, depth)
	if depth > MAX_DEPTH then
		fail("type nests deeper than " .. MAX_DEPTH)
	end

	local tag, payload = type_tag(atype)
	if tag == nil then
		fail("no type to decode against")
	end

	if tag == "Ref" then
		-- The require is lazy so the two modules stay independently loadable, and
		-- `lib/schema` owns the 0-based off-by-one.
		local resolved = model ~= nil and require("spacetime.lib.schema").type_at(model, payload) or nil
		if resolved == nil then
			fail("unresolvable Ref")
		end
		return decode_value(rd, resolved, model, depth + 1)
	end

	local width = INTEGERS[tag]
	if width ~= nil then
		return decode_integer(rd, width[1], width[2])
	end

	if tag == "Bool" then
		return take(rd, 1):byte() ~= 0
	end
	if tag == "F32" then
		return decode_f32(rd)
	end
	if tag == "F64" then
		return decode_f64(rd)
	end
	if tag == "String" then
		return take(rd, decode_length(rd))
	end
	if tag == "Product" then
		return decode_product(rd, payload, model, depth)
	end
	if tag == "Sum" then
		return decode_sum(rd, payload, model, depth)
	end
	if tag == "Array" then
		return decode_array(rd, payload, model, depth)
	end

	fail("unknown type tag " .. tag)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

---Decode a hex string into its bytes.
---@param hex string
---@return string|nil bytes
local function unhex(hex)
	if #hex % 2 ~= 0 or hex:find("[^0-9A-Fa-f]") ~= nil then
		return nil
	end
	return (hex:gsub("%x%x", function(pair)
		return string.char(tonumber(pair, 16))
	end))
end

---Decode a hex-encoded BSATN value against its `AlgebraicType`.
---
---The result is the untagged SATS shape `lib/value.format` renders: a product is
---a positional array, a sum is `{tag, payload}`, and every integer is a decimal
---digit string.
---
---Trailing bytes are an error rather than something to ignore: they mean the
---type and the payload disagree, and half a value rendered confidently is the
---bug this module exists to remove.
---@param hex string Hex-encoded BSATN, as both schema versions carry a default.
---@param atype any The value's `AlgebraicType`, raw off the wire.
---@param types any A `SpacetimeSchema` or a bare typespace, for `Ref` resolution.
---@return any value # `nil` on any failure.
---@return string|nil err
function M.decode(hex, atype, types)
	if type(hex) ~= "string" then
		return nil, "not a hex string"
	end
	local bytes = unhex(hex)
	if bytes == nil then
		return nil, "not a hex string"
	end

	local model = nil
	if type(types) == "table" then
		model = type(types.typespace) == "table" and types or { typespace = types }
	end

	local rd = { bytes = bytes, pos = 1 }
	local ok, value = pcall(decode_value, rd, atype, model, 0)
	if not ok then
		if type(value) == "table" and type(value.bsatn) == "string" then
			return nil, value.bsatn
		end
		return nil, "decode failed"
	end
	if remaining(rd) > 0 then
		return nil, remaining(rd) .. " trailing byte(s)"
	end
	return value, nil
end

return M
