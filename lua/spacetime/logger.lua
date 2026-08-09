local M = {}

local log_level = vim.log.levels.INFO

function M.debug(msg)
	if log_level <= vim.log.levels.DEBUG then
		vim.notify("[spacetime] " .. msg, vim.log.levels.DEBUG)
	end
end

function M.info(msg)
	if log_level <= vim.log.levels.INFO then
		vim.notify("[spacetime] " .. msg, vim.log.levels.INFO)
	end
end

function M.warn(msg)
	if log_level <= vim.log.levels.WARN then
		vim.notify("[spacetime] " .. msg, vim.log.levels.WARN)
	end
end

function M.error(msg)
	if log_level <= vim.log.levels.ERROR then
		vim.notify("[spacetime] " .. msg, vim.log.levels.ERROR)
	end
end

function M.set_level(level)
	log_level = level
end

return M
