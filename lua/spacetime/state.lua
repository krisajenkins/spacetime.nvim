-- The one module-level state table: in-flight requests, the sequence guard, the
-- debounce timers and the response cache. UI modules read `M.data` freely, but
-- mutate it only through the functions below.
--
-- The module sits in `lua/spacetime/` rather than `lib/` because it owns
-- `vim.uv` timers and `vim.schedule`. It still touches no
-- `vim.api`/`vim.fn`/`vim.ui`/`vim.notify` — the one thing it reports goes
-- through `spacetime.logger`, `require`d lazily inside the function that needs
-- it so a test can inject a stub.
--
-- **Why a sequence guard as well as `kill()`.** `lib/http.lua` guarantees that
-- *one handle's* late callback is silent after *its own* `kill()`. It says
-- nothing about ordering *between* handles, and that is where the real bug
-- lives: `<CR>` on table A, then quickly `<CR>` on table B. A's
-- `kill("sigterm")` can lose the race — curl has already written its response,
-- or the callback is already queued inside `vim.schedule` — so A's callback
-- runs *after* B's and repaints B's buffer with A's rows (ROADMAP.md, risk 3).
-- Killing the process cannot fix that; comparing tokens can. Every request
-- registers under a stable key, `start` hands back a monotonic token, and a
-- callback that cannot present the key's current token is dropped on the floor.
--
-- The counter is never reset, not even by `reset()`: keeping it monotonic for
-- the life of the session means a callback that outlives a reset can never
-- coincidentally match a reissued token.
--
-- The cache is session-lifetime with **no TTL and no expiry sweep**, keyed by
-- the same `M.key(...)` strings as the in-flight registry — one naming rule
-- instead of two, and a `rows:` key embeds its database so invalidating a
-- database is a prefix match. `r` (refresh) is the invalidation mechanism,
-- deliberately (ROADMAP.md, "Async and state discipline").

local M = {}

---@param ok any Truthy when the check passed.
---@param msg string What went wrong, without the module prefix.
local function want(ok, msg)
	if not ok then
		-- Level 3: `want` is called from a public function, so the error points
		-- at that function's caller rather than at this file.
		error("spacetime.state: " .. msg, 3)
	end
end

---@class SpacetimeStateData
---@field cache table<string,any> Session-lifetime, no TTL. Keyed by `M.key(...)`.
---@field inflight table<string,SpacetimeHttpHandle> At most one handle per key.
---@field seq table<string,integer> The live sequence token for each key.
---@field timers table<string,any> One reused `vim.uv` timer per debounce key.

---The one module-level state table.
---
---Read it freely; mutate it only through the `M.*` functions.
---@type SpacetimeStateData
M.data = { cache = {}, inflight = {}, seq = {}, timers = {} }

-- Monotonic for the life of the session. Bumped by `start` and by `cancel`,
-- never reset. See the module header.
local next_seq = 0

-- The trailing-edge function waiting on each debounce timer. Module-local
-- rather than a field of `M.data`: it is machinery, not state a UI module has
-- any business reading.
local pending = {} ---@type table<string,fun()>

--------------------------------------------------------------------------------
-- Keys
--------------------------------------------------------------------------------

---Stable key for a request and its cache entry.
---
---`"schema:<db>"`, `"rows:<db>.<table>"`, `"logs:<db>"`. The in-flight registry
---and the cache share this key space on purpose.
---@param kind "schema"|"rows"|"logs"
---@param db string Database name or identity.
---@param table_name? string Required for `"rows"`, ignored otherwise.
---@return string
function M.key(kind, db, table_name)
	want(kind == "schema" or kind == "rows" or kind == "logs", 'key kind must be "schema", "rows" or "logs"')
	want(type(db) == "string" and db ~= "", "key needs a non-empty database name")
	if kind == "rows" then
		want(type(table_name) == "string" and table_name ~= "", 'a "rows" key needs a table name')
		return ("rows:%s.%s"):format(db, table_name)
	end
	return kind .. ":" .. db
end

--------------------------------------------------------------------------------
-- Cancellation and the sequence guard
--------------------------------------------------------------------------------

---Kill a handle without letting a badly-behaved one propagate.
---
---`lib/http.lua`'s `kill` is idempotent and safe after completion, but a
---hand-written handle in a test may not be, and a cancel must never be the
---thing that raises. Called as `handle.kill()` — `http.lua` writes `kill` to
---ignore its argument, so the dot form works for both calling styles.
---@param handle SpacetimeHttpHandle|nil
local function kill(handle)
	if handle then
		pcall(handle.kill)
	end
end

---Register an in-flight request under `key`, killing the previous holder.
---
---Returns the sequence token the caller must present when its response lands:
---
---```lua
---local key = state.key("rows", db, tbl)
---local seq = state.start(key, http.request(req, function(err, res)
---  if not state.finish(key, seq) then return end -- stale: drop, silently
---  ...
---end))
---```
---
---`seq` is an upvalue assigned only after `http.request` returns, which is safe
---because every `on_done` is `vim.schedule_wrap`ped in `lib/http.lua` and so
---cannot fire before the assignment.
---@param key string
---@param handle SpacetimeHttpHandle A `{kill}` handle, from `lib/http`.
---@return integer seq The token that `finish`/`is_current` will accept.
function M.start(key, handle)
	want(type(key) == "string" and key ~= "", "start needs a non-empty key")
	want(type(handle) == "table" and type(handle.kill) == "function", "start needs a handle with a kill function")

	kill(M.data.inflight[key])

	next_seq = next_seq + 1
	M.data.inflight[key] = handle
	M.data.seq[key] = next_seq
	return next_seq
end

---Is `seq` still the live token for `key`?
---
---Read-only, for a mid-flight check (a streaming consumer deciding whether to
---keep appending). Use `finish` to accept a completed response.
---@param key string
---@param seq integer
---@return boolean
function M.is_current(key, seq)
	return M.data.seq[key] == seq
end

---Accept a response.
---
---`true` when `seq` is still the live token — the in-flight entry is cleared
---and the caller may proceed. `false` when the response is stale and must be
---discarded; that is normal operation, not a warning, so nothing is logged.
---@param key string
---@param seq integer The token `start` returned.
---@return boolean current
function M.finish(key, seq)
	if M.data.seq[key] ~= seq then
		return false
	end
	M.data.inflight[key] = nil
	M.data.seq[key] = nil
	return true
end

---Kill whatever is in flight under `key` and invalidate its token.
---
---A response already on its way is therefore dropped. Bumping the counter with
---no successor request matters: `:SpacetimeLogsStop` must invalidate even
---though nothing takes the key's place. No-op-ish when nothing is registered —
---the token is still burned.
---@param key string
function M.cancel(key)
	want(type(key) == "string" and key ~= "", "cancel needs a non-empty key")

	kill(M.data.inflight[key])
	M.data.inflight[key] = nil

	next_seq = next_seq + 1
	M.data.seq[key] = next_seq
end

---Cancel every in-flight key. For `q`, `BufWipeout` and `VimLeavePre`.
function M.cancel_all()
	-- Collected first: `cancel` writes to `M.data.inflight` as it goes.
	local keys = {} ---@type string[]
	for key in pairs(M.data.inflight) do
		keys[#keys + 1] = key
	end
	for _, key in ipairs(keys) do
		M.cancel(key)
	end
end

--------------------------------------------------------------------------------
-- Debounce
--------------------------------------------------------------------------------

---Run `fn` once, `ms` after the last call for `key`. Trailing edge only.
---
---There is no leading call: each call replaces the stored function with the
---latest and restarts the countdown, so N calls inside the window produce
---exactly one invocation, of the *last* function.
---
---One `vim.uv` timer per key, created on first use and reused forever after —
---stopped and restarted, never closed and recreated, which would leak a libuv
---handle on every cursor move. The uv callback runs in a |fast-event| context,
---so it only reschedules; `fn` itself runs on the main loop and may call
---`vim.api` (the intended consumer, `auto_preview`, sets buffer lines).
---@param key string
---@param ms integer Milliseconds. Must be >= 0.
---@param fn fun() Runs on the main loop.
function M.debounce(key, ms, fn)
	want(type(key) == "string" and key ~= "", "debounce needs a non-empty key")
	want(type(ms) == "number" and ms >= 0, "debounce needs a non-negative delay in milliseconds")
	want(type(fn) == "function", "debounce needs a function to run")

	local timer = M.data.timers[key]
	if not timer then
		timer = vim.uv.new_timer()
		M.data.timers[key] = timer
	end

	pending[key] = fn
	timer:stop()
	-- Repeat interval 0: one-shot.
	timer:start(ms, 0, function()
		timer:stop()
		-- Looked up rather than captured, so the *latest* function wins and a
		-- `cancel_debounce` that raced the timer still suppresses the call.
		local run = pending[key]
		pending[key] = nil
		if not run then
			return
		end
		vim.schedule(function()
			-- A failing callback must not take the timer with it: the key stays
			-- usable for the next debounce.
			local ok, err = pcall(run)
			if not ok then
				require("spacetime.logger").error(("debounced %s failed: %s"):format(key, err))
			end
		end)
	end)
end

---Drop a pending debounced call for `key`, if any.
---
---The timer itself stays allocated for reuse; only the queued function goes.
---@param key string
function M.cancel_debounce(key)
	want(type(key) == "string" and key ~= "", "cancel_debounce needs a non-empty key")

	pending[key] = nil
	local timer = M.data.timers[key]
	if timer then
		timer:stop()
	end
end

--------------------------------------------------------------------------------
-- Cache
--------------------------------------------------------------------------------

---@param key string
---@return any|nil # `nil` on a miss.
function M.cache_get(key)
	want(type(key) == "string" and key ~= "", "cache_get needs a non-empty key")
	return M.data.cache[key]
end

---Store `value` under `key`.
---
---Session lifetime, no TTL. Stored by reference, not copied: the caller must
---not keep mutating what it hands over.
---@param key string
---@param value any
function M.cache_set(key, value)
	want(type(key) == "string" and key ~= "", "cache_set needs a non-empty key")
	M.data.cache[key] = value
end

---Drop exactly one entry.
---@param key string
function M.cache_invalidate(key)
	want(type(key) == "string" and key ~= "", "cache_invalidate needs a non-empty key")
	M.data.cache[key] = nil
end

---Drop a database's schema entry and every `rows:<db>.*` entry under it.
---
---What `r` (refresh) does on a database node: a rows key embeds its database,
---so refreshing the database has to drop its dependents too.
---@param db string
function M.cache_invalidate_db(db)
	want(type(db) == "string" and db ~= "", "cache_invalidate_db needs a non-empty database name")

	M.data.cache["schema:" .. db] = nil
	-- The trailing dot is load-bearing: without it, refreshing `a` would also
	-- drop `rows:ab.t`.
	local prefix = "rows:" .. db .. "."
	for key in pairs(M.data.cache) do
		if key:sub(1, #prefix) == prefix then
			M.data.cache[key] = nil
		end
	end
end

---Drop every entry.
function M.cache_clear()
	M.data.cache = {}
end

--------------------------------------------------------------------------------
-- Teardown
--------------------------------------------------------------------------------

---Tear everything down: for tests, and for `q` closing the layout.
---
---Timers are closed here rather than merely stopped — an open libuv handle
---keeps a headless Neovim alive and would hang the test runner. The sequence
---counter is deliberately *not* reset; see the module header.
function M.reset()
	M.cancel_all()

	for _, timer in pairs(M.data.timers) do
		timer:stop()
		if not timer:is_closing() then
			timer:close()
		end
	end

	-- Closures capture the variable, not the table, so a uv callback that
	-- survives this finds the fresh empty table and has nothing to run.
	pending = {}
	M.data = { cache = {}, inflight = {}, seq = {}, timers = {} }
end

return M
