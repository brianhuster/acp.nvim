local command = vim.api.nvim_create_user_command

command("Acp", function(opts)
	require("acp.core").ex(opts.fargs)
end, {
	nargs = "+",
	desc = "acp.nvim",
	complete = "custom,v:lua.require'acp.core'.ex_complete",
})

vim.treesitter.language.register("markdown", "acpchat")
