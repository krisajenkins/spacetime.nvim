# Default target - run checks and tests
all: typecheck test

# Run all test files
test: deps/mini.nvim
	nvim --headless --noplugin -u ./scripts/minimal_init.lua -c "lua MiniTest.run()" -c "qa!"

# Run test from file at `$FILE` environment variable
test_file: deps/mini.nvim
	nvim --headless --noplugin -u ./scripts/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')" -c "qa!"

# Format Lua code with stylua
format:
	stylua lua plugin scripts tests

# Check formatting without modifying files (used in CI)
check-format:
	stylua --check lua plugin scripts tests

# Static analysis: luacheck (linting) plus lua-language-server (type checking).
# The two are complementary — luacheck catches lint issues, lua_ls verifies the
# LuaCATS type annotations that luacheck ignores entirely.
typecheck: luacheck lua-ls

# Lint with luacheck
luacheck:
	@echo "Running static analysis with luacheck..."
	@luacheck lua plugin scripts tests

# Type-check the LuaCATS annotations with lua-language-server.
#
# lua_ls treats the --check path as the workspace root, so it will not discover
# the repo-root .luarc.json on its own — point it there with an absolute path
# (a bare/relative path would be resolved against lua/ and silently ignored,
# leaving vim et al. undefined and flooding the run with false positives).
#
# --check exits non-zero when it finds any diagnostic at or above --checklevel,
# which fails the build. Severities are configured in .luarc.json.
lua-ls:
	@echo "Type-checking with lua-language-server..."
	@lua-language-server --check=lua --checklevel=Warning --configpath=$(CURDIR)/.luarc.json

# Record the README demo into demo.gif (tracked in git).
#
# Needs a SpacetimeDB on 127.0.0.1:3000 serving `medium-epic-events`;
# scripts/record-demo-setup.sh checks for both and stops if either is missing.
demo:
	vhs scripts/record-demo.tape

# Regenerate the vimdoc help tags after editing doc/*.txt. doc/tags is tracked.
helptags:
	nvim --headless -c "helptags doc/" -c "quit"

# Download 'mini.nvim' to use its 'mini.test' testing module
deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/echasnovski/mini.nvim $@

.PHONY: all test test_file format check-format typecheck luacheck lua-ls demo helptags
