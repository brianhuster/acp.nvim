local command = vim.api.nvim_create_user_command

command("Acp", function(opts)
	require("acp.core").ex(opts.fargs)
end, {
	nargs = "+",
	desc = "acp.nvim",
	complete = "custom,v:lua.require'acp.core'.ex_complete",
})

vim.api.nvim_create_autocmd("BufReadCmd", {
	pattern = "acp://**",
	callback = function(a)
		if require("acp.core").sessions[a.buf] then
			return -- Session already exists for this buffer, do nothing
		end
		vim.bo[a.buf].filetype = "acpchat"
		local bufname = a.match
		local agent = bufname:match("^acp://([^/]+)")
		local sessionId = bufname:match("^acp://[^/]+/(.+)$")
		require("acp.core").create_or_load_session(agent, sessionId)
	end,
})
