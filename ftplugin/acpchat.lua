local bufnr = vim.api.nvim_get_current_buf()
local acp = require("acp")
local bufcommand = vim.api.nvim_buf_create_user_command

vim.bo[bufnr].buftype = "prompt"
vim.bo[bufnr].bufhidden = "hide"
vim.bo[bufnr].swapfile = false

vim.treesitter.start(bufnr)

vim.fn.prompt_setprompt(bufnr, "\027]133;A\a ")
vim.fn.prompt_setcallback(bufnr, function(text)
	acp.prompt_callback(bufnr, text)
end)
vim.fn.prompt_setinterrupt(bufnr, function()
	acp.cancel(bufnr)
end)

bufcommand(bufnr, "AcpSetMode", function(cmd)
	acp.set_mode(bufnr, cmd.args)
end, {
	nargs = 1,
	desc = "Set ACP mode for this buffer",
	complete = "custom,v:lua.require'acp'.acpsetmode_complete"
})

bufcommand(bufnr, "AcpViewDiff", function()
	acp.view_diff(bufnr)
end, {
	desc = "View pending diffs in split windows"
})

-- Highlight all lines started with the prompt OCP `"\027]133;A\a` as sign ▶
vim.schedule(function()
	vim.cmd [[
		setl conceallevel=2
		setl concealcursor=nivc
		syntax match Conceal /\%x1b]133;A\%x07/ conceal cchar=▶
	]]
end)

vim.keymap.set("n", "[[", function()
	vim.fn.search([[^\%x1b]133;A\%x07]], "b")
end, { buffer = bufnr, desc = "Go to previous prompt" })

vim.keymap.set("n", "]]", function()
	vim.fn.search([[^\%x1b]133;A\%x07]])
end, { buffer = bufnr, desc = "Go to next prompt" })

vim.b.undo_ftplugin = table.concat({
    vim.b.undo_ftplugin or "",
	"setlocal buftype< bufhidden< swapfile< conceallevel< concealcursor",
    "delcommand -buffer AcpSetMode",
    "lua vim.treesitter.stop(" .. bufnr .. ")",
	"nunmap <buffer> [[",
	"nunmap <buffer> ]]",
}, "\n")
