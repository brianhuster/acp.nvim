local M = {}

function M.check()
	local acp = require("acp.core")
	local health = vim.health

	vim.health.start("Check acp.nvim dependencies")

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

	if vim.fn.executable("file") == 1 then
		health.ok("`file` command is available for MIME type detection")
	else
		health.warn("`file` command is not available. acp.nvim won't be able to detect MIME types of embedded content")
	end

	vim.health.start("List of working agents")
	vim.health.info(vim.inspect(acp.agents))
	vim.health.start("List of working sessions")
	vim.health.info(vim.inspect(acp.sessions))
end

return M
