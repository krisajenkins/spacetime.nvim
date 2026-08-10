-- Scratch buffers, and the window layout every `:Spacetime*` command opens into.
--
-- This module lives under `ui/` and may therefore touch `vim.api`; `lib/` is
-- pure logic and may not.
--
-- **Buffer names are the layout's identity.** `open_layout()` finds the windows
-- it should reuse by looking, in the *current tabpage*, for a window already
-- showing the `spacetime://sidebar` or `spacetime://content` buffer. Nothing is
-- stashed in `state.lua`, deliberately: a stored window handle goes stale the
-- moment the user runs `:only`, closes a window behind our back, or reloads a
-- session, and a stale handle is worse than none — it either errors or, once
-- Neovim reuses the id, addresses somebody else's window. A buffer name
-- survives all three, and the buffers themselves are `bufhidden = "hide"`, so
-- they persist unshown until the layout is opened again.
--
-- The layout replaces the current view rather than opening a tabpage of its
-- own, which is the (neo)vim convention for this kind of tool: the current
-- window becomes the content window (its buffer is displaced) and the sidebar
-- is split off beside it, full height, on the configured side. Focus is left on
-- the **sidebar**, because that is where the tree keymaps live.
--
-- Every buffer here is created non-modifiable. Writes go through `set_lines`,
-- which toggles the flag around the write and puts it back — including when the
-- write itself raises, which is the whole reason the restore is `pcall`ed.

local M = {}

---The sidebar buffer's name. This string *is* how the layout is recognised.
M.SIDEBAR_NAME = "spacetime://sidebar"

---The content buffer's name.
M.CONTENT_NAME = "spacetime://content"

---Filetype for the sidebar tree, so users can hang autocommands and keymaps
---off something stable.
M.SIDEBAR_FILETYPE = "spacetimetree"

---Filetype for content buffers (rows, schema, logs).
M.CONTENT_FILETYPE = "spacetime"

---Options for |spacetime.ui.buffer.get()|.
---@class SpacetimeBufferOpts
---@field filetype? string Defaults to `M.CONTENT_FILETYPE`.

-- Created on first use and reused for the life of the session.
-- `nvim_create_namespace` is itself idempotent by name, but caching keeps the
-- "one namespace" rule visible rather than incidental.
local namespace_id ---@type integer|nil

---The one extmark namespace every renderer marks into.
---@return integer
function M.namespace()
	if not namespace_id then
		namespace_id = vim.api.nvim_create_namespace("spacetime")
	end
	return namespace_id
end

---The buffer called `name`, if one exists.
---
---Names are compared exactly. Neovim stores a `scheme://` name verbatim (it
---does not expand it to a path, as it would a relative filename), so the string
---handed to `M.get` is the string that comes back.
---@param name string
---@return integer|nil bufnr
function M.find(name)
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == name then
			return bufnr
		end
	end
	return nil
end

---Get — or create — the scratch buffer called `name`.
---
---Idempotent: one name always means one buffer, for the life of the session.
---@param name string A `spacetime://…` name.
---@param opts? SpacetimeBufferOpts
---@return integer bufnr
function M.get(name, opts)
	vim.validate("name", name, function(value)
		return type(value) == "string" and value:match("^spacetime://.") ~= nil
	end, false, "a spacetime:// buffer name")
	opts = opts or {}

	local existing = M.find(name)
	if existing then
		return existing
	end

	-- Unlisted and scratch. The scratch flag already implies
	-- nofile/hide/noswapfile, but the three are set explicitly below because
	-- they are this function's contract, not an incidental of `nvim_create_buf`.
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, name)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = opts.filetype or M.CONTENT_FILETYPE
	-- Last, so the assignments above are not fighting it: from here on every
	-- write goes through `M.set_lines`.
	vim.bo[bufnr].modifiable = false
	return bufnr
end

---Replace lines in a buffer that is normally not modifiable.
---
---`modifiable` is turned on for the write and restored to whatever it was
---afterwards — restored through `pcall`, so a write that raises (invalid lines,
---a buffer wiped mid-render) cannot leave the buffer stuck modifiable. The
---write's own error is re-raised once the buffer is safe again.
---@param bufnr integer
---@param lines string[]
---@param first? integer 0-based start line, defaults to `0`.
---@param last? integer Exclusive end line, defaults to `-1` (end of buffer).
function M.set_lines(bufnr, lines, first, last)
	local modifiable = vim.bo[bufnr].modifiable
	vim.bo[bufnr].modifiable = true

	local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, first or 0, last or -1, false, lines)

	pcall(function()
		vim.bo[bufnr].modifiable = modifiable
	end)

	if not ok then
		-- Level 0: the message from `nvim_buf_set_lines` already names the API
		-- call, and a second position prefix would only obscure it.
		error(err, 0)
	end
end

---The window in the current tabpage showing `bufnr`, if any.
---
---Public because it is also how a caller asks "is the layout open?" — the same
---question `open_layout` answers for itself, and one that must be answered the
---same way (by what is on screen now) rather than from a remembered handle.
---@param bufnr integer
---@return integer|nil winid
function M.window_showing(bufnr)
	for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_buf(winid) == bufnr then
			return winid
		end
	end
	return nil
end

---Split from `winid` with `command` and return the window that appears.
---
---`nvim_win_call` restores the previous current window when it returns, so the
---new window's handle has to be read *inside* the callback.
---@param winid integer
---@param command string A `:vsplit` variant.
---@return integer created
local function split_from(winid, command)
	local created ---@type integer|nil
	vim.api.nvim_win_call(winid, function()
		vim.cmd(command)
		created = vim.api.nvim_get_current_win()
	end)
	return created --[[@as integer]]
end

---Open — or re-focus — the sidebar/content layout in the current tabpage.
---
---Idempotent. Running it twice returns the same two window handles; running it
---after the sidebar has been closed recreates only the sidebar and leaves the
---content window exactly where it was. See the module header for why reuse is
---detected by buffer name rather than by a remembered handle.
---
---`side` and `width` come from |spacetime.setup()|; a percentage width is
---resolved against `vim.o.columns` as it stands right now, so the same config
---gives a sensible sidebar in a wide and a narrow terminal alike.
---
---Focus is left on the sidebar.
---@return integer sidebar_win
---@return integer content_win
function M.open_layout()
	local opts = require("spacetime").config
	local side = opts.side or "left"
	local width = require("spacetime.config").sidebar_columns(opts.width or 30, vim.o.columns)

	local sidebar_buf = M.get(M.SIDEBAR_NAME, { filetype = M.SIDEBAR_FILETYPE })
	local content_buf = M.get(M.CONTENT_NAME, { filetype = M.CONTENT_FILETYPE })

	local sidebar_win = M.window_showing(sidebar_buf)
	local content_win = M.window_showing(content_buf)

	if not content_win then
		-- The current window becomes the content window, displacing whatever it
		-- was showing — unless the current window *is* the sidebar, in which case
		-- any other window will do, and a fresh split if there is no other (the
		-- user ran `:only` from the sidebar).
		local candidate = vim.api.nvim_get_current_win()
		if candidate == sidebar_win then
			candidate = nil
			for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
				if winid ~= sidebar_win then
					candidate = winid
					break
				end
			end
			-- Split away from the sidebar, so the content window lands on the
			-- side the sidebar is not on.
			candidate = candidate
				or split_from(sidebar_win, side == "left" and "rightbelow vsplit" or "leftabove vsplit")
		end
		content_win = candidate
	end
	vim.api.nvim_win_set_buf(content_win, content_buf)

	if not sidebar_win then
		-- `topleft`/`botright` split the whole tabpage rather than just the
		-- current window, which is what makes the sidebar a full-height column
		-- beside everything else — the conventional shape for one.
		sidebar_win = split_from(content_win, side == "left" and "topleft vsplit" or "botright vsplit")
		vim.api.nvim_win_set_buf(sidebar_win, sidebar_buf)
		-- Only on creation: re-running `:Spacetime` must not undo a width the
		-- user has deliberately dragged. `winfixwidth` below keeps it from
		-- drifting on its own.
		vim.api.nvim_win_set_width(sidebar_win, width)
	end

	local wo = vim.wo[sidebar_win]
	wo.winfixwidth = true
	wo.number = false
	wo.relativenumber = false
	wo.signcolumn = "no"
	wo.wrap = false

	vim.api.nvim_set_current_win(sidebar_win)
	return sidebar_win, content_win
end

return M
