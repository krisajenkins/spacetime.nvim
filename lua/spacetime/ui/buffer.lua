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
--
-- **'wrap' follows the buffer, not the window.** Every view here is a grid: the
-- row table, the tree and the log are all column-aligned, and one wrapped line
-- shunts every line under it out of alignment, which is exactly what makes a
-- wrapped view unreadable. 'wrap' is window-local, though, and the content
-- window is *the user's own window* — the layout only borrows it, displacing
-- its buffer, and `q` hands it straight back. So the option is imposed by a
-- `BufWinEnter` autocommand (see `M.watch_windows`) that claims a window when a
-- `spacetime://` buffer appears in it and gives the window's own value back the
-- moment it shows anything else. Two consequences worth having:
--
--  * every way out restores it — `q`, `:edit`, `:bdelete`, `:bnext` — rather
--    than only the one teardown path a save-and-restore in `close()` would
--    cover;
--  * it follows the buffer, so a `spacetime://` buffer opened in a window the
--    layout never created is unwrapped too, and that window is still handed
--    back intact.
--
-- The saved value lives in a window-local variable rather than a module table
-- keyed by window id: it cannot go stale, because it dies with the window.
-- The one thing this does not chase is a `:split` of a spacetime window — the
-- copy inherits 'wrap' along with every other window option, as any split does,
-- and the plugin leaves ordinary split semantics alone.

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
	-- Before the buffer exists, so nothing can be displayed unwatched.
	M.watch_windows()

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

--------------------------------------------------------------------------------
-- The window options a spacetime buffer imposes on whatever window shows it
--------------------------------------------------------------------------------

---The window-local options every window is held to while it is showing a
---`spacetime://` buffer, and only while it is showing one. See the module
---header for why the list is this short: `'sidescroll'`, the obvious companion
---to `nowrap`, is a *global* option, and the plugin has no business changing
---the user's global settings to make its own window read better.
---@type table<string, any>
M.WINDOW_OPTIONS = {
	wrap = false,
}

-- The window-local variable a claimed window stashes its own values in. Its
-- presence is also the "this window is claimed" flag, so claiming twice cannot
-- overwrite the user's values with our own.
local SAVED_OPTIONS_VAR = "spacetime_saved_window_options"

---The augroup |spacetime.ui.buffer.watch_windows()| installs into.
M.WINDOW_AUGROUP = "SpacetimeWindowOptions"

---Is `bufnr` one of ours?
---@param bufnr integer
---@return boolean
local function is_spacetime_buffer(bufnr)
	return vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr):match("^spacetime://") ~= nil
end

---Impose |spacetime.ui.buffer.WINDOW_OPTIONS| on `winid`, remembering what the
---window had. Idempotent: a window already claimed keeps its saved values.
---@param winid integer
local function claim_window(winid)
	if not vim.api.nvim_win_is_valid(winid) then
		return
	end
	if not pcall(vim.api.nvim_win_get_var, winid, SAVED_OPTIONS_VAR) then
		local saved = {}
		for name in pairs(M.WINDOW_OPTIONS) do
			saved[name] = vim.wo[winid][name]
		end
		vim.api.nvim_win_set_var(winid, SAVED_OPTIONS_VAR, saved)
	end
	for name, value in pairs(M.WINDOW_OPTIONS) do
		vim.wo[winid][name] = value
	end
end

---Give `winid` its own options back. A no-op on a window we never claimed —
---which is what keeps this from imposing anything of ours on a window that
---merely happens to fire the autocommand.
---@param winid integer
local function release_window(winid)
	if not vim.api.nvim_win_is_valid(winid) then
		return
	end
	local ok, saved = pcall(vim.api.nvim_win_get_var, winid, SAVED_OPTIONS_VAR)
	if not ok or type(saved) ~= "table" then
		return
	end
	for name in pairs(M.WINDOW_OPTIONS) do
		if saved[name] ~= nil then
			vim.wo[winid][name] = saved[name]
		end
	end
	vim.api.nvim_win_del_var(winid, SAVED_OPTIONS_VAR)
end

-- Installed once per session. Cheap to re-install (the augroup is cleared), but
-- the flag keeps `M.get` from churning autocommands on every call.
local watching = false

---Keep every window showing a `spacetime://` buffer on our options, and every
---other window on its own.
---
---Called from |spacetime.ui.buffer.get()|, which is the only way a
---`spacetime://` buffer comes into existence — so the autocommand is always in
---place before one can be displayed. Idempotent.
---
---`BufWinEnter` alone, rather than a `BufWinEnter`/`BufWinLeave` pair: the
---event fires for the *new* buffer in the affected window, with that window
---current, whichever way the swap was made, so one handler sees both halves of
---the change. `BufWinLeave` would additionally miss the case where the buffer
---stays visible in a second window, and `BufEnter`/`BufLeave` are the wrong
---events entirely — they follow the cursor, and the layout deliberately leaves
---the cursor in the sidebar rather than in the content window.
function M.watch_windows()
	if watching then
		return
	end
	watching = true

	local group = vim.api.nvim_create_augroup(M.WINDOW_AUGROUP, { clear = true })
	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = group,
		desc = "spacetime.nvim: no 'wrap' while a spacetime:// buffer is on screen",
		callback = function(args)
			local winid = vim.api.nvim_get_current_win()
			if is_spacetime_buffer(args.buf) then
				claim_window(winid)
			else
				release_window(winid)
			end
		end,
	})
end

--------------------------------------------------------------------------------
-- Who is painting the content buffer
--------------------------------------------------------------------------------

-- The content buffer is shared: the row grid, the schema view and (later) the
-- log view all paint into it, and only one of them is on screen at a time. A
-- name rather than a handle, for the same reason the layout is found by buffer
-- name: it survives the buffer being wiped and recreated.
local content_owner = nil ---@type string|nil

---Claim the content buffer for `owner`.
---
---What a view calls before it paints. The point is the *other* view: a request
---that was already on the wire when the user switched views calls its own
---`render()` when it lands, and |spacetime.ui.buffer.owns_content()| is how that
---render knows it would be painting over somebody else's buffer.
---
---Keymaps are not touched here — each view applies its own through
---`spacetime.ui.keys`, which unbinds the previous view's as it goes.
---@param owner string A short, stable name: `"rows"`, `"schema"`.
function M.claim_content(owner)
	content_owner = owner
end

---Is `owner` the last view to have claimed the content buffer?
---@param owner string
---@return boolean
function M.owns_content(owner)
	return content_owner == owner
end

---Every window in the current tabpage showing `bufnr`, in the tabpage's order.
---
---Usually none or one, but a buffer is not a window: the user may `:split` the
---content window, and then two windows show `spacetime://content`. Teardown has
---to deal with all of them, or `q` leaves a scratch buffer on screen.
---@param bufnr integer
---@return integer[] winids
function M.windows_showing(bufnr)
	local winids = {} ---@type integer[]
	for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_buf(winid) == bufnr then
			winids[#winids + 1] = winid
		end
	end
	return winids
end

---The window in the current tabpage showing `bufnr`, if any.
---
---Public because it is also how a caller asks "is the layout open?" — the same
---question `open_layout` answers for itself, and one that must be answered the
---same way (by what is on screen now) rather than from a remembered handle.
---@param bufnr integer
---@return integer|nil winid
function M.window_showing(bufnr)
	return M.windows_showing(bufnr)[1]
end

---Move focus to the other half of the layout.
---
---What `<Tab>` does, from either window: there are exactly two of them, so one
---key serves both directions and there is no `<S-Tab>`. Which half you are in is
---decided by the buffer in the current window rather than by a window handle, for
---the same reason the layout itself is found by name — so a `:split` of the
---content window counts as "in the content window" and still tabs to the sidebar.
---
---Coming back the other way lands in |spacetime.ui.buffer.window_showing()| —
---the first content window in the tabpage's order — because a split is still one
---view of one buffer, and picking between the copies would be guesswork.
---
---A counterpart that is not on screen in the current tabpage is `false`, never an
---error: the caller says so and does nothing.
---@return boolean moved
function M.focus_other()
	local current = vim.api.nvim_get_current_win()
	local in_sidebar = vim.api.nvim_win_get_buf(current) == M.find(M.SIDEBAR_NAME)
	local target = M.find(in_sidebar and M.CONTENT_NAME or M.SIDEBAR_NAME)
	local winid = target and M.window_showing(target)
	if not winid or winid == current then
		return false
	end
	vim.api.nvim_set_current_win(winid)
	return true
end

---Is `winid` a floating window?
---
---Floats are in `nvim_tabpage_list_wins`, so a window count that does not filter
---them out is not the count Neovim closes windows by: closing the last
---*non-floating* window raises `E444` however many floats are on screen. A
---notification popup is enough to make the difference, so |M.normal_windows()|
---is what teardown counts with.
---@param winid integer
---@return boolean
function M.is_floating(winid)
	return vim.api.nvim_win_get_config(winid).relative ~= ""
end

---How many windows in the current tabpage Neovim would actually keep — every
---one that is not a float.
---@return integer
function M.normal_windows()
	local count = 0
	for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if not M.is_floating(winid) then
			count = count + 1
		end
	end
	return count
end

---Is `bufnr` one of the plugin's own `spacetime://` buffers?
---
---The name test, in one place: teardown asks it of a buffer it is about to put
---*back* in a window, and putting one of ours back is the one answer that is
---never right.
---@param bufnr integer|nil
---@return boolean
function M.is_ours(bufnr)
	return type(bufnr) == "number" and is_spacetime_buffer(bufnr)
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

	-- Chrome for a window the layout normally closes again, so it is set outright
	-- rather than saved — the exception is a sidebar window that turns out to be
	-- the last one in the tabpage, which teardown cannot close and hands to
	-- |spacetime.ui.buffer.unstyle_sidebar()| instead. `'wrap'` is deliberately
	-- not among these: it is the one option a *content* window has to give back,
	-- and it comes from the same place for both windows —
	-- |spacetime.ui.buffer.WINDOW_OPTIONS|, applied by the `BufWinEnter` watcher.
	M.style_sidebar(sidebar_win)

	vim.api.nvim_set_current_win(sidebar_win)
	return sidebar_win, content_win
end

---The window options that make `winid` look like a sidebar.
---@param winid integer
function M.style_sidebar(winid)
	local wo = vim.wo[winid]
	wo.winfixwidth = true
	wo.number = false
	wo.relativenumber = false
	wo.signcolumn = "no"
end

---Make `winid` an ordinary window again.
---
---For the one case where a sidebar window outlives the layout: it was the last
---window in the tabpage, so teardown gave it a buffer instead of closing it, and
---a window the user is going to keep working in must not be left pinned to the
---sidebar's width with its numbers off. The global values are what it gets back
---— they are what a new window would have — rather than remembered ones, which
---would have to survive an arbitrary session to be worth anything.
---@param winid integer
function M.unstyle_sidebar(winid)
	local wo = vim.wo[winid]
	wo.winfixwidth = false
	wo.number = vim.o.number
	wo.relativenumber = vim.o.relativenumber
	wo.signcolumn = vim.o.signcolumn
end

return M
