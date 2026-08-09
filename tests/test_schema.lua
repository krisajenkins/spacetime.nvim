-- Tests for the schema normaliser.
--
-- No child Neovim: the module is pure logic, like `tests/test_sql.lua`. Both
-- fixtures are the *same* live module captured in both wire shapes, so the
-- headline case is not "does v9 parse" but "does v9 normalise to exactly what
-- v10 normalises to".
--
-- The two fixtures are 95 KB and 74 KB, so each is decoded once into a
-- file-local upvalue and shared across the cases.
local schema = require("spacetime.lib.schema")
local json = require("spacetime.lib.json")
local read = require("tests.helpers.fixtures").read
local expect = MiniTest.expect

local T = MiniTest.new_set()

local cache = {}

---The decoded (but unparsed) fixture, so a case may mutate a fresh copy.
---@param version integer
---@return table
local function decoded(version)
	return json.decode(read("schema_v" .. version .. ".json"))
end

---The parsed model for a fixture version, decoded at most once per run.
---@param version integer
---@return SpacetimeSchema
local function model(version)
	if cache[version] == nil then
		cache[version] = schema.parse(decoded(version))
	end
	return cache[version]
end

---@param entries table[] Anything with a `name` field.
---@param name string
---@return table
local function by_name(entries, name)
	for _, entry in ipairs(entries) do
		if entry.name == name then
			return entry
		end
	end
	error("no entry named " .. name)
end

---@param entries table[] Anything with a `canonical` field.
---@param canonical string
---@return table
local function by_canonical(entries, canonical)
	for _, entry in ipairs(entries) do
		if entry.canonical == canonical then
			return entry
		end
	end
	error("no entry canonically named " .. canonical)
end

---@param columns SpacetimeSchemaColumn[]
---@return string[]
local function column_names(columns)
	local names = {}
	for i, column in ipairs(columns) do
		names[i] = column.name
	end
	return names
end

T["v10 yields 12 tables, 4 views and 19 reducers"] = function()
	local m = model(10)
	expect.equality(m.version, 10)
	expect.equality(#m.tables, 12)
	expect.equality(#m.views, 4)
	expect.equality(#m.reducers, 19)
end

T["v9 yields the same counts"] = function()
	local m = model(9)
	expect.equality(m.version, 9)
	expect.equality(#m.tables, 12)
	expect.equality(#m.views, 4)
	expect.equality(#m.reducers, 19)
end

T["v9 and v10 normalise to the same tables and columns"] = function()
	-- Index and constraint *names* are deliberately left out: v9 says
	-- `security_security_id_idx_btree` where v10 says
	-- `security_securityId_idx_btree`, so those legitimately differ.
	local function project(m)
		local out = {}
		for i, entry in ipairs(m.tables) do
			local autoinc = {}
			for _, column in ipairs(entry.columns) do
				if column.is_autoinc then
					autoinc[#autoinc + 1] = column.id
				end
			end
			out[i] = {
				canonical = entry.canonical,
				columns = column_names(entry.columns),
				primary_key = entry.primary_key,
				autoinc = autoinc,
			}
		end
		return out
	end

	expect.equality(project(model(9)), project(model(10)))
end

T["product_type_ref resolves through the 0-based index"] = function()
	local m = model(10)
	-- Ref 12 catches an off-by-minus-one, ref 0 catches an off-by-plus-one.
	expect.equality(by_name(m.tables, "ledgerEntry").product_type_ref, 12)
	expect.equality(
		column_names(by_name(m.tables, "ledgerEntry").columns),
		{ "entry_id", "transaction_id", "security_id", "amount", "account" }
	)
	expect.equality(by_name(m.tables, "user").product_type_ref, 0)
	expect.equality(
		column_names(by_name(m.tables, "user").columns),
		{ "id", "primary_email", "display_name", "picture_url", "is_admin", "created_at" }
	)

	-- The accessor itself, since nothing else in the module may add the one.
	expect.equality(schema.type_at(m, 12), m.typespace[13])
	expect.equality(schema.type_at(m, #m.typespace), nil)
end

T["v10 populates visibility, v9 leaves it nil"] = function()
	local counts = { ClientCallable = 0, Private = 0 }
	for _, reducer in ipairs(model(10).reducers) do
		counts[reducer.visibility] = (counts[reducer.visibility] or 0) + 1
	end
	expect.equality(counts, { ClientCallable = 14, Private = 5 })

	for _, name in ipairs({ "init", "onConnect", "onDisconnect", "run_materialize_tick", "run_redemption_tick" }) do
		expect.equality(by_name(model(10).reducers, name).visibility, "Private")
	end
	expect.equality(by_name(model(10).reducers, "book").visibility, "ClientCallable")

	for _, reducer in ipairs(model(9).reducers) do
		expect.equality(reducer.visibility, nil)
	end
end

T["unknown visibility is assumed callable"] = function()
	local callable = 0
	for _, reducer in ipairs(model(9).reducers) do
		expect.equality(schema.is_callable(reducer), true)
		callable = callable + 1
	end
	expect.equality(callable, 19)

	callable = 0
	for _, reducer in ipairs(model(10).reducers) do
		if schema.is_callable(reducer) then
			callable = callable + 1
		end
	end
	expect.equality(callable, 14)
end

T["an unrecognised section is ignored without error"] = function()
	local value = decoded(10)
	table.insert(value.sections, { Procedures = {} })
	table.insert(value.sections, { NotARealSection = { "x" } })

	local parsed
	expect.no_error(function()
		parsed = schema.parse(value)
	end)
	expect.equality(#parsed.tables, 12)
	expect.equality(#parsed.reducers, 19)
end

T["ExplicitNames maps source to canonical"] = function()
	local names = model(10).names
	expect.equality(names.tables.to_canonical.ledgerEntry, "ledger_entry")
	expect.equality(names.tables.to_source.ledger_entry, "ledgerEntry")
	-- Views are functions too, so both live in the same half of the map.
	expect.equality(names.functions.to_canonical.onConnect, "on_connect")
	expect.equality(names.functions.to_canonical.meView, "me_view")

	local entry = by_name(model(10).tables, "ledgerEntry")
	expect.equality(entry.canonical, "ledger_entry")
	-- Either spelling finds it, because SQL accepts either.
	expect.equality(schema.table_by_name(model(10), "ledger_entry"), entry)
	expect.equality(schema.table_by_name(model(10), "ledgerEntry"), entry)
	expect.equality(schema.table_by_name(model(10), "nope"), nil)
end

T["v9 names are their own canonical"] = function()
	local m = model(9)
	expect.equality(m.names.tables.to_canonical.ledger_entry, "ledger_entry")
	expect.equality(m.names.tables.to_source.ledger_entry, "ledger_entry")
	for _, entry in ipairs(m.tables) do
		expect.equality(entry.name, entry.canonical)
	end
end

T["autoinc comes from sequences"] = function()
	for _, version in ipairs({ 9, 10 }) do
		local entry = by_canonical(model(version).tables, "ledger_entry")
		expect.equality(entry.columns[1].name, "entry_id")
		expect.equality(entry.columns[1].id, 0)
		expect.equality(entry.columns[1].is_autoinc, true)

		for _, column in ipairs(by_canonical(model(version).tables, "security").columns) do
			expect.equality(column.is_autoinc, false)
		end
	end
end

T["primary keys land on both the table and its column"] = function()
	for _, version in ipairs({ 9, 10 }) do
		for _, entry in ipairs(model(version).tables) do
			expect.equality(entry.primary_key, { 0 })
			expect.equality(entry.columns[1].is_primary_key, true)
			expect.equality(entry.columns[2].is_primary_key, false)
		end
	end
end

T["column defaults are lifted from both shapes"] = function()
	-- v10 carries these inline as `default_values`; v9 buries them in
	-- `misc_exports` as `ColumnDefaultValue`.
	for _, version in ipairs({ 9, 10 }) do
		local entry = by_canonical(model(version).tables, "class_instance")
		expect.equality(entry.columns[10].id, 9)
		expect.equality(entry.columns[10].name, "booking_count")
		expect.equality(entry.columns[10].default, "00000000")
		for _, column in ipairs(entry.columns) do
			if column.id ~= 9 then
				expect.equality(column.default, nil)
			end
		end
	end
end

T["views resolve their columns through the return type"] = function()
	for _, version in ipairs({ 9, 10 }) do
		local m = model(version)
		expect.equality(#m.views, 4)

		local me = by_canonical(m.views, "me_view")
		expect.equality(me.product_type_ref, 26)
		expect.equality(me.is_view, true)
		expect.equality(column_names(me.columns), {
			"user_id",
			"primary_email",
			"display_name",
			"picture_url",
			"is_admin",
			"is_host",
			"passes_outstanding",
		})

		for _, view in ipairs(m.views) do
			expect.equality(view.is_public, true)
			expect.equality(view.is_anonymous, view.canonical == "public_classes_view")
		end
	end
end

T["schedules normalise out of a section and out of the table alike"] = function()
	for _, version in ipairs({ 9, 10 }) do
		local m = model(version)
		expect.equality(#m.schedules, 2)

		local tick
		for _, schedule in ipairs(m.schedules) do
			if schedule.table == "materialize_tick" then
				tick = schedule
			end
		end
		assert(tick, "no materialize_tick schedule")
		expect.equality(tick.column, 1)
		expect.equality(tick.reducer, "run_materialize_tick")
		expect.equality(tick.name, "materialize_tick_sched")

		-- The v10 join trap: `table_name` is `materialize_tick` while the table's
		-- source name is `materializeTick`, so this only attaches if the join
		-- went through canonical names.
		expect.equality(by_canonical(m.tables, "materialize_tick").schedule, tick)
		expect.equality(by_canonical(m.tables, "booking").schedule, nil)
	end
end

T["lifecycle reducers resolve in both versions"] = function()
	for _, version in ipairs({ 9, 10 }) do
		local m = model(version)
		expect.equality(m.lifecycle.Init, "init")
		expect.equality(m.lifecycle.OnConnect, "on_connect")
		expect.equality(m.lifecycle.OnDisconnect, "on_disconnect")
		expect.equality(by_canonical(m.reducers, "on_connect").lifecycle, "OnConnect")
		expect.equality(by_canonical(m.reducers, "book").lifecycle, nil)
	end
	-- The other half of the join trap: displayed as `onConnect`, joined as
	-- `on_connect`.
	expect.equality(by_name(model(10).reducers, "onConnect").lifecycle, "OnConnect")
end

T["the fallback policy retries only on 4xx"] = function()
	expect.equality(schema.VERSIONS, { 10, 9 })
	expect.equality(schema.should_fallback(400), true)
	expect.equality(schema.should_fallback(404), true)
	expect.equality(schema.should_fallback(200), false)
	-- A paused database answers 503; retrying it at v9 would only ask twice.
	expect.equality(schema.should_fallback(503), false)
	expect.equality(schema.should_fallback(nil), false)
end

T["parse rejects an unrecognised payload"] = function()
	expect.error(function()
		schema.parse({})
	end)
	expect.error(function()
		schema.parse("not a table")
	end)
end

T["system tables come from a constant, not the schema"] = function()
	expect.equality(schema.is_system_table("st_client"), true)
	expect.equality(schema.is_system_table("st_table"), true)
	expect.equality(schema.is_system_table("user"), false)
	expect.equality(schema.is_system_table(nil), false)

	-- The module definition never mentions `st_*`, so without the constant the
	-- sidebar's system group would always be empty.
	for _, version in ipairs({ 9, 10 }) do
		for _, entry in ipairs(model(version).tables) do
			expect.equality(entry.is_system, false)
			expect.equality(entry.table_type, "User")
		end
	end
end

return T
