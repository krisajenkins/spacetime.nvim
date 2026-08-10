-- Tests for the in-flight registry, the sequence guard, the debounce timers and
-- the cache.
--
-- No child Neovim: `state.lua` touches no editor surface, and a handle is just
-- a table with a `kill` function, so most cases run against a fake one. The
-- exception is the transport case, which drives the real `lib/http.request`
-- over its `http._system` seam with a deferred `on_exit`, so the wiring a
-- caller will actually write is exercised end to end.
--
-- `post_case` calls `state.reset()` unconditionally: an unclosed `vim.uv` timer
-- keeps the headless runner alive and would hang the suite rather than fail it.
local state = require("spacetime.state")
local http = require("spacetime.lib.http")
local expect = MiniTest.expect

local URL = "http://127.0.0.1:3000/v1/database/quickstart/sql"

---A handle that records its kills instead of touching a process.
---@param log string[] Appended to, once per kill.
---@param name string
---@return SpacetimeHttpHandle
local function fake_handle(log, name)
	return {
		kill = function()
			log[#log + 1] = name
		end,
	}
end

local T = MiniTest.new_set({
	hooks = {
		post_case = function()
			state.reset()
		end,
	},
})

--------------------------------------------------------------------------------
-- Keys
--------------------------------------------------------------------------------

T["key builds the three documented shapes"] = function()
	expect.equality(state.key("schema", "db"), "schema:db")
	expect.equality(state.key("rows", "db", "tbl"), "rows:db.tbl")
	expect.equality(state.key("logs", "db"), "logs:db")
end

T["a rows key without a table name raises"] = function()
	expect.error(function()
		state.key("rows", "db")
	end, "needs a table name")
	expect.error(function()
		state.key("frobnicate", "db")
	end, "key kind")
end

--------------------------------------------------------------------------------
-- Cancellation and the sequence guard
--------------------------------------------------------------------------------

T["starting a second request under one key kills the first"] = function()
	local killed = {} ---@type string[]
	local key = state.key("rows", "db", "person")

	local seq_a = state.start(key, fake_handle(killed, "a"))
	expect.equality(killed, {})

	local seq_b = state.start(key, fake_handle(killed, "b"))
	expect.equality(killed, { "a" })
	expect.no_equality(seq_a, seq_b)
end

T["a response arriving after a kill is dropped, not delivered"] = function()
	-- The bug the guard exists for: `<CR>` on table A, then quickly on table B.
	-- `kill` is asynchronous and can lose the race, so A's callback still runs —
	-- and without the token comparison it would paint A's rows into B's buffer.
	-- The handles here refuse to die, which is exactly that lost race.
	local key = state.key("rows", "db", "person")
	local dead_handle = { kill = function() end }

	local seq_a = state.start(key, dead_handle)
	local seq_b = state.start(key, dead_handle)

	local painted = {} ---@type string[]

	-- A's response lands late, after B has taken the key.
	if state.finish(key, seq_a) then
		painted[#painted + 1] = "rows of A"
	end
	expect.equality(painted, {})
	expect.equality(state.is_current(key, seq_a), false)

	-- B's response is the one the buffer is waiting for.
	if state.finish(key, seq_b) then
		painted[#painted + 1] = "rows of B"
	end
	expect.equality(painted, { "rows of B" })
end

T["two distinct keys do not invalidate each other"] = function()
	-- The guard must not over-reject: two tables open at once, completing out of
	-- the order they were started, are both still wanted.
	local killed = {} ---@type string[]
	local key_a = state.key("rows", "db", "person")
	local key_b = state.key("rows", "db", "planet")

	local seq_a = state.start(key_a, fake_handle(killed, "a"))
	local seq_b = state.start(key_b, fake_handle(killed, "b"))

	expect.equality(killed, {})
	expect.equality(state.finish(key_b, seq_b), true)
	expect.equality(state.finish(key_a, seq_a), true)
end

T["cancel kills the handle and invalidates its token"] = function()
	local killed = {} ---@type string[]
	local key = state.key("logs", "db")

	local seq = state.start(key, fake_handle(killed, "logs"))
	state.cancel(key)

	expect.equality(killed, { "logs" })
	-- No successor request took the key, and the token is still burned.
	expect.equality(state.is_current(key, seq), false)
	expect.equality(state.finish(key, seq), false)
end

T["cancel_all cancels every in-flight key"] = function()
	local killed = {} ---@type string[]
	local seq_a = state.start("schema:a", fake_handle(killed, "a"))
	local seq_b = state.start("schema:b", fake_handle(killed, "b"))

	state.cancel_all()

	table.sort(killed)
	expect.equality(killed, { "a", "b" })
	expect.equality(state.finish("schema:a", seq_a), false)
	expect.equality(state.finish("schema:b", seq_b), false)
end

T["finish accepts a token exactly once"] = function()
	local killed = {} ---@type string[]
	local key = state.key("schema", "db")

	local seq = state.start(key, fake_handle(killed, "schema"))
	expect.equality(state.finish(key, seq), true)
	expect.equality(state.finish(key, seq), false)
end

T["start rejects a handle it cannot kill"] = function()
	expect.error(function()
		state.start("schema:db", { kill = "not a function" })
	end, "kill function")
	expect.error(function()
		state.start("", { kill = function() end })
	end, "non%-empty key")
end

T["a handle whose kill raises does not break the restart"] = function()
	local key = state.key("schema", "db")
	state.start(key, {
		kill = function()
			error("this handle is broken")
		end,
	})
	local killed = {} ---@type string[]
	expect.no_error(function()
		state.start(key, fake_handle(killed, "b"))
	end)
end

--------------------------------------------------------------------------------
-- The real transport
--------------------------------------------------------------------------------

T["over the real transport a superseded request is killed and disregarded"] = function()
	local saved = http._system
	local exits = {} ---@type fun(out: table)[]
	local signals = {} ---@type string[]

	http._system = function(_, _, on_exit)
		exits[#exits + 1] = on_exit
		return {
			kill = function(_, signal)
				signals[#signals + 1] = signal
			end,
		}
	end

	local key = state.key("rows", "quickstart", "person")
	local painted = {} ---@type string[]

	local seq_a ---@type integer
	seq_a = state.start(
		key,
		http.request({ url = URL }, function(_, res)
			if not state.finish(key, seq_a) then
				return
			end
			painted[#painted + 1] = res and res.body or "?"
		end)
	)

	local seq_b ---@type integer
	seq_b = state.start(
		key,
		http.request({ url = URL }, function(_, res)
			if not state.finish(key, seq_b) then
				return
			end
			painted[#painted + 1] = res and res.body or "?"
		end)
	)

	-- `start` reached the process: A's curl got a SIGTERM.
	expect.equality(signals, { "sigterm" })
	-- And A's token is stale, so a callback that outran the signal is refused.
	expect.equality(state.is_current(key, seq_a), false)

	-- A's response arrives anyway — the kill lost the race — then B's.
	exits[1]({ code = 0, stdout = "HTTP/1.1 200 OK\r\n\r\nrows of A", stderr = "" })
	exits[2]({ code = 0, stdout = "HTTP/1.1 200 OK\r\n\r\nrows of B", stderr = "" })

	expect.equality(
		vim.wait(1000, function()
			return #painted > 0
		end, 5),
		true
	)
	-- Settle, so a late A would have had every chance to show up.
	vim.wait(50)

	expect.equality(painted, { "rows of B" })

	http._system = saved
end

--------------------------------------------------------------------------------
-- Debounce
--------------------------------------------------------------------------------

T["rapid debounce calls coalesce to one invocation of the last function"] = function()
	local calls = {} ---@type string[]
	for _, id in ipairs({ "first", "second", "third" }) do
		state.debounce("k", 20, function()
			calls[#calls + 1] = id
		end)
	end

	expect.equality(
		vim.wait(1000, function()
			return #calls > 0
		end, 5),
		true
	)
	-- Give a second (wrong) invocation room to appear.
	vim.wait(60)
	expect.equality(calls, { "third" })
end

T["a debounce key reuses its timer and fires again"] = function()
	local calls = 0
	state.debounce("k", 10, function()
		calls = calls + 1
	end)
	local timer = state.data.timers.k
	expect.equality(timer ~= nil, true)

	expect.equality(
		vim.wait(1000, function()
			return calls == 1
		end, 5),
		true
	)

	state.debounce("k", 10, function()
		calls = calls + 1
	end)
	expect.equality(state.data.timers.k, timer)
	expect.equality(
		vim.wait(1000, function()
			return calls == 2
		end, 5),
		true
	)
end

T["a failing debounced function does not disable the key"] = function()
	local logged = {} ---@type string[]
	local saved_logger = package.loaded["spacetime.logger"]
	package.loaded["spacetime.logger"] = {
		error = function(msg)
			logged[#logged + 1] = msg
		end,
	}

	state.debounce("k", 10, function()
		error("boom")
	end)
	expect.equality(
		vim.wait(1000, function()
			return #logged > 0
		end, 5),
		true
	)

	local ran = false
	state.debounce("k", 10, function()
		ran = true
	end)
	expect.equality(
		vim.wait(1000, function()
			return ran
		end, 5),
		true
	)

	package.loaded["spacetime.logger"] = saved_logger
end

T["cancel_debounce drops a pending call"] = function()
	local calls = 0
	state.debounce("k", 20, function()
		calls = calls + 1
	end)
	state.cancel_debounce("k")

	vim.wait(80)
	expect.equality(calls, 0)
	-- The timer is kept for reuse rather than closed.
	expect.equality(state.data.timers.k ~= nil, true)
end

T["debounce rejects a negative delay"] = function()
	expect.error(function()
		state.debounce("k", -1, function() end)
	end, "non%-negative")
	expect.error(function()
		state.debounce("k", 10, "not a function")
	end, "needs a function")
end

--------------------------------------------------------------------------------
-- Cache
--------------------------------------------------------------------------------

T["cache set, get and invalidate round-trip"] = function()
	local key = state.key("schema", "db")
	expect.equality(state.cache_get(key), nil)

	local schema = { tables = { "person" } }
	state.cache_set(key, schema)
	-- Stored by reference, not copied.
	expect.equality(state.cache_get(key), schema)

	state.cache_invalidate(key)
	expect.equality(state.cache_get(key), nil)
end

T["cache_invalidate_db drops the database and its rows, and nothing else"] = function()
	state.cache_set(state.key("schema", "a"), "schema a")
	state.cache_set(state.key("rows", "a", "person"), "rows a.person")
	state.cache_set(state.key("schema", "ab"), "schema ab")
	state.cache_set(state.key("rows", "ab", "person"), "rows ab.person")
	state.cache_set(state.key("rows", "b", "person"), "rows b.person")

	state.cache_invalidate_db("a")

	expect.equality(state.cache_get("schema:a"), nil)
	expect.equality(state.cache_get("rows:a.person"), nil)
	-- The prefix match must not spill into a database whose name starts the same.
	expect.equality(state.cache_get("schema:ab"), "schema ab")
	expect.equality(state.cache_get("rows:ab.person"), "rows ab.person")
	expect.equality(state.cache_get("rows:b.person"), "rows b.person")
end

T["cache_clear drops everything"] = function()
	state.cache_set("schema:a", 1)
	state.cache_set("rows:b.t", 2)
	state.cache_clear()
	expect.equality(state.cache_get("schema:a"), nil)
	expect.equality(state.cache_get("rows:b.t"), nil)
end

--------------------------------------------------------------------------------
-- reset
--------------------------------------------------------------------------------

T["reset kills in-flight handles and cancels pending debounces"] = function()
	local killed = {} ---@type string[]
	local key = state.key("rows", "db", "person")
	local seq = state.start(key, fake_handle(killed, "rows"))
	state.cache_set(key, "cached")

	local calls = 0
	state.debounce("k", 20, function()
		calls = calls + 1
	end)

	state.reset()

	expect.equality(killed, { "rows" })
	expect.equality(state.data.inflight, {})
	expect.equality(state.data.timers, {})
	expect.equality(state.cache_get(key), nil)
	-- The counter is never reset, so a callback outliving the reset stays stale.
	expect.equality(state.finish(key, seq), false)

	vim.wait(80)
	expect.equality(calls, 0)
end

return T
