local command = vim.api.nvim_create_user_command

command("AcpNewSession", function(opts)
	require("acp").new_session(opts.args)
end, {
	nargs = 1,
    desc = "Start ACP connection and open chat window.",
	complete = "custom,v:lua.require'acp'.acpstart_complete"
})

vim.treesitter.language.register("markdown", "acpchat")
