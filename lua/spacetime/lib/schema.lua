-- The module definition, in either wire shape, normalised into one model.
--
-- `GET /v1/database/{db}/schema?version=` answers with two quite different
-- documents. v10 (SpacetimeDB 2.0.4 and later) is `{sections: [...]}`, one
-- single-key tagged object per section; v9 is a flat struct with views and
-- column defaults buried in `misc_exports`. v10 is the target because it is the
-- only one that carries reducer **visibility** — on the real module 5 of 19
-- reducers are `Private`, and a v9-based browser would offer all 19 as callable.
-- See ROADMAP.md, "Why schema v10 (with a v9 fallback)".
--
-- `M.parse` detects which arrived and produces the same model either way, so
-- nothing above this module has to care. The version is recorded on the model
-- purely so the UI can say what it is talking to.
--
-- Three things this file exists to get right:
--
-- 1. **Unrecognised sections are skipped in silence.** `RawModuleDefV10Section`
--    is `#[non_exhaustive]` upstream and the checkout already has `Procedures`,
--    `HttpHandlers`, `HttpRoutes`, `ViewPrimaryKeys`, `Submodules` and
--    `CaseConversionPolicy` queued up. Sections are bucketed by tag and then
--    looked up by name, so a tag nobody asks for is never seen.
-- 2. **`product_type_ref` is 0-based; Lua is 1-based.** `M.type_at` is the one
--    accessor that adds the one, and `typespace` is never indexed anywhere else
--    in the file.
-- 3. **Joins go through canonical names, never source names.** In the live
--    fixture, `Schedules[].table_name` is `materialize_tick` while the table's
--    `source_name` is `materializeTick`, and `LifeCycleReducers[].function_name`
--    is `on_connect` while the reducer's `source_name` is `onConnect`. Joining
--    on the source spelling silently loses both.
--
-- Scope: this module is **pure** — it takes an already-decoded value and makes
-- no `vim.*` call at all (a JSON `null` decodes to `vim.NIL`, which is userdata,
-- so the `type(x) == "table"` / `"string"` guards below reject it without ever
-- naming the sentinel). The HTTP request itself belongs to `lib/client.lua`,
-- which does not exist yet; what lives here is the *negotiation policy* —
-- `M.VERSIONS` and `M.should_fallback` — as pure functions for that module to
-- wire up.

local M = {}

---@class SpacetimeSchema
---@field version integer `9` or `10`.
---@field typespace table[] Raw AlgebraicTypes. Index with `M.type_at`, never directly.
---@field types SpacetimeSchemaTypeAlias[] Named type aliases, in wire order.
---@field tables SpacetimeSchemaTable[] Sorted by `canonical`.
---@field views SpacetimeSchemaView[] Sorted by `canonical`.
---@field reducers SpacetimeSchemaReducer[] Sorted by `canonical`.
---@field schedules SpacetimeSchemaSchedule[]
---@field lifecycle table<string,string> `"Init"`/`"OnConnect"`/`"OnDisconnect"` -> canonical function name.
---@field names SpacetimeSchemaNames

---@class SpacetimeSchemaNames
---@field tables { to_canonical: table<string,string>, to_source: table<string,string> }
---@field functions { to_canonical: table<string,string>, to_source: table<string,string> }

---@class SpacetimeSchemaTypeAlias
---@field name string
---@field scope string[] Module path segments; empty at the top level.
---@field ref integer 0-based typespace index.
---@field custom_ordering boolean

---@class SpacetimeSchemaParam
---@field name string|nil Absent when the wire sent `{"none":[]}`.
---@field type table|nil Raw AlgebraicType.

---@class SpacetimeSchemaColumn
---@field id integer 0-based.
---@field name string Canonical in both versions; `"col<N>"` if the wire sent no name.
---@field type table|nil Raw AlgebraicType.
---@field is_primary_key boolean
---@field is_autoinc boolean From the table's `sequences[].column`.
---@field default string|nil Hex-encoded default value, or `nil`.

---@class SpacetimeSchemaIndex
---@field name string|nil
---@field accessor string|nil
---@field algorithm table|nil Raw, e.g. `{BTree = {0}}`.

---@class SpacetimeSchemaConstraint
---@field name string|nil
---@field data table|nil Raw, e.g. `{Unique = {columns = {0}}}`.

---@class SpacetimeSchemaSchedule
---@field name string|nil
---@field table string Canonical table name.
---@field column integer 0-based schedule-at column.
---@field reducer string Canonical function name.

---@class SpacetimeSchemaTable
---@field name string Display name: v10 `source_name` (`"ledgerEntry"`), v9 `name`.
---@field canonical string SQL name (`"ledger_entry"`). Query this, display `name`.
---@field product_type_ref integer|nil 0-based.
---@field columns SpacetimeSchemaColumn[] In column order.
---@field primary_key integer[] 0-based column ids.
---@field table_type string Raw tag, `"User"` or `"System"`.
---@field access string Raw tag, `"Public"` or `"Private"`.
---@field is_event boolean v10 only; `false` on v9.
---@field is_system boolean `table_type == "System"` or a member of `M.SYSTEM_TABLES`.
---@field is_view boolean Always `false`.
---@field indexes SpacetimeSchemaIndex[]
---@field constraints SpacetimeSchemaConstraint[]
---@field schedule SpacetimeSchemaSchedule|nil

---@class SpacetimeSchemaView
---@field name string Display name.
---@field canonical string
---@field index integer|nil View index as sent.
---@field is_public boolean
---@field is_anonymous boolean
---@field params SpacetimeSchemaParam[]
---@field return_type table|nil Raw AlgebraicType.
---@field product_type_ref integer|nil From `return_type.Array.Ref`.
---@field columns SpacetimeSchemaColumn[] Resolved like a table's; `{}` if unresolvable.
---@field is_view boolean Always `true`.

---@class SpacetimeSchemaReducer
---@field name string Display name (v10 `"onConnect"`, v9 `"on_connect"`).
---@field canonical string
---@field params SpacetimeSchemaParam[]
---@field visibility string|nil `"ClientCallable"`/`"Private"`; **`nil` on v9**.
---@field ok_return_type table|nil v10 only.
---@field err_return_type table|nil v10 only.
---@field lifecycle string|nil `"Init"`, `"OnConnect"` or `"OnDisconnect"`.

-- Schema versions to try, most capable first. `?version=` is required and
-- accepts only these two: omitting it, or sending `11`, is a 400 rather than a
-- default.
---@type integer[]
M.VERSIONS = { 10, 9 }

-- SpacetimeDB's system tables. This is a **constant**, not something read out of
-- the schema: the module definition describes only the module's own tables, and
-- every table in both live fixtures is `table_type = "User"`. Without this list
-- the sidebar's "system" group would always be empty.
---@type string[]
M.SYSTEM_TABLES = {
	"st_table",
	"st_column",
	"st_index",
	"st_constraint",
	"st_sequence",
	"st_client",
	"st_scheduled",
	"st_module",
	"st_var",
	"st_view",
}

---@type table<string,boolean>
local SYSTEM_TABLE_SET = {}
for _, name in ipairs(M.SYSTEM_TABLES) do
	SYSTEM_TABLE_SET[name] = true
end

--------------------------------------------------------------------------------
-- Wire-shape helpers
--------------------------------------------------------------------------------

---The single key of a tagged object, e.g. `{"Private":[]}` -> `"Private"`.
---
---Tolerates a bare string (older servers have been seen sending one) and
---returns `nil` for anything else, including an array, whose first key is the
---number `1`.
---@param value any
---@return string|nil
local function tag(value)
	if type(value) == "string" then
		return value
	end
	if type(value) ~= "table" then
		return nil
	end
	local key = next(value)
	return type(key) == "string" and key or nil
end

---Unwrap an Option: `{"some": x}` -> `x`, `{"none": []}` -> `nil`.
---
---A JSON `null` decodes to `vim.NIL`, which is userdata rather than a table, so
---it is rejected here as absent without this module ever naming the sentinel.
---@param value any
---@return any
local function opt(value)
	if type(value) ~= "table" then
		return nil
	end
	local some = value.some
	if some == nil or type(some) == "userdata" then
		return nil
	end
	return some
end

---`value` when it is a table, otherwise an empty one, so callers can `ipairs`
---an absent array without a guard of their own.
---@param value any
---@return table
local function list(value)
	if type(value) ~= "table" then
		return {}
	end
	return value
end

---`value` when it is a string, otherwise `nil`.
---@param value any
---@return string|nil
local function text(value)
	return type(value) == "string" and value or nil
end

---The `source_name` (v10) or `name` (v9) of a named sub-object, unwrapping the
---Option both versions wrap index, constraint, sequence and schedule names in.
---
---Accepting either key is what lets one code path handle both versions: the two
---spellings never collide, because no payload carries both.
---@param value any
---@return string|nil
local function named(value)
	if type(value) ~= "table" then
		return nil
	end
	local name = opt(value.source_name)
	if name == nil then
		name = opt(value.name)
	end
	if name == nil then
		name = value.source_name
	end
	if name == nil then
		name = value.name
	end
	return text(name)
end

---Normalise a `{elements: [...]}` parameter list.
---@param raw any
---@return SpacetimeSchemaParam[]
local function param_list(raw)
	local out = {}
	if type(raw) ~= "table" then
		return out
	end
	for i, element in ipairs(list(raw.elements)) do
		if type(element) == "table" then
			out[i] = {
				name = text(opt(element.name)),
				type = type(element.algebraic_type) == "table" and element.algebraic_type or nil,
			}
		else
			out[i] = { name = nil, type = nil }
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Public accessors
--------------------------------------------------------------------------------

---Resolve a 0-based `product_type_ref` against the typespace.
---
---**The only place the off-by-one is handled.** Every other reference to
---`model.typespace` in this file goes through here, and callers should do the
---same rather than adding the one themselves.
---@param model SpacetimeSchema
---@param ref integer 0-based typespace index, exactly as it appears on the wire.
---@return table|nil # The raw AlgebraicType, or `nil` when the ref is out of range.
function M.type_at(model, ref)
	if type(ref) ~= "number" then
		return nil
	end
	local entry = model.typespace[ref + 1]
	return type(entry) == "table" and entry or nil
end

---Whether `name` is one of SpacetimeDB's own tables.
---@param name any
---@return boolean
function M.is_system_table(name)
	return type(name) == "string" and SYSTEM_TABLE_SET[name] == true
end

---Whether a reducer may be called from a client.
---
---**Unknown visibility means callable.** v9 carries no visibility field at all,
---and hiding every reducer on an older server would look like data loss rather
---than like a missing field.
---@param reducer SpacetimeSchemaReducer|table
---@return boolean
function M.is_callable(reducer)
	if type(reducer) ~= "table" then
		return false
	end
	return reducer.visibility ~= "Private"
end

---Find a table by either spelling of its name.
---
---The SQL layer accepts both `ledgerEntry` and `ledger_entry`, and so does
---this — the sidebar displays the source spelling while everything else works
---in canonical names.
---@param model SpacetimeSchema
---@param name any
---@return SpacetimeSchemaTable|nil
function M.table_by_name(model, name)
	if type(name) ~= "string" then
		return nil
	end
	for _, entry in ipairs(model.tables) do
		if entry.canonical == name or entry.name == name then
			return entry
		end
	end
	return nil
end

---Find a table **or a view** by either spelling of its name.
---
---Views are queryable exactly as tables are, so everything the user can name —
---`:SpacetimeRows`, `:SpacetimeSchema`, completion — has to look in both lists.
---Tables win a name collision, which is the SQL layer's own precedence.
---
---Tolerant of a half-built model: a `model` that is not a table, or one whose
---`tables`/`views` are missing, simply finds nothing. That matters because the
---one caller that reads a *cached* model cannot be sure what is under the key.
---@param model SpacetimeSchema|table|nil
---@param name any
---@return SpacetimeSchemaTable|SpacetimeSchemaView|nil
function M.entry_by_name(model, name)
	if type(model) ~= "table" or type(name) ~= "string" then
		return nil
	end

	---@param group any
	---@return any
	local function find(group)
		for _, entry in ipairs(list(group)) do
			if type(entry) == "table" and (entry.canonical == name or entry.name == name) then
				return entry
			end
		end
		return nil
	end

	-- Two calls rather than a loop over `{model.tables, model.views}`: `ipairs`
	-- stops at the first `nil`, so a model with no `tables` key would silently
	-- never look at its views (tests/CLAUDE.md).
	return find(model.tables) or find(model.views)
end

---Whether a failed schema request should be retried at the next version down.
---
---Mirrors the CLI's own negotiation (`crates/cli/src/api.rs`): a server that
---does not know `?version=10` rejects it as a 4xx. A 5xx is the server being
---unwell — in particular a paused database answers 503 — and retrying that
---would only ask a sick server the same question twice.
---@param status any HTTP status code.
---@return boolean
function M.should_fallback(status)
	return type(status) == "number" and status >= 400 and status < 500
end

--------------------------------------------------------------------------------
-- Shared normalisation
--------------------------------------------------------------------------------

---The columns of a product type, resolved through the typespace.
---
---A ref that resolves to nothing, or to something that is not a `Product`,
---yields no columns rather than an error: a schema the UI can only partly
---render still beats a stack trace.
---@param model SpacetimeSchema
---@param ref integer|nil 0-based.
---@param pk table<integer,boolean> Primary-key column ids.
---@param autoinc table<integer,boolean> Sequence-backed column ids.
---@param defaults table<integer,string> Column id -> hex-encoded default.
---@return SpacetimeSchemaColumn[]
local function columns_of(model, ref, pk, autoinc, defaults)
	local columns = {}
	local ty = ref ~= nil and M.type_at(model, ref) or nil
	if type(ty) ~= "table" or type(ty.Product) ~= "table" then
		return columns
	end

	for i, element in ipairs(list(ty.Product.elements)) do
		local id = i - 1
		local name = type(element) == "table" and text(opt(element.name)) or nil
		columns[i] = {
			id = id,
			-- Defensive: neither fixture has an unnamed element, but display
			-- code must never be handed a nil heading.
			name = name or ("col" .. id),
			type = type(element) == "table" and type(element.algebraic_type) == "table" and element.algebraic_type
				or nil,
			is_primary_key = pk[id] == true,
			is_autoinc = autoinc[id] == true,
			default = defaults[id],
		}
	end

	return columns
end

---Normalise the index and constraint lists, which differ between versions only
---in whether the name key is `source_name` or `name`.
---@param raw any
---@return SpacetimeSchemaIndex[]
local function indexes_of(raw)
	local out = {}
	for i, index in ipairs(list(raw)) do
		out[i] = {
			name = named(index),
			accessor = type(index) == "table" and text(opt(index.accessor_name)) or nil,
			algorithm = type(index) == "table" and type(index.algorithm) == "table" and index.algorithm or nil,
		}
	end
	return out
end

---@param raw any
---@return SpacetimeSchemaConstraint[]
local function constraints_of(raw)
	local out = {}
	for i, constraint in ipairs(list(raw)) do
		out[i] = {
			name = named(constraint),
			data = type(constraint) == "table" and type(constraint.data) == "table" and constraint.data or nil,
		}
	end
	return out
end

---Build one normalised table from a version-neutral description.
---@param model SpacetimeSchema
---@param spec table `{name, canonical, raw, defaults}` — `raw` is the wire table.
---@return SpacetimeSchemaTable
local function make_table(model, spec)
	local raw = spec.raw

	local primary_key = {}
	local pk = {}
	for _, id in ipairs(list(raw.primary_key)) do
		if type(id) == "number" then
			primary_key[#primary_key + 1] = id
			pk[id] = true
		end
	end

	local autoinc = {}
	for _, sequence in ipairs(list(raw.sequences)) do
		if type(sequence) == "table" and type(sequence.column) == "number" then
			autoinc[sequence.column] = true
		end
	end

	local ref = type(raw.product_type_ref) == "number" and raw.product_type_ref or nil
	local table_type = tag(raw.table_type) or "User"

	return {
		name = spec.name,
		canonical = spec.canonical,
		product_type_ref = ref,
		columns = columns_of(model, ref, pk, autoinc, spec.defaults or {}),
		primary_key = primary_key,
		table_type = table_type,
		access = tag(raw.table_access) or "Private",
		is_event = raw.is_event == true,
		is_system = table_type == "System" or M.is_system_table(spec.canonical),
		is_view = false,
		indexes = indexes_of(raw.indexes),
		constraints = constraints_of(raw.constraints),
		schedule = nil,
	}
end

---Build one normalised view. Identical in both versions apart from the name
---key, which the caller has already resolved.
---@param model SpacetimeSchema
---@param raw table
---@param name string
---@param canonical string
---@return SpacetimeSchemaView
local function make_view(model, raw, name, canonical)
	local return_type = type(raw.return_type) == "table" and raw.return_type or nil

	-- A view returns `Array<Ref>`; that `Ref` is the product describing its rows.
	local ref
	if return_type ~= nil and type(return_type.Array) == "table" and type(return_type.Array.Ref) == "number" then
		ref = return_type.Array.Ref
	end

	return {
		name = name,
		canonical = canonical,
		index = type(raw.index) == "number" and raw.index or nil,
		is_public = raw.is_public == true,
		is_anonymous = raw.is_anonymous == true,
		params = param_list(raw.params),
		return_type = return_type,
		product_type_ref = ref,
		columns = columns_of(model, ref, {}, {}, {}),
		is_view = true,
	}
end

---Normalise a `Types`/`types` entry. The inner name object is `{scope, name}` on
---v9 and `{scope, source_name}` on v10.
---@param raw any
---@return SpacetimeSchemaTypeAlias|nil
local function make_type_alias(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local holder = type(raw.source_name) == "table" and raw.source_name or raw.name
	if type(holder) ~= "table" then
		return nil
	end
	local name = text(holder.source_name) or text(holder.name)
	if name == nil then
		return nil
	end
	local scope = {}
	for i, segment in ipairs(list(holder.scope)) do
		scope[i] = tostring(segment)
	end
	return {
		name = name,
		scope = scope,
		ref = type(raw.ty) == "number" and raw.ty or -1,
		custom_ordering = raw.custom_ordering == true,
	}
end

---Sort by canonical name.
---
---v10 lists tables, views and reducers in module order and v9 alphabetically;
---sorting both is what makes the two models directly comparable, and it is also
---the order the sidebar wants.
---@param entries table[]
local function sort_by_canonical(entries)
	table.sort(entries, function(a, b)
		return a.canonical < b.canonical
	end)
end

---Record a source <-> canonical pair in one half of the names map.
---@param map { to_canonical: table<string,string>, to_source: table<string,string> }
---@param source string
---@param canonical string
local function record_name(map, source, canonical)
	map.to_canonical[source] = canonical
	map.to_source[canonical] = source
end

---An empty names map.
---@return SpacetimeSchemaNames
local function new_names()
	return {
		tables = { to_canonical = {}, to_source = {} },
		functions = { to_canonical = {}, to_source = {} },
	}
end

---Hang each schedule off its table, joining on the **canonical** table name.
---@param model SpacetimeSchema
local function attach_schedules(model)
	local by_canonical = {}
	for _, entry in ipairs(model.tables) do
		by_canonical[entry.canonical] = entry
	end
	for _, schedule in ipairs(model.schedules) do
		local entry = by_canonical[schedule.table]
		if entry ~= nil then
			entry.schedule = schedule
		end
	end
end

--------------------------------------------------------------------------------
-- v10: the sectioned shape
--------------------------------------------------------------------------------

---@param value table The decoded `{sections: [...]}` document.
---@return SpacetimeSchema
local function parse_v10(value)
	-- Pass 1: bucket the sections by tag. Order on the wire is not guaranteed —
	-- in the live fixture `Typespace` comes first but `ExplicitNames` comes
	-- *last*, and both `Tables` and `Reducers` need the name map. Unknown tags
	-- land in the bucket and are simply never looked up, which is the
	-- silent-skip requirement.
	local sections = {}
	for _, section in ipairs(list(value.sections)) do
		local key = tag(section)
		if key ~= nil then
			sections[key] = section[key]
		end
	end

	-- Pass 2: build in dependency order, whatever order the wire used.
	---@type SpacetimeSchema
	local model = {
		version = 10,
		typespace = list(type(sections.Typespace) == "table" and sections.Typespace.types or nil),
		types = {},
		tables = {},
		views = {},
		reducers = {},
		schedules = {},
		lifecycle = {},
		names = new_names(),
	}

	local names = model.names
	for _, entry in ipairs(list(type(sections.ExplicitNames) == "table" and sections.ExplicitNames.entries or nil)) do
		local kind = tag(entry)
		local pair = kind ~= nil and entry[kind] or nil
		if type(pair) == "table" then
			local source, canonical = text(pair.source_name), text(pair.canonical_name)
			if source ~= nil and canonical ~= nil then
				if kind == "Table" then
					record_name(names.tables, source, canonical)
				elseif kind == "Function" then
					-- Views are functions too, so this map covers both.
					record_name(names.functions, source, canonical)
				end
			end
		end
	end

	for _, raw in ipairs(list(sections.Types)) do
		local alias = make_type_alias(raw)
		if alias ~= nil then
			model.types[#model.types + 1] = alias
		end
	end

	for _, raw in ipairs(list(sections.Tables)) do
		local name = text(raw.source_name)
		if name ~= nil then
			local defaults = {}
			for _, default in ipairs(list(raw.default_values)) do
				if type(default) == "table" and type(default.col_id) == "number" then
					defaults[default.col_id] = text(default.value)
				end
			end
			model.tables[#model.tables + 1] = make_table(model, {
				name = name,
				canonical = names.tables.to_canonical[name] or name,
				raw = raw,
				defaults = defaults,
			})
		end
	end

	for _, raw in ipairs(list(sections.Views)) do
		local name = text(raw.source_name)
		if name ~= nil then
			model.views[#model.views + 1] = make_view(model, raw, name, names.functions.to_canonical[name] or name)
		end
	end

	for _, raw in ipairs(list(sections.Reducers)) do
		local name = text(raw.source_name)
		if name ~= nil then
			model.reducers[#model.reducers + 1] = {
				name = name,
				canonical = names.functions.to_canonical[name] or name,
				params = param_list(raw.params),
				visibility = tag(raw.visibility),
				ok_return_type = type(raw.ok_return_type) == "table" and raw.ok_return_type or nil,
				err_return_type = type(raw.err_return_type) == "table" and raw.err_return_type or nil,
				lifecycle = nil,
			}
		end
	end

	for _, raw in ipairs(list(sections.Schedules)) do
		local table_name, reducer = text(raw.table_name), text(raw.function_name)
		if table_name ~= nil and reducer ~= nil then
			model.schedules[#model.schedules + 1] = {
				name = named(raw),
				table = table_name,
				column = type(raw.schedule_at_col) == "number" and raw.schedule_at_col or 0,
				reducer = reducer,
			}
		end
	end

	for _, raw in ipairs(list(sections.LifeCycleReducers)) do
		local kind = type(raw) == "table" and tag(raw.lifecycle_spec) or nil
		local reducer = type(raw) == "table" and text(raw.function_name) or nil
		if kind ~= nil and reducer ~= nil then
			model.lifecycle[kind] = reducer
		end
	end

	-- The join trap: `function_name` is `on_connect` while the reducer is
	-- displayed as `onConnect`, so this must match on canonical names.
	for _, entry in ipairs(model.reducers) do
		for kind, reducer in pairs(model.lifecycle) do
			if entry.canonical == reducer then
				entry.lifecycle = kind
			end
		end
	end

	sort_by_canonical(model.tables)
	sort_by_canonical(model.views)
	sort_by_canonical(model.reducers)
	attach_schedules(model)

	return model
end

--------------------------------------------------------------------------------
-- v9: the flat shape
--------------------------------------------------------------------------------

---@param value table The decoded flat document.
---@return SpacetimeSchema
local function parse_v9(value)
	---@type SpacetimeSchema
	local model = {
		version = 9,
		typespace = list(type(value.typespace) == "table" and value.typespace.types or nil),
		types = {},
		tables = {},
		views = {},
		reducers = {},
		schedules = {},
		lifecycle = {},
		names = new_names(),
	}

	-- v9 names are already canonical, so source and canonical coincide. Building
	-- the map anyway means consumers never have to branch on version.
	local names = model.names

	-- `misc_exports` mixes views and column defaults, and will grow more kinds;
	-- anything that is neither is skipped in silence, exactly like an unknown
	-- v10 section.
	local views, defaults = {}, {}
	for _, entry in ipairs(list(value.misc_exports)) do
		local kind = tag(entry)
		local payload = kind ~= nil and entry[kind] or nil
		if type(payload) == "table" then
			if kind == "View" then
				views[#views + 1] = payload
			elseif kind == "ColumnDefaultValue" then
				local table_name = text(payload.table)
				if table_name ~= nil and type(payload.col_id) == "number" then
					defaults[table_name] = defaults[table_name] or {}
					defaults[table_name][payload.col_id] = text(payload.value)
				end
			end
		end
	end

	for _, raw in ipairs(list(value.types)) do
		local alias = make_type_alias(raw)
		if alias ~= nil then
			model.types[#model.types + 1] = alias
		end
	end

	for _, raw in ipairs(list(value.tables)) do
		local name = text(raw.name)
		if name ~= nil then
			record_name(names.tables, name, name)
			model.tables[#model.tables + 1] =
				make_table(model, { name = name, canonical = name, raw = raw, defaults = defaults[name] or {} })

			-- v9 hangs the schedule off the table rather than giving it a section.
			local schedule = opt(raw.schedule)
			if type(schedule) == "table" then
				local reducer = text(schedule.reducer_name)
				if reducer ~= nil then
					model.schedules[#model.schedules + 1] = {
						name = named(schedule),
						table = name,
						column = type(schedule.scheduled_at_column) == "number" and schedule.scheduled_at_column or 0,
						reducer = reducer,
					}
				end
			end
		end
	end

	for _, raw in ipairs(views) do
		local name = text(raw.name)
		if name ~= nil then
			record_name(names.functions, name, name)
			model.views[#model.views + 1] = make_view(model, raw, name, name)
		end
	end

	for _, raw in ipairs(list(value.reducers)) do
		local name = text(raw.name)
		if name ~= nil then
			record_name(names.functions, name, name)
			-- `lifecycle` is an Option around a tagged object; `visibility` has no
			-- v9 equivalent at all and stays nil, which `M.is_callable` reads as
			-- "callable".
			local lifecycle = tag(opt(raw.lifecycle))
			if lifecycle ~= nil then
				model.lifecycle[lifecycle] = name
			end
			model.reducers[#model.reducers + 1] = {
				name = name,
				canonical = name,
				params = param_list(raw.params),
				visibility = nil,
				ok_return_type = nil,
				err_return_type = nil,
				lifecycle = lifecycle,
			}
		end
	end

	sort_by_canonical(model.tables)
	sort_by_canonical(model.views)
	sort_by_canonical(model.reducers)
	attach_schedules(model)

	return model
end

--------------------------------------------------------------------------------

---Normalise a decoded schema response, in either wire shape, into one model.
---
---Detection is structural rather than by a version field, because neither
---document carries one: v10 has `sections`, v9 has `tables`/`typespace`.
---
---This is the one place that raises. Everything below it is tolerant — a
---missing section yields an empty list and an unresolvable `product_type_ref`
---yields no columns — because a schema we can only partly render is still worth
---showing.
---@param value table Already decoded, e.g. by `spacetime.lib.json.decode`.
---@return SpacetimeSchema
function M.parse(value)
	if type(value) == "table" then
		if type(value.sections) == "table" then
			return parse_v10(value)
		end
		if type(value.tables) == "table" or type(value.typespace) == "table" then
			return parse_v9(value)
		end
	end
	error("spacetime.lib.schema: unrecognised schema payload", 2)
end

return M
