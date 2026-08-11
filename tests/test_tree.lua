-- Tests for the pure sidebar tree.
--
-- No child Neovim: `ui/tree.lua` makes no `vim.*` call at all, so a plain test
-- set is enough — the same precedent `tests/test_grid.lua` set for a pure module
-- under `ui/`.
--
-- The loaded case is driven from the committed `tests/fixtures/schema_v10.json`
-- through `lib/schema.parse`, so the grouping and ordering assertions run
-- against the real module's twelve tables and four views rather than against a
-- hand-written list that could agree with a bug. Every table in both live
-- fixtures is `table_type = "User"`, so the system group is exercised by
-- injecting one `st_*` table — and `st_client` deliberately sorts *before*
-- `user` canonically, so "system last" cannot pass by accident.
local tree = require("spacetime.ui.tree")
local schema_lib = require("spacetime.lib.schema")
local json = require("spacetime.lib.json")
local highlights = require("spacetime.ui.highlights")
local read = require("tests.helpers.fixtures").read
local expect = MiniTest.expect

local T = MiniTest.new_set()

local COLLAPSED = "▸"
local EXPANDED = "▾"
local PAUSED = "⏸"
local INDENT = "    "
local PRIVATE = "🔒"
local PUBLIC = "🌎"
local TABLE = "📋"
local VIEW = "👓"
local SYSTEM = "🔧"

---@return SpacetimeSchema
local function fixture_schema()
	return schema_lib.parse(json.decode(read("schema_v10.json")))
end

---Add one system table to a parsed schema and restore the canonical sort, so
---the sidebar sees the three groups it has to separate.
---@param model SpacetimeSchema
---@return SpacetimeSchema
local function with_system_table(model)
	model.tables[#model.tables + 1] = {
		name = "st_client",
		canonical = "st_client",
		product_type_ref = nil,
		columns = {},
		primary_key = {},
		table_type = "System",
		access = "Public",
		is_event = false,
		is_system = true,
		is_view = false,
		indexes = {},
		constraints = {},
		schedule = nil,
	}
	table.sort(model.tables, function(a, b)
		return a.canonical < b.canonical
	end)
	return model
end

---Add one public table to a parsed schema, since every table in both live
---fixtures is `Private` and the icon has two states to prove.
---@param model SpacetimeSchema
---@return SpacetimeSchema
local function with_public_table(model)
	model.tables[#model.tables + 1] = {
		name = "leaderboard",
		canonical = "leaderboard",
		product_type_ref = nil,
		columns = {},
		primary_key = {},
		table_type = "User",
		access = "Public",
		is_event = false,
		is_system = false,
		is_view = false,
		indexes = {},
		constraints = {},
		schedule = nil,
	}
	table.sort(model.tables, function(a, b)
		return a.canonical < b.canonical
	end)
	return model
end

---The access icon a node must carry, derived from the *model* rather than read
---back off the rendered line: a table's raw access tag, a view's boolean.
---@param node SpacetimeTreeNode
---@return string
local function want_access_icon(node)
	local entry = node.entry
	local public
	if node.kind == "view" then
		public = entry.is_public == true
	else
		public = entry.access == "Public"
	end
	return public and PUBLIC or PRIVATE
end

---The kind icon a node must carry, keyed off the group the entry was rendered
---into rather than off `entry.is_view`, exactly as the module keys it.
---@param node SpacetimeTreeNode
---@return string
local function want_kind_icon(node)
	if node.kind == "view" then
		return VIEW
	elseif node.kind == "system_table" then
		return SYSTEM
	end
	return TABLE
end

---The two icons a table or view line is prefixed with, kind then access.
---@param node SpacetimeTreeNode
---@return string
local function want_icons(node)
	return want_kind_icon(node) .. want_access_icon(node)
end

---The full indent a table or view line carries: four spaces, its icons, a space.
---@param node SpacetimeTreeNode
---@return string
local function want_indent(node)
	return INDENT .. want_icons(node) .. " "
end

---The invariants that must hold of every render, whatever the model.
---
---`nodes` dense and parallel to `lines` is the round-trip the issue asks for;
---every span landing inside its own line, measured in bytes, is what makes the
---spans usable as extmark positions; and every `hl_group` being a real group is
---the same cross-check `test_grid.lua` performs.
---@param render SpacetimeTreeRender
local function check_invariants(render)
	expect.equality(#render.nodes, #render.lines)
	for i = 1, #render.lines do
		expect.equality(render.nodes[i].line, i)
		expect.equality(type(render.nodes[i].label), "string")
		expect.equality(render.lines[i]:find("\n"), nil)
	end

	for _, span in ipairs(render.spans) do
		local line = render.lines[span.line + 1]
		expect.equality(type(line), "string")
		expect.equality(span.start_col >= 0, true)
		expect.equality(span.start_col < span.end_col, true)
		expect.equality(span.end_col <= #line, true)
		expect.no_equality(highlights.links[span.hl_group], nil)
	end
end

---Every node below the database line, which is always line 1 here.
---@param render SpacetimeTreeRender
---@return SpacetimeTreeNode[]
local function child_nodes(render)
	local out = {}
	for i = 2, #render.nodes do
		out[#out + 1] = render.nodes[i]
	end
	return out
end

T["a collapsed database renders one line and no children"] = function()
	local db = { name = "spacegym", schema = fixture_schema() }
	local render = tree.build_lines({ databases = { db } })
	check_invariants(render)

	expect.equality(render.lines, { COLLAPSED .. " spacegym" })
	expect.equality(render.nodes[1].kind, "database")
	expect.equality(render.nodes[1].label, "spacegym")
	expect.equality(render.nodes[1].database, "spacegym")
	-- The back-reference is the caller's own table, not a copy of it: the
	-- controller mutates `expanded` on it and re-renders.
	expect.equality(rawequal(render.nodes[1].db, db), true)

	expect.equality(render.spans, {
		{ line = 0, start_col = 4, end_col = 4 + #"spacegym", hl_group = "SpacetimeDatabase" },
	})
end

T["an expanded database renders one child per table and view"] = function()
	local schema = fixture_schema()
	local render = tree.build_lines({ databases = { { name = "spacegym", expanded = true, schema = schema } } })
	check_invariants(render)

	expect.equality(render.lines[1], EXPANDED .. " spacegym")
	expect.equality(#render.lines, 1 + #schema.tables + #schema.views)

	for _, node in ipairs(child_nodes(render)) do
		expect.equality(render.lines[node.line]:sub(1, #INDENT), INDENT)
		expect.equality(render.lines[node.line], want_indent(node) .. node.label)
		expect.equality(node.label, node.name)
		expect.equality(node.database, "spacegym")
		expect.no_equality(node.canonical, nil)
	end

	-- The source spelling is displayed, the canonical name is carried: the whole
	-- point of `ExplicitNames`.
	local ledger
	for _, node in ipairs(child_nodes(render)) do
		if node.name == "ledgerEntry" then
			ledger = node
		end
	end
	expect.no_equality(ledger, nil)
	expect.equality(ledger.canonical, "ledger_entry")
	expect.equality(rawequal(ledger.entry, schema_lib.table_by_name(schema, "ledger_entry")), true)
end

T["children group user tables, then views, then system tables"] = function()
	local schema = with_system_table(fixture_schema())
	local render = tree.build_lines({ databases = { { name = "spacegym", expanded = true, schema = schema } } })
	check_invariants(render)

	local expected_kinds, expected_labels = {}, {}
	local function want(kind, name)
		expected_kinds[#expected_kinds + 1] = kind
		expected_labels[#expected_labels + 1] = name
	end
	for _, entry in ipairs(schema.tables) do
		if not entry.is_system then
			want("table", entry.name)
		end
	end
	for _, entry in ipairs(schema.views) do
		want("view", entry.name)
	end
	for _, entry in ipairs(schema.tables) do
		if entry.is_system then
			want("system_table", entry.name)
		end
	end

	local kinds, labels = {}, {}
	for _, node in ipairs(child_nodes(render)) do
		kinds[#kinds + 1] = node.kind
		labels[#labels + 1] = node.label
	end
	expect.equality(kinds, expected_kinds)
	expect.equality(labels, expected_labels)

	-- The system table is last even though `st_client` sorts before `user`, so
	-- grouping really did override the canonical sort rather than coincide with it.
	local last = render.nodes[#render.nodes]
	expect.equality(last.kind, "system_table")
	expect.equality(last.canonical, "st_client")
	local saw_later_name = false
	for _, node in ipairs(child_nodes(render)) do
		if node.kind == "table" and node.canonical > "st_client" then
			saw_later_name = true
		end
	end
	expect.equality(saw_later_name, true)
end

T["each group keeps the schema's canonical order"] = function()
	local schema = with_system_table(fixture_schema())
	local render = tree.build_lines({ databases = { { name = "spacegym", expanded = true, schema = schema } } })

	local previous = {}
	for _, node in ipairs(child_nodes(render)) do
		local last = previous[node.kind]
		if last ~= nil then
			expect.equality(last < node.canonical, true)
		end
		previous[node.kind] = node.canonical
	end
	expect.no_equality(previous["table"], nil)
	expect.no_equality(previous["view"], nil)
	expect.no_equality(previous["system_table"], nil)
end

T["a table's icon comes from its access and a view's from is_public"] = function()
	local schema = with_public_table(with_system_table(fixture_schema()))
	local render = tree.build_lines({ databases = { { name = "spacegym", expanded = true, schema = schema } } })
	check_invariants(render)

	local seen_access, seen_kind = {}, {}
	for _, node in ipairs(child_nodes(render)) do
		local line = render.lines[node.line]
		expect.equality(line:sub(1, #INDENT), INDENT)
		expect.equality(line, want_indent(node) .. node.label)
		seen_kind[want_kind_icon(node)] = true
		seen_access[want_access_icon(node)] = true
	end
	-- Both access icons really did appear: the live module's tables are all
	-- `Private`, its four views are all `is_public`, and `leaderboard` is a
	-- `Public` table. All three kind icons appeared too.
	expect.equality(seen_access, { [PRIVATE] = true, [PUBLIC] = true })
	expect.equality(seen_kind, { [TABLE] = true, [VIEW] = true, [SYSTEM] = true })

	---@param name string
	---@return SpacetimeTreeNode
	local function node_named(name)
		for _, node in ipairs(child_nodes(render)) do
			if node.label == name then
				return node
			end
		end
		error("no node labelled " .. name)
	end

	expect.equality(render.lines[node_named("ledgerEntry").line], INDENT .. TABLE .. PRIVATE .. " ledgerEntry")
	expect.equality(render.lines[node_named("leaderboard").line], INDENT .. TABLE .. PUBLIC .. " leaderboard")
	expect.equality(render.lines[node_named("meView").line], INDENT .. VIEW .. PUBLIC .. " meView")
	-- System tables carry an access like any other table, and are iconed from it:
	-- leaving them bare would put their names left of everything else, and
	-- `st_client` is genuinely readable where `st_var` is not. Their kind glyph is
	-- their own, so the group is identifiable without reading the `st_` prefix.
	local system = node_named("st_client")
	expect.equality(system.kind, "system_table")
	expect.equality(render.lines[system.line], INDENT .. SYSTEM .. PUBLIC .. " st_client")
end

T["the label span covers exactly the name, past the icon"] = function()
	local schema = with_public_table(with_system_table(fixture_schema()))
	local render = tree.build_lines({ databases = { { name = "spacegym", expanded = true, schema = schema } } })
	check_invariants(render)

	local checked = 0
	for _, node in ipairs(child_nodes(render)) do
		local line = render.lines[node.line]
		local span
		for _, candidate in ipairs(render.spans) do
			if candidate.line == node.line - 1 then
				span = candidate
			end
		end
		expect.no_equality(span, nil)
		expect.equality(span.start_col, #want_indent(node))
		expect.equality(line:sub(span.start_col + 1, span.end_col), node.label)
		checked = checked + 1
	end
	expect.equality(checked, #schema.tables + #schema.views)
end

T["a private entry is never mistaken for a public one"] = function()
	-- Neither an absent access nor an absent `is_public` may render as the globe:
	-- being wrong in that direction says "anyone can read this" about something
	-- nobody can.
	local render = tree.build_lines({
		databases = {
			{
				name = "db",
				expanded = true,
				schema = { tables = { { name = "t", canonical = "t" } }, views = { { name = "v", canonical = "v" } } },
			},
		},
	})
	check_invariants(render)

	expect.equality(render.lines, {
		EXPANDED .. " db",
		INDENT .. TABLE .. PRIVATE .. " t",
		INDENT .. VIEW .. PRIVATE .. " v",
	})
end

T["icons = ascii and icons = none are the terminals-without-emoji fallbacks"] = function()
	local schema = with_public_table(fixture_schema())
	---@param mode string|nil
	---@return table<string, string> # Label -> the line that carries it.
	local function lines_for(mode)
		local render = tree.build_lines({
			icons = mode,
			databases = { { name = "db", expanded = true, schema = schema } },
		})
		check_invariants(render)
		local by_label = {}
		for _, node in ipairs(child_nodes(render)) do
			by_label[node.label] = render.lines[node.line]
		end
		return by_label
	end

	-- One byte and one column each, so the ASCII glyphs align with each other
	-- exactly as the emoji do.
	local ascii = lines_for("ascii")
	expect.equality(ascii["booking"], INDENT .. "t- booking")
	expect.equality(ascii["leaderboard"], INDENT .. "t+ leaderboard")
	expect.equality(ascii["meView"], INDENT .. "v+ meView")

	-- `none` is the pre-icon rendering exactly: four spaces and the name. Neither
	-- column survives — a kind glyph with no access beside it would be a half
	-- fallback nobody asked for.
	local none = lines_for("none")
	expect.equality(none["booking"], INDENT .. "booking")
	expect.equality(none["leaderboard"], INDENT .. "leaderboard")
	expect.equality(none["meView"], INDENT .. "meView")

	-- An unset or unrecognised mode is the emoji default rather than a raise: the
	-- setting is cosmetic, and `setup()` has already refused what it does not know.
	local default = lines_for(nil)
	expect.equality(default["booking"], INDENT .. TABLE .. PRIVATE .. " booking")
	expect.equality(default["leaderboard"], INDENT .. TABLE .. PUBLIC .. " leaderboard")
	expect.equality(default["meView"], INDENT .. VIEW .. PUBLIC .. " meView")
	expect.equality(lines_for("hieroglyphs"), default)
end

T["an expanded database renders its loading state"] = function()
	local render = tree.build_lines({ databases = { { name = "db", expanded = true, status = "loading" } } })
	check_invariants(render)

	expect.equality(render.lines, { EXPANDED .. " db", INDENT .. "loading…" })
	expect.equality(render.nodes[2].kind, "message")
	expect.equality(render.nodes[2].message, "loading…")
	expect.equality(render.nodes[2].database, "db")
	-- Only the database name is highlighted; the placeholder is plain.
	expect.equality(#render.spans, 1)
	expect.equality(render.spans[1].hl_group, "SpacetimeDatabase")
end

T["an expanded database renders its error on one line"] = function()
	local render = tree.build_lines({
		databases = { { name = "db", expanded = true, status = "error", error = "unauthorized\n(401)" } },
	})
	check_invariants(render)

	expect.equality(render.lines, { EXPANDED .. " db", INDENT .. "error: unauthorized (401)" })
	expect.equality(render.nodes[2].kind, "message")

	local error_span = render.spans[2]
	expect.equality(error_span.line, 1)
	expect.equality(error_span.hl_group, "SpacetimeError")
	expect.equality(error_span.start_col, #INDENT)
	expect.equality(error_span.end_col, #render.lines[2])

	-- A database with no message at all still renders one, so the sidebar never
	-- shows a bare `error:`.
	local bare = tree.build_lines({ databases = { { name = "db", expanded = true, status = "error" } } })
	expect.equality(bare.lines[2], INDENT .. "error: unknown error")
end

T["a paused database is marked and has no children"] = function()
	local render = tree.build_lines({
		databases = { { name = "db", expanded = true, status = "paused", schema = fixture_schema() } },
	})
	check_invariants(render)

	-- Expanded, with a schema already cached, and still no children: the marker is
	-- the whole story.
	expect.equality(render.lines, { EXPANDED .. " db " .. PAUSED })
	expect.equality(#render.nodes, 1)

	local pause = render.spans[2]
	expect.equality(pause.hl_group, "SpacetimePaused")
	expect.equality(render.lines[1]:sub(pause.start_col + 1, pause.end_col), PAUSED)

	-- The marker rides on the collapsed line too.
	local collapsed = tree.build_lines({ databases = { { name = "db", status = "paused" } } })
	expect.equality(collapsed.lines, { COLLAPSED .. " db " .. PAUSED })
	expect.equality(collapsed.spans[2].hl_group, "SpacetimePaused")
end

T["byte offsets survive a multibyte database name"] = function()
	local name = "héllo🎟"
	expect.no_equality(#name, vim.fn.strchars(name))

	local render = tree.build_lines({ databases = { { name = name, status = "paused" } } })
	check_invariants(render)

	expect.equality(render.lines, { COLLAPSED .. " " .. name .. " " .. PAUSED })

	local db_span, pause = render.spans[1], render.spans[2]
	expect.equality(db_span.start_col, 4)
	expect.equality(db_span.end_col, 4 + #name)
	expect.equality(render.lines[1]:sub(db_span.start_col + 1, db_span.end_col), name)
	expect.equality(pause.start_col, 4 + #name + 1)
	expect.equality(render.lines[1]:sub(pause.start_col + 1, pause.end_col), PAUSED)

	-- Multibyte table names index the same way.
	local schema = fixture_schema()
	schema.tables[1].name = "héllo🎟"
	local expanded = tree.build_lines({ databases = { { name = "db", expanded = true, schema = schema } } })
	check_invariants(expanded)
	local node = expanded.nodes[2]
	expect.equality(node.label, "héllo🎟")
	-- Four spaces, a four-byte clipboard, a four-byte lock and a space before the
	-- name, all of it counted in bytes.
	expect.equality(expanded.spans[2].start_col, #INDENT + #TABLE + #PRIVATE + 1)
	expect.equality(expanded.spans[2].end_col, #INDENT + #TABLE + #PRIVATE + 1 + #node.label)
	expect.equality(expanded.lines[2]:sub(expanded.spans[2].start_col + 1, expanded.spans[2].end_col), node.label)
end

T["a loaded database with nothing in it says so"] = function()
	local render = tree.build_lines({
		databases = { { name = "db", expanded = true, schema = { tables = {}, views = {} } } },
	})
	check_invariants(render)

	expect.equality(render.lines, { EXPANDED .. " db", INDENT .. "(no tables)" })
	expect.equality(render.nodes[2].kind, "message")

	-- Idle with no schema at all is different: nothing has been fetched, so there
	-- is nothing truthful to say.
	local unfetched = tree.build_lines({ databases = { { name = "db", expanded = true } } })
	expect.equality(unfetched.lines, { EXPANDED .. " db" })
end

T["the database list has its own loading, error and empty lines"] = function()
	local loading = tree.build_lines({ status = "loading" })
	check_invariants(loading)
	expect.equality(loading.lines, { "loading…" })
	expect.equality(loading.spans, {})
	expect.equality(loading.nodes[1].kind, "message")
	expect.equality(loading.nodes[1].database, nil)

	local errored = tree.build_lines({ status = "error", error = "connection refused" })
	check_invariants(errored)
	expect.equality(errored.lines, { "error: connection refused" })
	expect.equality(errored.spans, {
		{ line = 0, start_col = 0, end_col = #errored.lines[1], hl_group = "SpacetimeError" },
	})

	-- A list status wins over any databases still hanging around from before.
	local stale = tree.build_lines({ status = "error", error = "boom", databases = { { name = "db" } } })
	expect.equality(stale.lines, { "error: boom" })

	for _, model in ipairs({ {}, { databases = {} }, { status = "idle" } }) do
		local render = tree.build_lines(model)
		check_invariants(render)
		expect.equality(render.lines, { "(no databases)" })
		expect.equality(render.nodes[1].kind, "message")
		expect.equality(render.spans, {})
	end
end

T["a model that is not a table fails loudly"] = function()
	expect.error(function()
		tree.build_lines(nil)
	end)
	expect.error(function()
		---@diagnostic disable-next-line: param-type-mismatch
		tree.build_lines("spacegym")
	end)
end

T["several databases render in the order given"] = function()
	local schema = with_system_table(fixture_schema())
	local render = tree.build_lines({
		databases = {
			{ name = "zulu", expanded = true, status = "loading" },
			{ name = "alpha", status = "paused" },
			{ name = "bravo", expanded = true, schema = schema },
		},
	})
	check_invariants(render)

	local databases = {}
	for _, node in ipairs(render.nodes) do
		if node.kind == "database" then
			databases[#databases + 1] = node.label
		end
	end
	expect.equality(databases, { "zulu", "alpha", "bravo" })

	expect.equality(render.lines[1], EXPANDED .. " zulu")
	expect.equality(render.lines[2], INDENT .. "loading…")
	expect.equality(render.lines[3], COLLAPSED .. " alpha " .. PAUSED)
	expect.equality(render.lines[4], EXPANDED .. " bravo")
	expect.equality(#render.lines, 4 + #schema.tables + #schema.views)
end

return T
