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

-- The one eager require: highlight groups must exist before any renderer (or a
-- user's colourscheme override) can reference them. The module is a table of
-- names plus two nvim_set_hl loops — cheap and dependency-free, so it does not
-- break the "module stays lazy" rule above.
require("spacetime.ui.highlights").register()
