-- spacetime.nvim plugin initialization.
-- Neovim loads this automatically when the plugin is on the runtimepath.
--
-- Keep this file to load-time wiring only — anything the plugin must register
-- before setup() is called (commands, highlight groups, autocommands). The
-- module itself stays lazy so requiring the plugin is cheap.

-- Only load once
if vim.g.loaded_spacetime then
	return
end
vim.g.loaded_spacetime = 1
