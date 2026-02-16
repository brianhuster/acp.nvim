require("acp.clipboard")

local buf = vim.api.nvim_get_current_buf()
local acp = require("acp.core")

vim.bo[buf].buftype = "prompt"
vim.bo[buf].bufhidden = "hide"
vim.bo[buf].swapfile = false
vim.wo[0][0].wrap = true
vim.wo[0][0].linebreak = true
vim.wo[0][0].statusline = "%!v:lua.require'acp.utils'.get_status_line()"

vim.treesitter.start(buf)

require("acp.lsp").start(buf)

if vim.lsp.inlay_hint then
	vim.lsp.inlay_hint.enable(true, { bufnr = buf })
end

vim.fn.prompt_setprompt(buf, "\027]133;A\a ")
vim.fn.prompt_setcallback(buf, function(text)
	acp.prompt_callback(buf, text)
end)
vim.fn.prompt_setinterrupt(buf, function()
	acp.cancel(buf)
end)

-- Highlight all lines started with the prompt OCP `"\027]133;A\a` as sign ▶
vim.schedule(function()
	vim.cmd([[
		setl conceallevel=2
		setl concealcursor=nivc
		syntax match Conceal /\%x1b]133;A\%x07/ conceal cchar=▶
	]])
end)

vim.keymap.set("n", "[[", function()
	vim.fn.search([[^\%x1b]133;A\%x07]], "b")
end, { buffer = buf, desc = "Go to previous prompt" })

vim.keymap.set("n", "]]", function()
	vim.fn.search([[^\%x1b]133;A\%x07]])
end, { buffer = buf, desc = "Go to next prompt" })

vim.b.undo_ftplugin = table.concat({
	vim.b.undo_ftplugin or "",
	"setlocal buftype< bufhidden< swapfile< conceallevel< concealcursor< wrap< linebreak<",
	"nunmap <buffer> [[",
	"nunmap <buffer> ]]",
	"lua vim.treesitter.stop(" .. buf .. ")",
}, "\n")
