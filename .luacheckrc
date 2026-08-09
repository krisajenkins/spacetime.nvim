-- Luacheck configuration for spacetime.nvim

-- Neovim's LuaJIT ships without Lua 5.2 compat, so table.unpack is nil at
-- runtime and we use the global `unpack`. luacheck's "luajit" std is Lua
-- 5.1-based and already recognises the global `unpack`.
std = "luajit"

-- Global variables that are allowed
globals = {
    "vim",
    "MiniTest",
}

-- Read-only globals
read_globals = {
    "vim",
    "MiniTest",
}

-- Ignore unused self arguments
self = false

-- Maximum line length
max_line_length = 120

-- Exclude patterns
exclude_files = {
    "deps/**",
    ".luarocks/**",
}

-- Warning codes to ignore
ignore = {
    "212", -- Unused argument (for callbacks with unused parameters)
    "213", -- Unused loop variable
    "631", -- Line is too long (we handle this with max_line_length)
}

-- File-specific configuration
files["tests/"] = {
    globals = {"MiniTest"}
}

files["scripts/"] = {
    globals = {"vim"}
}
