local M = {}

function M.check()
	local acp = require("acp.core")
	local health, fn = vim.health, vim.fn

	local log_path = vim.fn.stdpath("log") .. "/acp.log"
	local log_size = vim.fn.getfsize(log_path)
	if log_size > 0 then
		health.info("Log path: " .. log_path)
		health.info("Log size: " .. math.floor(vim.fn.getfsize(log_path) / 1024) .. " bytes")
	end

	health.start("Check acp.nvim dependencies")

	if fn.has("nvim-0.12") == 1 then
		health.ok("Neovim version is 0.12 or higher")
	else
		health.error("Neovim version is below 0.12")
	end

	if fn.has("linux") == 1 then
		local clipboard_prog = require("acp.clipboard").executable
		if fn.executable(clipboard_prog) == 1 then
			health.ok("Clipboard program '" .. clipboard_prog .. "' is available")
		else
			health.warn(
				"Clipboard program '"
					.. clipboard_prog
					.. "' is not available. You won't be able to paste images or audio from the clipboard to acp.nvim"
			)
		end
	end

	if fn.executable("file") == 1 then
		health.ok("`file` command is available for MIME type detection")
	else
		health.warn("`file` command is not available. acp.nvim won't be able to detect MIME types of embedded content")
	end

	health.start("List of working agents")
	health.info(vim.inspect(acp.agents))
	health.start("List of working sessions")
	health.info(vim.inspect(acp.sessions))
end

return M
