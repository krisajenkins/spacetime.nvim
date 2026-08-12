-- A raw SATS value plus its `AlgebraicType`, rendered for display.
--
-- Every value SpacetimeDB sends over the JSON API is *untagged*: a row is a
-- positional array, a sum is `[variant_index, payload]`, and a `Timestamp` is
-- indistinguishable from any other one-element product. Nothing in the payload
-- says what it is — the type does. So this module is a reflective decoder: it
-- walks the `AlgebraicType` and the value in lockstep, exactly as upstream's own
-- deserializers do (`crates/sats/src/de/impls.rs:583` in Rust,
-- `sdks/typescript/src/lib/algebraic_type.ts:527` in TypeScript).
--
-- Four things this file exists to get right:
--
-- 1. **A recursive type must not hang the editor.** `Ref` resolution carries its
--    own counter, separate from structural depth, so a self-referential type
--    bottoms out at `…` (values) or `Ref(n)` (labels) rather than looping.
--    Keeping the two counters apart matters: a column typed as a `Ref` to
--    `String` is still a top-level string, and must render bare rather than
--    quoted.
-- 2. **The wire format is not consistent per width.** In the committed
--    `sql_bigint.json` the U256 `identity` is the hex *string*
--    `"0xc2005efe…"` while the U128 `connection_id` is a bare *number* that
--    `lib/json.lua` hands back as a 39-digit decimal *string*. Integers
--    therefore accept a number or a string and, when it is a string, pass it
--    through verbatim.
-- 3. **Integers must never go near `tostring`.** In LuaJIT
--    `tostring(1780864718837447)` is `"1.7808647188374e+15"`, which would put a
--    mangled primary key in the grid and in the user's yank register.
--    `string.format("%d", …)` is the only integer path.
-- 4. **Unrecognised newtypes pass through verbatim.** `__uuid__` (U128) exists
--    upstream and appears in the live fixture, and is *deliberately* rendered as
--    the plain product `{ __uuid__ = 42 }`. Guessing at a formatting for a
--    newtype we do not know is how a browser starts lying about the data.
--
-- One deliberate asymmetry, so it is not "fixed" later by accident:
-- `__identity__` arrives as `"0x…"` and stays hex, while `__connection_id__`
-- arrives as a bare number and stays *decimal digits*. `lib/` has no bignum, the
-- issue's stated principle is verbatim pass-through, and preserving the exact
-- digits is what keeps a yank correct. The two specials consequently look
-- different in a grid; that is the honest rendering.
--
-- **No truncation happens here.** `M.format` returns the whole string;
-- `ui/grid.lua` owns width, truncation and the ellipsis span, and the row-detail
-- float wants the untruncated text. `max_depth`/`max_elements` exist only to
-- bound pathological structures, not to do layout.
--
-- This module lives under `lib/` and is pure logic: `vim.NIL` (a sentinel value,
-- not a call) and `spacetime.lib.schema` are the whole of its outside world.

local M = {}

---@class SpacetimeValueOpts
---@field max_depth? integer Nesting, and `Ref` hops, before `…`. Default 12.
---@field max_elements? integer Array elements rendered before a final `…`. Default 32.

---@class spacetime.ValueCtx
---@field model any Normalised `{typespace = …}`, or `nil` when refs cannot be resolved.
---@field aliases table<integer,string> 0-based typespace index -> alias name.
---@field max_depth integer
---@field max_elements integer

local NULL_HL = "SpacetimeNull"
local SPECIAL_HL = "SpacetimeSpecial"
local ELLIPSIS = "…"
local UNKNOWN_LABEL = "?"
local DEFAULT_MAX_DEPTH = 12
local DEFAULT_MAX_ELEMENTS = 32

-- 2^53: above this a Lua number is no longer an exact integer, so `%d` would
-- print a rounded value with unwarranted confidence.
local EXACT_INTEGER_LIMIT = 9007199254740992

-- The full set of SATS integer tags. The live fixtures only exercise
-- `U8/U32/U64/U128/U256/I64/I128`, but upstream enumerates all twelve and a
-- module using `I16` should not fall through to the untyped renderer.
---@type table<string, boolean>
local INTEGERS = {}
for _, name in ipairs({ "U8", "U16", "U32", "U64", "U128", "U256", "I8", "I16", "I32", "I64", "I128", "I256" }) do
	INTEGERS[name] = true
end

-- The magic newtypes: a one-element product whose sole element carries one of
-- these names *is* the scalar, and renders as one.
---@type table<string, string>
local SPECIALS = {
	__identity__ = "identity",
	__connection_id__ = "connection_id",
	__timestamp_micros_since_unix_epoch__ = "timestamp",
	__time_duration_micros__ = "duration",
}

---@type table<string, string>
local SPECIAL_LABELS = {
	identity = "Identity",
	connection_id = "ConnectionId",
	timestamp = "Timestamp",
	duration = "TimeDuration",
}

--------------------------------------------------------------------------------
-- Wire-shape helpers
--------------------------------------------------------------------------------

---The single key of a tagged `AlgebraicType`, with its payload:
---`{U64 = {}}` -> `"U64", {}`; `{Ref = 2}` -> `"Ref", 2`.
---
---A JSON `null` decodes to `vim.NIL`, which is userdata rather than a table, so
---the `type` guard rejects it without this module ever naming the sentinel.
---@param atype any
---@return string|nil tag
---@return any payload
local function type_tag(atype)
	if type(atype) ~= "table" then
		return nil, nil
	end
	local key = next(atype)
	if type(key) ~= "string" then
		return nil, nil
	end
	return key, atype[key]
end

---The name of a product element or a sum variant, unwrapping the Option both
---are wrapped in. Older servers have been seen sending a bare string.
---@param element any
---@return string|nil
local function element_name(element)
	if type(element) ~= "table" then
		return nil
	end
	local name = element.name
	if type(name) == "table" and type(name.some) == "string" then
		return name.some
	end
	if type(name) == "string" then
		return name
	end
	return nil
end

---Whether `atype` is the unit product `{"Product":{"elements":[]}}` — the
---payload every payload-less sum variant carries.
---@param atype any
---@return boolean
local function is_unit(atype)
	local tag, payload = type_tag(atype)
	if tag ~= "Product" then
		return false
	end
	local elements = type(payload) == "table" and payload.elements or nil
	return type(elements) == "table" and next(elements) == nil
end

---Which magic newtype, if any, a `Product` payload describes.
---@param product any The payload of a `{"Product": …}` type.
---@return string|nil kind One of `"identity"`, `"connection_id"`, `"timestamp"`, `"duration"`.
---@return string|nil field The element name, for unwrapping a named value.
local function special_of(product)
	if type(product) ~= "table" then
		return nil, nil
	end
	local elements = product.elements
	if type(elements) ~= "table" or #elements ~= 1 then
		return nil, nil
	end
	local name = element_name(elements[1])
	if name == nil then
		return nil, nil
	end
	return SPECIALS[name], name
end

---The `some` payload type of a Sum, when that Sum is an Option.
---
---The predicate is deliberately exact — two variants, named `some` then `none`,
---with `none` carrying the unit product. Order matters: a module is free to
---declare its own two-variant sum called `some`/`none` the other way round, and
---that is not an Option.
---@param sum any The payload of a `{"Sum": …}` type.
---@return any some_type Payload type of the `some` variant; `nil` if not an Option.
---@return boolean is_option
local function option_type(sum)
	local variants = type(sum) == "table" and sum.variants or nil
	if type(variants) ~= "table" or #variants ~= 2 then
		return nil, false
	end
	if element_name(variants[1]) ~= "some" or element_name(variants[2]) ~= "none" then
		return nil, false
	end
	if not is_unit(type(variants[2]) == "table" and variants[2].algebraic_type or nil) then
		return nil, false
	end
	return type(variants[1]) == "table" and variants[1].algebraic_type or nil, true
end

--------------------------------------------------------------------------------
-- Scalar rendering
--------------------------------------------------------------------------------

---An integer as text. `%d` up to 2^53, where a Lua number stops being exact;
---beyond that `tostring` at least admits it is approximate.
---@param v number
---@return string
local function number_text(v)
	if v == math.floor(v) and v > -EXACT_INTEGER_LIMIT and v < EXACT_INTEGER_LIMIT then
		return string.format("%d", v)
	end
	return tostring(v)
end

---A string as a quoted literal, so a nested empty string or one with leading
---space is still visible as a value.
---@param s string
---@return string
local function quoted(s)
	local escaped = s:gsub("\\", "\\\\")
	escaped = escaped:gsub('"', '\\"')
	return '"' .. escaped .. '"'
end

---A scalar as micros: a number, or the decimal string `lib/json.lua` hands back
---for a run of 16 or more digits — which is exactly what every real timestamp
---is. That module owns the coercion, because it is the one that makes the second
---spelling possible.
---@param value any
---@return integer|nil
local function to_micros(value)
	return require("spacetime.lib.json").to_integer(value)
end

---Trim a fixed-point decimal down to its significant digits: `"1.500"` ->
---`"1.5"`, `"2.000000"` -> `"2"`.
---@param s string
---@return string
local function trim_zeros(s)
	if s:find(".", 1, true) == nil then
		return s
	end
	return (s:gsub("0+$", ""):gsub("%.$", ""))
end

---Micros since the Unix epoch as ISO-8601 UTC, to microsecond precision.
---
---`os.date` is the whole of the calendar arithmetic; when it refuses a value
---(one far outside the platform's `time_t`) the raw micros are shown instead,
---because an unreadable timestamp still beats no cell at all.
---@param micros integer
---@return string
local function timestamp_text(micros)
	local seconds = math.floor(micros / 1000000)
	local rest = micros - seconds * 1000000
	local ok, stamp = pcall(os.date, "!%Y-%m-%dT%H:%M:%S", seconds)
	if not ok or type(stamp) ~= "string" then
		return string.format("%d", micros)
	end
	return stamp .. string.format(".%06dZ", rest)
end

---A duration in micros as `500µs`, `1.5ms`, `1.5s`, `1m 30s`, `2d 3h 4m 5s`.
---
---Only non-zero units are emitted, so `5400000000` is `1h 30m` rather than
---`1h 30m 0s`, and a duration of nothing is `0s`.
---@param micros integer
---@return string
local function duration_text(micros)
	local sign = ""
	if micros < 0 then
		sign, micros = "-", -micros
	end
	if micros == 0 then
		return "0s"
	end
	if micros < 1000 then
		return sign .. string.format("%d", micros) .. "µs"
	end
	if micros < 1000000 then
		return sign .. trim_zeros(string.format("%.3f", micros / 1000)) .. "ms"
	end

	local whole = math.floor(micros / 1000000)
	local rest = micros - whole * 1000000
	local parts = {}
	local days = math.floor(whole / 86400)
	local hours = math.floor(whole / 3600) % 24
	local minutes = math.floor(whole / 60) % 60
	local seconds = whole % 60
	if days > 0 then
		parts[#parts + 1] = string.format("%dd", days)
	end
	if hours > 0 then
		parts[#parts + 1] = string.format("%dh", hours)
	end
	if minutes > 0 then
		parts[#parts + 1] = string.format("%dm", minutes)
	end
	if rest > 0 then
		parts[#parts + 1] = trim_zeros(string.format("%.6f", seconds + rest / 1000000)) .. "s"
	elseif seconds > 0 then
		parts[#parts + 1] = string.format("%ds", seconds)
	end
	return sign .. table.concat(parts, " ")
end

---The scalar inside a magic newtype's value.
---
---It may arrive as the one-element product array `["0x…"]`, as the named form
---`{__identity__ = "0x…"}`, or already unwrapped as a bare scalar — a value can
---reach this rule by any of the three routes.
---@param value any
---@param field string|nil The element name, for the named form.
---@return any
local function unwrap_scalar(value, field)
	if type(value) ~= "table" then
		return value
	end
	if value[1] ~= nil then
		return value[1]
	end
	if field ~= nil then
		return value[field]
	end
	return nil
end

---Render one magic newtype's scalar, or `nil` when the value does not fit the
---type and the untyped renderer should have it instead.
---@param kind string
---@param scalar any
---@return string|nil
local function special_text(kind, scalar)
	if kind == "identity" or kind == "connection_id" then
		if type(scalar) == "string" then
			return scalar
		end
		if type(scalar) == "number" then
			return number_text(scalar)
		end
		return nil
	end
	local micros = to_micros(scalar)
	if micros == nil then
		return nil
	end
	if kind == "timestamp" then
		return timestamp_text(micros)
	end
	return duration_text(micros)
end

--------------------------------------------------------------------------------
-- Context
--------------------------------------------------------------------------------

---Normalise the `types` argument: a full `SpacetimeSchema`, a bare typespace
---array, or nothing at all.
---@param types any
---@return any # `nil` when refs cannot be resolved.
local function as_model(types)
	if type(types) ~= "table" then
		return nil
	end
	if type(types.typespace) == "table" then
		return types
	end
	return { typespace = types }
end

---@param types any
---@param opts any
---@return spacetime.ValueCtx
local function new_ctx(types, opts)
	local options = type(opts) == "table" and opts or {}
	local model = as_model(types)

	---@type table<integer,string>
	local aliases = {}
	if model ~= nil and type(model.types) == "table" then
		for _, alias in ipairs(model.types) do
			if type(alias) == "table" and type(alias.name) == "string" and type(alias.ref) == "number" then
				aliases[alias.ref] = alias.name
			end
		end
	end

	return {
		model = model,
		aliases = aliases,
		max_depth = type(options.max_depth) == "number" and options.max_depth or DEFAULT_MAX_DEPTH,
		max_elements = type(options.max_elements) == "number" and options.max_elements or DEFAULT_MAX_ELEMENTS,
	}
end

---Resolve a 0-based `Ref` through `lib/schema`, which owns the off-by-one.
---The require is lazy so the two modules stay independently loadable.
---@param ctx spacetime.ValueCtx
---@param ref any
---@return table|nil
local function resolve(ctx, ref)
	if ctx.model == nil or type(ref) ~= "number" then
		return nil
	end
	return require("spacetime.lib.schema").type_at(ctx.model, ref)
end

--------------------------------------------------------------------------------
-- Value rendering
--------------------------------------------------------------------------------

---Render a value with no type to guide it: the fallback for an absent type, an
---unresolvable `Ref`, and any value whose shape contradicts its type.
---@param value any
---@param ctx spacetime.ValueCtx
---@param depth integer
---@return string
---@return string|nil
local function untyped(value, ctx, depth)
	if value == nil or value == vim.NIL then
		return "NULL", NULL_HL
	end

	local kind = type(value)
	if kind == "string" then
		return depth > 0 and quoted(value) or value, nil
	end
	if kind == "number" then
		return number_text(value), nil
	end
	if kind ~= "table" then
		return tostring(value), nil
	end
	if depth >= ctx.max_depth then
		return ELLIPSIS, nil
	end

	local count = #value
	if count > 0 then
		local shown = math.min(count, ctx.max_elements)
		local pieces = {}
		for i = 1, shown do
			pieces[i] = (untyped(value[i], ctx, depth + 1))
		end
		if count > shown then
			pieces[#pieces + 1] = ELLIPSIS
		end
		return "[" .. table.concat(pieces, ", ") .. "]", nil
	end

	-- `pairs` order is a hash order, so keys are sorted: a cell's text must not
	-- change between two renders of the same value.
	local keys = {}
	for key in pairs(value) do
		keys[#keys + 1] = key
	end
	if #keys == 0 then
		return "{}", nil
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)

	local pieces = {}
	for i, key in ipairs(keys) do
		pieces[i] = tostring(key) .. " = " .. (untyped(value[key], ctx, depth + 1))
	end
	return "{ " .. table.concat(pieces, ", ") .. " }", nil
end

-- Forward declaration: the three composite renderers below are mutually
-- recursive with `render`.
---@type fun(value: any, atype: any, ctx: spacetime.ValueCtx, depth: integer, refs: integer): string, string|nil
local render

---@param value any
---@param element_type any
---@param ctx spacetime.ValueCtx
---@param depth integer
---@param refs integer
---@return string
---@return string|nil
local function render_array(value, element_type, ctx, depth, refs)
	if type(value) ~= "table" then
		return untyped(value, ctx, depth)
	end
	local count = #value
	if count == 0 then
		return "[]", nil
	end

	local shown = math.min(count, ctx.max_elements)
	local pieces = {}
	for i = 1, shown do
		pieces[i] = (render(value[i], element_type, ctx, depth + 1, refs))
	end
	if count > shown then
		pieces[#pieces + 1] = ELLIPSIS
	end
	return "[" .. table.concat(pieces, ", ") .. "]", nil
end

---@param value any
---@param product any
---@param ctx spacetime.ValueCtx
---@param depth integer
---@param refs integer
---@return string
---@return string|nil
local function render_product(value, product, ctx, depth, refs)
	local kind, field = special_of(product)
	if kind ~= nil then
		local text = special_text(kind, unwrap_scalar(value, field))
		if text ~= nil then
			return text, SPECIAL_HL
		end
		return untyped(value, ctx, depth)
	end

	local elements = type(product) == "table" and product.elements or nil
	if type(elements) ~= "table" then
		return untyped(value, ctx, depth)
	end
	if #elements == 0 then
		return "{}", nil
	end
	if type(value) ~= "table" then
		return untyped(value, ctx, depth)
	end

	local pieces = {}
	for i, element in ipairs(elements) do
		local name = element_name(element)
		-- Positional first — that is what the wire sends — with the named shape
		-- the serializer also emits as the fallback.
		local item = value[i]
		if item == nil and name ~= nil then
			item = value[name]
		end
		local etype = type(element) == "table" and element.algebraic_type or nil
		local text = (render(item, etype, ctx, depth + 1, refs))
		pieces[i] = name and (name .. " = " .. text) or text
	end
	return "{ " .. table.concat(pieces, ", ") .. " }", nil
end

---Which variant of a Sum a value carries.
---
---`[tag, payload]` is the wire shape; `{name = payload}` is the serializer's
---other spelling and costs one lookup to accept.
---@param value any
---@param variants any[]
---@return integer|nil index 1-based index into `variants`.
---@return integer|nil wire_tag The 0-based tag as it arrived.
---@return any payload
local function sum_variant(value, variants)
	if type(value) ~= "table" then
		return nil, nil, nil
	end
	if type(value[1]) == "number" then
		local wire_tag = value[1]
		return wire_tag + 1, wire_tag, value[2]
	end
	local key = next(value)
	if type(key) == "string" then
		for i, variant in ipairs(variants) do
			if element_name(variant) == key then
				return i, i - 1, value[key]
			end
		end
	end
	return nil, nil, nil
end

---@param value any
---@param sum any
---@param ctx spacetime.ValueCtx
---@param depth integer
---@param refs integer
---@return string
---@return string|nil
local function render_sum(value, sum, ctx, depth, refs)
	local variants = type(sum) == "table" and sum.variants or nil
	if type(variants) ~= "table" or type(value) ~= "table" then
		return untyped(value, ctx, depth)
	end

	local index, wire_tag, payload = sum_variant(value, variants)
	if index == nil then
		return untyped(value, ctx, depth)
	end

	local variant = variants[index]
	if type(variant) ~= "table" then
		-- A tag the type does not describe: say so, and show the payload raw
		-- rather than dropping it.
		return string.format("<tag %d>(%s)", wire_tag, (untyped(payload, ctx, depth + 1))), nil
	end

	local some_type, is_option = option_type(sum)
	if is_option then
		if index == 1 then
			-- The one place a highlight propagates outward: `some(<timestamp>)`
			-- stays a special, because the cell is still showing a timestamp.
			local text, hl = render(payload, some_type, ctx, depth + 1, refs)
			return "some(" .. text .. ")", hl
		end
		return "none", NULL_HL
	end

	local name = element_name(variant) or string.format("<tag %d>", wire_tag)
	local vtype = variant.algebraic_type
	if is_unit(vtype) then
		return name, nil
	end
	return name .. "(" .. (render(payload, vtype, ctx, depth + 1, refs)) .. ")", nil
end

-- `depth` counts structural nesting (and so decides whether a string is quoted);
-- `refs` counts `Ref` hops on this path, which is what makes a cyclic type
-- terminate without a self-reference through a plain alias looking nested.
render = function(value, atype, ctx, depth, refs)
	if depth > ctx.max_depth or refs > ctx.max_depth then
		return ELLIPSIS, nil
	end
	if value == nil or value == vim.NIL then
		return "NULL", NULL_HL
	end

	local tag, payload = type_tag(atype)
	if tag == nil then
		return untyped(value, ctx, depth)
	end

	if tag == "Ref" then
		local resolved = resolve(ctx, payload)
		if resolved == nil then
			return untyped(value, ctx, depth)
		end
		return render(value, resolved, ctx, depth, refs + 1)
	end

	if tag == "String" then
		if type(value) == "string" then
			return depth > 0 and quoted(value) or value, nil
		end
		return untyped(value, ctx, depth)
	end

	if INTEGERS[tag] then
		-- A string here is a big integer `lib/json.lua` preserved exactly, or the
		-- hex spelling of a U256. Either way it is already the right digits.
		if type(value) == "string" then
			return value, nil
		end
		if type(value) == "number" then
			return number_text(value), nil
		end
		return untyped(value, ctx, depth)
	end

	if tag == "Bool" then
		if type(value) == "boolean" then
			return tostring(value), nil
		end
		return untyped(value, ctx, depth)
	end

	if tag == "F32" or tag == "F64" then
		if type(value) == "number" then
			return tostring(value), nil
		end
		return untyped(value, ctx, depth)
	end

	if tag == "Array" then
		return render_array(value, payload, ctx, depth, refs)
	end
	if tag == "Product" then
		return render_product(value, payload, ctx, depth, refs)
	end
	if tag == "Sum" then
		return render_sum(value, payload, ctx, depth, refs)
	end

	return untyped(value, ctx, depth)
end

--------------------------------------------------------------------------------
-- Sort keys
--------------------------------------------------------------------------------

-- Sorting the grid (`ui/rows.lua`, via `lib/sort.lua`) must never compare the
-- *display* strings this module produces: `"10"` sorts before `"9"`, and an
-- ISO-8601 timestamp sorts by the year's leading digit rather than by the
-- instant. So a sort key is the same reflective walk as the render — which is
-- exactly why it lives here — stopping at comparable atoms instead of text.
--
-- A key is a list of atoms compared lexicographically, and each atom carries the
-- class it belongs to. Two atoms of different classes are ordered by class
-- alone, so a number is never compared against a string: that is what keeps a
-- mixed-type column (a sum, a big integer that arrived as digits next to one
-- that arrived as a number) from making `table.sort` raise "invalid order
-- function for sorting".
--
-- `null` is a flag on the key rather than an atom class, because NULL sorts last
-- in *both* directions: the direction orders the values, and a missing value is
-- not one. A nested NULL — one element of a product — is an atom, and does flip
-- with the direction along with the rest of the composite.

local SORT_NUMBER = 1
local SORT_TEXT = 2
local SORT_NULL = 3

---@class SpacetimeSortAtom
---@field class integer `1` numeric, `2` text, `3` absent.
---@field number? number Set when `class == 1`.
---@field text? string Set when `class == 2`.

---@class SpacetimeSortKey
---@field null boolean Sorts last in both directions.
---@field atoms SpacetimeSortAtom[] Compared lexicographically.

---@param atoms SpacetimeSortAtom[]
local function push_null(atoms)
	atoms[#atoms + 1] = { class = SORT_NULL }
end

---@param atoms SpacetimeSortAtom[]
---@param n number
local function push_number(atoms, n)
	-- NaN compares false against everything, itself included, so a key holding
	-- one would make the comparator inconsistent and `table.sort` would raise.
	-- It has no place in an order; it is keyed as absent and sorts last.
	if n ~= n then
		push_null(atoms)
		return
	end
	atoms[#atoms + 1] = { class = SORT_NUMBER, number = n }
end

---@param atoms SpacetimeSortAtom[]
---@param s string
local function push_text(atoms, s)
	atoms[#atoms + 1] = { class = SORT_TEXT, text = s }
end

---An integer that arrived as text: `lib/json.lua` hands back a run of 16 or more
---digits as a string, and a U256 arrives as hex.
---
---The number comes first so it orders against a column's small values, which
---arrive as plain numbers; the digits follow as a tiebreak, because past 2^53
---`tonumber` is lossy and two distinct identifiers would otherwise compare equal.
---@param atoms SpacetimeSortAtom[]
---@param s string
local function push_integer_text(atoms, s)
	local n = tonumber(s)
	if n ~= nil then
		push_number(atoms, n)
	end
	push_text(atoms, s)
end

-- Forward declaration: the typed walk falls back to the untyped one, which
-- recurses back through neither — but the typed one is referenced first.
---@type fun(value: any, atype: any, ctx: spacetime.ValueCtx, atoms: SpacetimeSortAtom[], depth: integer, refs: integer)
local sort_atoms

---Key a value with no type to guide it: the fallback for an absent type, an
---unresolvable `Ref`, and any value whose shape contradicts its type.
---@param value any
---@param ctx spacetime.ValueCtx
---@param atoms SpacetimeSortAtom[]
---@param depth integer
local function untyped_atoms(value, ctx, atoms, depth)
	if value == nil or value == vim.NIL then
		push_null(atoms)
		return
	end

	local kind = type(value)
	if kind == "number" then
		push_number(atoms, value)
	elseif kind == "string" then
		push_text(atoms, value)
	elseif kind == "boolean" then
		push_number(atoms, value and 1 or 0)
	elseif kind ~= "table" or depth >= ctx.max_depth then
		push_text(atoms, tostring(value))
	elseif #value > 0 then
		for i = 1, math.min(#value, ctx.max_elements) do
			untyped_atoms(value[i], ctx, atoms, depth + 1)
		end
	else
		-- `pairs` order is a hash order, so keys are sorted: two renders of the
		-- same value must key the same way.
		local keys = {}
		for key in pairs(value) do
			keys[#keys + 1] = key
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		for _, key in ipairs(keys) do
			push_text(atoms, tostring(key))
			untyped_atoms(value[key], ctx, atoms, depth + 1)
		end
	end
end

sort_atoms = function(value, atype, ctx, atoms, depth, refs)
	if depth > ctx.max_depth or refs > ctx.max_depth then
		return
	end
	if value == nil or value == vim.NIL then
		push_null(atoms)
		return
	end

	local tag, payload = type_tag(atype)
	if tag == "Ref" then
		local resolved = resolve(ctx, payload)
		if resolved ~= nil then
			sort_atoms(value, resolved, ctx, atoms, depth, refs + 1)
			return
		end
		tag = nil
	end

	if tag == "String" and type(value) == "string" then
		push_text(atoms, value)
		return
	end

	if tag ~= nil and (INTEGERS[tag] or tag == "F32" or tag == "F64") then
		if type(value) == "number" then
			push_number(atoms, value)
			return
		end
		if type(value) == "string" then
			push_integer_text(atoms, value)
			return
		end
	end

	if tag == "Bool" and type(value) == "boolean" then
		push_number(atoms, value and 1 or 0)
		return
	end

	if tag == "Array" and type(value) == "table" then
		for i = 1, math.min(#value, ctx.max_elements) do
			sort_atoms(value[i], payload, ctx, atoms, depth + 1, refs)
		end
		return
	end

	if tag == "Product" then
		local kind, field = special_of(payload)
		if kind ~= nil then
			-- A Timestamp sorts by its micros, which is the one thing its ISO text
			-- would get wrong across a year boundary; an Identity sorts by the exact
			-- digits it arrived as, which is what the grid shows.
			local scalar = unwrap_scalar(value, field)
			if kind == "timestamp" or kind == "duration" then
				local micros = to_micros(scalar)
				if micros ~= nil then
					push_number(atoms, micros)
					return
				end
			elseif type(scalar) == "string" then
				push_text(atoms, scalar)
				return
			elseif type(scalar) == "number" then
				push_number(atoms, scalar)
				return
			end
		else
			local elements = type(payload) == "table" and payload.elements or nil
			if type(elements) == "table" and type(value) == "table" then
				for i, element in ipairs(elements) do
					local name = element_name(element)
					local item = value[i]
					if item == nil and name ~= nil then
						item = value[name]
					end
					local etype = type(element) == "table" and element.algebraic_type or nil
					sort_atoms(item, etype, ctx, atoms, depth + 1, refs)
				end
				return
			end
		end
	end

	if tag == "Sum" then
		local variants = type(payload) == "table" and payload.variants or nil
		if type(variants) == "table" then
			local index, wire_tag, item = sum_variant(value, variants)
			if index ~= nil then
				local some_type, is_option = option_type(payload)
				if is_option then
					-- `none` is what the grid renders as NULL, so it keys as one.
					if index == 1 then
						sort_atoms(item, some_type, ctx, atoms, depth + 1, refs)
					else
						push_null(atoms)
					end
					return
				end
				-- Variants group before they order: the tag first, the payload after.
				push_number(atoms, wire_tag --[[@as number]])
				local variant = variants[index]
				local vtype = type(variant) == "table" and variant.algebraic_type or nil
				sort_atoms(item, vtype, ctx, atoms, depth + 1, refs)
				return
			end
		end
	end

	untyped_atoms(value, ctx, atoms, depth)
end

--------------------------------------------------------------------------------
-- Labels
--------------------------------------------------------------------------------

---@param atype any
---@param ctx spacetime.ValueCtx
---@param depth integer
---@param seen table<integer,boolean> Refs open on this path, so a cycle stops at `Ref(n)`.
---@return string
local function label_of(atype, ctx, depth, seen)
	if depth > ctx.max_depth then
		return ELLIPSIS
	end

	local tag, payload = type_tag(atype)
	if tag == nil then
		return UNKNOWN_LABEL
	end

	if tag == "Ref" then
		if type(payload) ~= "number" then
			return UNKNOWN_LABEL
		end
		-- A module's own name for the type beats anything structural we could
		-- print, so it wins whenever a full schema model was handed in.
		local alias = ctx.aliases[payload]
		if alias ~= nil then
			return alias
		end
		local resolved = (not seen[payload]) and resolve(ctx, payload) or nil
		if resolved == nil then
			return string.format("Ref(%d)", payload)
		end
		seen[payload] = true
		local out = label_of(resolved, ctx, depth + 1, seen)
		seen[payload] = nil
		return out
	end

	if tag == "Array" then
		return "Array<" .. label_of(payload, ctx, depth + 1, seen) .. ">"
	end

	if tag == "Product" then
		local kind = special_of(payload)
		if kind ~= nil then
			return SPECIAL_LABELS[kind]
		end
		local elements = type(payload) == "table" and payload.elements or nil
		if type(elements) ~= "table" or #elements == 0 then
			return "{}"
		end
		local pieces = {}
		for i, element in ipairs(elements) do
			local name = element_name(element)
			local etype = type(element) == "table" and element.algebraic_type or nil
			local inner = label_of(etype, ctx, depth + 1, seen)
			pieces[i] = name and (name .. ": " .. inner) or inner
		end
		return "{ " .. table.concat(pieces, ", ") .. " }"
	end

	if tag == "Sum" then
		local some_type, is_option = option_type(payload)
		if is_option then
			return "Option<" .. label_of(some_type, ctx, depth + 1, seen) .. ">"
		end
		local variants = type(payload) == "table" and payload.variants or nil
		if type(variants) ~= "table" or #variants == 0 then
			return "{}"
		end
		local pieces = {}
		for i, variant in ipairs(variants) do
			local name = element_name(variant)
			local vtype = type(variant) == "table" and variant.algebraic_type or nil
			if name ~= nil and is_unit(vtype) then
				-- A payload-less variant is just its name; `google: {}` is noise.
				pieces[i] = name
			else
				local inner = label_of(vtype, ctx, depth + 1, seen)
				pieces[i] = name and (name .. ": " .. inner) or inner
			end
		end
		return "{ " .. table.concat(pieces, " | ") .. " }"
	end

	-- Every primitive is its own label.
	return tag
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

---A human type name: `"U64"`, `"Timestamp"`, `"Option<String>"`,
---`"Array<String>"`, `"{ id: U64, title: String }"`, `"{ google | spacetime }"`.
---
---Never raises; anything unrecognisable is `"?"`.
---@param atype any Raw AlgebraicType, e.g. `{U64 = {}}`.
---@param types? SpacetimeSchema|table[] The schema model, or a bare typespace array.
---@param opts? SpacetimeValueOpts
---@return string
function M.label(atype, types, opts)
	local ok, out = pcall(label_of, atype, new_ctx(types, opts), 0, {})
	if not ok or type(out) ~= "string" then
		return UNKNOWN_LABEL
	end
	return out
end

---A count of microseconds as human text: `500µs`, `1.5ms`, `1m 30s`.
---
---The same renderer a `TimeDuration` column goes through, exported because the
---row grid's badge shows a query's `total_duration_micros` and there must be
---exactly one place that decides what a duration reads as.
---@param micros any A number, or the decimal string `lib/json.lua` hands back.
---@return string|nil # `nil` when `micros` is not a count of microseconds.
function M.duration(micros)
	local n = to_micros(micros)
	if n == nil then
		return nil
	end
	return duration_text(n)
end

---Micros since the Unix epoch as ISO-8601 UTC: `2026-08-09T12:34:56.970840Z`.
---
---The same renderer a `Timestamp` column goes through, exported for the same
---reason |spacetime.lib.value.duration()| is: the log view stamps each entry
---from `logs.ts`, and a timestamp must read the same there as it does in a cell.
---@param micros any A number, or the decimal string `lib/json.lua` hands back.
---@return string|nil # `nil` when `micros` is not a count of microseconds.
function M.timestamp(micros)
	local n = to_micros(micros)
	if n == nil then
		return nil
	end
	return timestamp_text(n)
end

---A raw SATS value plus its type, as display text and an optional highlight
---group.
---
---Never raises: a value that contradicts its type falls back to the untyped
---render, because one odd cell must not take the whole grid down.
---@param value any Decoded by `spacetime.lib.json`; `vim.NIL` is a JSON `null`.
---@param atype any Raw AlgebraicType, or `nil` for an untyped render.
---@param types? SpacetimeSchema|table[] The schema model, or a bare typespace array.
---@param opts? SpacetimeValueOpts
---@return string text
---@return string|nil hl `"SpacetimeNull"`, `"SpacetimeSpecial"`, or `nil`.
function M.format(value, atype, types, opts)
	local ctx = new_ctx(types, opts)
	local ok, text, hl = pcall(render, value, atype, ctx, 0, 0)
	if ok and type(text) == "string" then
		return text, hl
	end
	local safe, fallback = pcall(untyped, value, ctx, 0)
	if safe and type(fallback) == "string" then
		return fallback, nil
	end
	return "", nil
end

---A raw SATS value plus its type, as a key that can be *compared* — the sort
---order of a grid column, never its display text.
---
---`9` keys before `10` because a U64 keys as a number; a Timestamp keys as its
---micros; an Option's `none` keys as NULL. Never raises: a value that defeats
---the walk keys as NULL and sorts last, because one odd cell must not take the
---sort down.
---@param value any Decoded by `spacetime.lib.json`; `vim.NIL` is a JSON `null`.
---@param atype any Raw AlgebraicType, or `nil` for an untyped key.
---@param types? SpacetimeSchema|table[] The schema model, or a bare typespace array.
---@param opts? SpacetimeValueOpts
---@return SpacetimeSortKey
function M.sort_key(value, atype, types, opts)
	local atoms = {} ---@type SpacetimeSortAtom[]
	local ok = pcall(sort_atoms, value, atype, new_ctx(types, opts), atoms, 0, 0)
	if not ok then
		atoms = { { class = SORT_NULL } }
	end
	-- A key that is nothing but an absence *is* NULL. One nested inside a
	-- composite is only an atom of it, and flips with the sort direction.
	local null = #atoms == 0 or (#atoms == 1 and atoms[1].class == SORT_NULL)
	return { null = null, atoms = atoms }
end

---Three-way comparison of two sort keys: `-1`, `0` or `1`.
---
---A total order, which is the whole point — `table.sort` raises on a comparator
---that contradicts itself. Atoms are compared class first, so no comparison is
---ever made between a number and a string, and a key that is a prefix of another
---sorts before it. A NULL key compares greater than any other, but callers
---wanting "NULL last in both directions" must handle `null` *before* the
---direction is applied.
---@param a SpacetimeSortKey
---@param b SpacetimeSortKey
---@return integer
function M.compare_keys(a, b)
	if a.null ~= b.null then
		return a.null and 1 or -1
	end
	if a.null then
		return 0
	end

	local shared = math.min(#a.atoms, #b.atoms)
	for i = 1, shared do
		local x, y = a.atoms[i], b.atoms[i]
		if x.class ~= y.class then
			return x.class < y.class and -1 or 1
		end
		if x.class == SORT_NUMBER then
			if x.number ~= y.number then
				return (x.number or 0) < (y.number or 0) and -1 or 1
			end
		elseif x.class == SORT_TEXT then
			if x.text ~= y.text then
				return (x.text or "") < (y.text or "") and -1 or 1
			end
		end
	end
	if #a.atoms ~= #b.atoms then
		return #a.atoms < #b.atoms and -1 or 1
	end
	return 0
end

---`M.format` in the shape `spacetime.ui.grid` consumes.
---@param value any
---@param atype any
---@param types? SpacetimeSchema|table[]
---@param opts? SpacetimeValueOpts
---@return SpacetimeGridCell
function M.cell(value, atype, types, opts)
	local text, hl = M.format(value, atype, types, opts)
	return { text = text, hl = hl }
end

return M
