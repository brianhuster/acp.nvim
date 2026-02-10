local M = {}

function M.check()
	local acp = require("acp.core")
	local health = vim.health

	vim.health.start("acp.nvim")

	if vim.fn.has("nvim-0.12") == 1 then
		health.ok("Neovim version is 0.12 or higher")
	else
		health.error("Neovim version is below 0.12")
	end

	if vim.fn.has("linux") == 1 then
		local clipboard_prog = require("acp.clipboard").executable
		if vim.fn.executable(clipboard_prog) == 1 then
			health.ok("Clipboard program '" .. clipboard_prog .. "' is available")
		else
			health.warn(
				"Clipboard program '"
					.. clipboard_prog
					.. "' is not available. You won't be able to paste images or audio from the clipboard to acp.nvim"
			)
		end
	end

	vim.health.info("List of working agents >lua")
	vim.health.info(vim.inspect(acp.agents))
	vim.health.info("List of working sessions >lua")
	vim.health.info(vim.inspect(acp.sessions))
end

return M
