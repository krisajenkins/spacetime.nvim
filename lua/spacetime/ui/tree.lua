-- The sidebar tree, rendered as data: a model in, lines plus nodes plus
-- highlight spans out.
--
-- This is the pure half of the sidebar. It lives under `ui/` because the
-- roadmap's layout puts it there, but it makes no `vim.*` call at all — not even
-- `vim.fn.strdisplaywidth`, which `ui/grid.lua` needs. Nothing here is aligned
-- into columns: the tree is a marker, a fixed indent and a name, so byte lengths
-- are the only measurements taken and `#s` is exactly right. The consequence is
-- that the whole sidebar's *content* is testable headlessly, and the module that
-- owns the buffer (task 24) is left with nothing but `nvim_buf_set_lines` and
-- `nvim_buf_set_extmark`.
--
-- Three things this file exists to get right:
--
-- 1. **`nodes` is dense and parallel to `lines`.** Every rendered line has a
--    node, message lines included, and `nodes[i].line == i`. That is what makes
--    "the node under the cursor" a single array index in the controller rather
--    than a search, and it is why every label is folded onto one line first —
--    one line per node is the invariant every index here depends on, the same
--    reason `grid.sanitise` exists.
-- 2. **Spans are 0-based byte offsets**, ready for `nvim_buf_set_extmark`
--    without conversion. The marker column is a 3-byte arrow plus a space, and
--    the access icon a 4-byte emoji plus a space, so a character-based offset
--    would put every database name four columns left of where it is and every
--    table name seven.
-- 3. **The module holds no state.** Expansion is passed in per database as
--    `expanded`, and the caller supplies the database order. Two calls with the
--    same model produce the same render.
--
-- No truncation is done: the sidebar window clips, and a name cut to fit would
-- be a name the user cannot search for.

---One database, as the sidebar wants it shown. The caller owns expansion state,
---the fetch that fills `schema`, and the order the databases appear in.
---@class SpacetimeTreeDatabase
---@field name string Display name.
---@field expanded? boolean Render children. Default `false`.
---@field status? "idle"|"loading"|"error"|"paused" Default `"idle"`.
---@field error? string Message to render when `status == "error"`.
---@field schema? SpacetimeSchema From `lib/schema.lua`; present once loaded.
---@field identity? string Opaque; reachable from a node via `node.db.identity`.

---@class SpacetimeTreeModel
---@field databases? SpacetimeTreeDatabase[] In the order given — the caller sorts.
---@field status? "idle"|"loading"|"error" Status of the database *list* itself.
---@field error? string Message to render when `status == "error"`.
---@field icons? "emoji"|"ascii"|"none" Which `M.ICONS` set to prefix names with. Default `"emoji"`.

---What one rendered line means. `kind` says which of the optional fields are set.
---@class SpacetimeTreeNode
---@field kind "database"|"table"|"view"|"system_table"|"message"
---@field line integer 1-based index into `lines`, so a node round-trips both ways.
---@field label string The rendered text, marker, indent and access icon excluded.
---@field database? string `db.name`; set on every node inside a database, `nil` on top-level messages.
---@field db? SpacetimeTreeDatabase The input entry itself, by reference.
---@field name? string Display name of a table or view (`entry.name`).
---@field canonical? string SQL name of a table or view (`entry.canonical`) — what to query.
---@field entry? SpacetimeSchemaTable|SpacetimeSchemaView The schema entry, by reference.
---@field message? string Set when `kind == "message"`.

---@class SpacetimeTreeSpan
---@field line integer 0-based index into `lines`.
---@field start_col integer 0-based byte offset.
---@field end_col integer 0-based byte offset, exclusive.
---@field hl_group string

---@class SpacetimeTreeRender
---@field lines string[]
---@field nodes SpacetimeTreeNode[] Parallel to `lines`, 1-based and dense.
---@field spans SpacetimeTreeSpan[]

local M = {}

---The three markers the sidebar draws, exported so callers and tests name them
---rather than re-spelling the code points.
---@type table<string, string>
M.MARKERS = {
	collapsed = "▸",
	expanded = "▾",
	paused = "⏸",
}

---Indent applied to every child line. Four spaces, matching the width of the
---`"▸ "` marker column, so labels line up under the database name.
M.INDENT = "    "

---The access icons, keyed by the mode `model.icons` names. Every table and view
---is prefixed with one, so "can anyone read this?" is answerable at a glance
---rather than by opening the schema view.
---
---`emoji` is the default, and the pair is chosen to be one width class: both
---glyphs are four bytes and both are `Emoji_Presentation` (East Asian Wide), so
---a terminal that draws emoji narrow draws *both* narrow and the label column
---shifts as a whole rather than going ragged. That is the whole of the
---mitigation — `strdisplaywidth` for emoji depends on `'ambiwidth'` and on the
---terminal's own tables, which ROADMAP.md's risk list says to document rather
---than chase. `ascii` is the bare-TTY fallback (one byte, one column, same
---property) and `none` renders no icon column at all.
---@type table<string, table<string, string>>
M.ICONS = {
	emoji = { public = "🌎", private = "🔒" },
	ascii = { public = "+", private = "-" },
	none = {},
}

---The `M.ICONS` set used when the model names none.
M.DEFAULT_ICONS = "emoji"

local LOADING = "loading…"
local NO_DATABASES = "(no databases)"
local NO_TABLES = "(no tables)"
local UNKNOWN_ERROR = "unknown error"

---`value` when it is a table, otherwise an empty one, so an absent list can be
---`ipairs`ed without a guard at every call site.
---@param value any
---@return table
local function list(value)
	if type(value) ~= "table" then
		return {}
	end
	return value
end

---Fold `value` onto a single line, collapsing every run of whitespace to one
---space. A newline in a name or an error message would break the line-to-node
---mapping silently, and multi-line server errors are common enough to be worth
---defending against; tabs go the same way, because their rendered width would
---depend on `'tabstop'` while every offset reported here is a byte count.
---@param value any
---@param fallback string Used when `value` is not a string.
---@return string
local function one_line(value, fallback)
	if type(value) ~= "string" then
		return fallback
	end
	local out = value:gsub("%s+", " ")
	return out
end

---Is this schema entry readable by anyone?
---
---The two halves of the model spell it differently and neither is re-derived
---from anything else: a view carries an `is_public` boolean, a table (system
---tables included — they have an access like any other, and giving them one
---keeps the label column straight) carries the raw `"Public"`/`"Private"` tag.
---Which to read is decided by the list the entry came out of rather than by
---`entry.is_view`, so a half-built model cannot make a public view read as a
---private table. Anything unrecognised counts as private, which is the safe way
---to be wrong.
---@param kind string The node kind, as `children` classified it.
---@param entry SpacetimeSchemaTable|SpacetimeSchemaView|table
---@return boolean
local function is_public(kind, entry)
	if kind == "view" then
		return entry.is_public == true
	end
	return entry.access == "Public"
end

---Lay the sidebar tree out.
---
---Raises on a non-table model: everything below that point is tolerant — a
---database with no name renders as an empty label, an unparsed schema renders no
---children — because a tree we can only partly draw still beats a stack trace in
---the sidebar.
---@param model SpacetimeTreeModel
---@return SpacetimeTreeRender
function M.build_lines(model)
	if type(model) ~= "table" then
		error("spacetime.ui.tree: model must be a table", 2)
	end

	local lines = {} ---@type string[]
	local nodes = {} ---@type SpacetimeTreeNode[]
	local spans = {} ---@type SpacetimeTreeSpan[]

	-- An unknown mode falls back to the default rather than raising: this is a
	-- cosmetic setting, and `setup()` has already refused anything it does not
	-- know about.
	local icons = M.ICONS[model.icons] or M.ICONS[M.DEFAULT_ICONS]

	---Append one line and the node that owns it, filling in `node.line`.
	---@param text string
	---@param node table Node fields; `line` is set here.
	---@return integer index 1-based index of the line just added.
	local function emit(text, node)
		local index = #lines + 1
		node.line = index
		lines[index] = text
		nodes[index] = node
		return index
	end

	---@param index integer 1-based line index, as returned by `emit`.
	---@param start_col integer 0-based byte offset.
	---@param end_col integer 0-based byte offset, exclusive.
	---@param hl_group string
	local function span(index, start_col, end_col, hl_group)
		if end_col > start_col then
			spans[#spans + 1] = {
				line = index - 1,
				start_col = start_col,
				end_col = end_col,
				hl_group = hl_group,
			}
		end
	end

	---A plain informational line: loading, an error, or an empty placeholder.
	---@param indent string
	---@param text string
	---@param hl_group string|nil Applied to the text, indent excluded.
	---@param db SpacetimeTreeDatabase|nil Owning database, if any.
	local function message(indent, text, hl_group, db)
		local line = indent .. text
		local index = emit(line, {
			kind = "message",
			label = text,
			message = text,
			database = db ~= nil and type(db.name) == "string" and db.name or nil,
			db = db,
		})
		if hl_group ~= nil then
			span(index, #indent, #line, hl_group)
		end
	end

	---The children of a loaded database, in the order the sidebar groups them:
	---user tables, then views, then the `st_*` system tables. Each group keeps
	---`lib/schema.lua`'s canonical sort, so the order within a group is stable
	---across both wire versions.
	---@param db SpacetimeTreeDatabase
	---@param schema SpacetimeSchema
	local function children(db, schema)
		local group = {} ---@type { kind: string, hl: string, entry: table }[]
		for _, entry in ipairs(list(schema.tables)) do
			if not entry.is_system then
				group[#group + 1] = { kind = "table", hl = "SpacetimeTable", entry = entry }
			end
		end
		for _, entry in ipairs(list(schema.views)) do
			group[#group + 1] = { kind = "view", hl = "SpacetimeView", entry = entry }
		end
		for _, entry in ipairs(list(schema.tables)) do
			if entry.is_system then
				group[#group + 1] = { kind = "system_table", hl = "SpacetimeSystemTable", entry = entry }
			end
		end

		if #group == 0 then
			message(M.INDENT, NO_TABLES, nil, db)
			return
		end

		for _, item in ipairs(group) do
			local entry = item.entry
			-- Display the source spelling the developer wrote; carry the canonical
			-- name on the node, because that is what the SQL layer queries.
			local label = one_line(entry.name, one_line(entry.canonical, ""))
			-- The icon is decoration, not part of the name: it is prefixed onto the
			-- line but kept out of `label` and out of the highlighted span, so `y`
			-- still yanks something you can paste into SQL.
			local icon = icons[is_public(item.kind, entry) and "public" or "private"]
			local indent = icon ~= nil and (M.INDENT .. icon .. " ") or M.INDENT
			local index = emit(indent .. label, {
				kind = item.kind,
				label = label,
				database = type(db.name) == "string" and db.name or nil,
				db = db,
				name = entry.name,
				canonical = entry.canonical,
				entry = entry,
			})
			span(index, #indent, #indent + #label, item.hl)
		end
	end

	local status = model.status or "idle"
	if status == "loading" then
		message("", LOADING, nil, nil)
		return { lines = lines, nodes = nodes, spans = spans }
	end
	if status == "error" then
		-- The list itself failed, so whatever databases were known before are not
		-- worth showing beside a message saying we could not list them.
		message("", "error: " .. one_line(model.error, UNKNOWN_ERROR), "SpacetimeError", nil)
		return { lines = lines, nodes = nodes, spans = spans }
	end

	local databases = list(model.databases)
	if #databases == 0 then
		message("", NO_DATABASES, nil, nil)
		return { lines = lines, nodes = nodes, spans = spans }
	end

	for _, db in ipairs(databases) do
		local db_status = db.status or "idle"
		local name = one_line(db.name, "")
		local marker = db.expanded and M.MARKERS.expanded or M.MARKERS.collapsed
		local start_col = #marker + 1

		local line = marker .. " " .. name
		if db_status == "paused" then
			line = line .. " " .. M.MARKERS.paused
		end

		local index = emit(line, {
			kind = "database",
			label = name,
			database = type(db.name) == "string" and db.name or nil,
			db = db,
		})
		span(index, start_col, start_col + #name, "SpacetimeDatabase")
		if db_status == "paused" then
			local pause_col = start_col + #name + 1
			span(index, pause_col, pause_col + #M.MARKERS.paused, "SpacetimePaused")
		end

		-- A collapsed database has no children at all, and a paused one has none
		-- either: the `⏸` on its own line is the whole story, and expanding it must
		-- not suggest there is a schema behind it to fetch.
		if db.expanded and db_status ~= "paused" then
			if db_status == "loading" then
				message(M.INDENT, LOADING, nil, db)
			elseif db_status == "error" then
				message(M.INDENT, "error: " .. one_line(db.error, UNKNOWN_ERROR), "SpacetimeError", db)
			elseif type(db.schema) == "table" then
				children(db, db.schema)
			end
			-- `idle` with no schema yet emits nothing: the fetch has not been asked
			-- for, so there is nothing truthful to say.
		end
	end

	return { lines = lines, nodes = nodes, spans = spans }
end

return M
