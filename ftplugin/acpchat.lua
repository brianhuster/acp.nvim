require("acp.clipboard")

local bufnr = vim.api.nvim_get_current_buf()
local acp = require("acp.core")

vim.bo[bufnr].buftype = "prompt"
vim.bo[bufnr].bufhidden = "hide"
vim.bo[bufnr].swapfile = false
vim.wo[0][0].wrap = true
vim.wo[0][0].linebreak = true

vim.treesitter.start(bufnr)

require("acp.lsp").start(bufnr)

if vim.lsp.inlay_hint then
	vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
end

vim.fn.prompt_setprompt(bufnr, "\027]133;A\a ")
vim.fn.prompt_setcallback(bufnr, function(text)
	acp.prompt_callback(bufnr, text)
end)
vim.fn.prompt_setinterrupt(bufnr, function()
	acp.cancel(bufnr)
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
end, { buffer = bufnr, desc = "Go to previous prompt" })

vim.keymap.set("n", "]]", function()
	vim.fn.search([[^\%x1b]133;A\%x07]])
end, { buffer = bufnr, desc = "Go to next prompt" })

vim.b.undo_ftplugin = table.concat({
	vim.b.undo_ftplugin or "",
	"setlocal buftype< bufhidden< swapfile< conceallevel< concealcursor< wrap< linebreak<",
	"nunmap <buffer> [[",
	"nunmap <buffer> ]]",
	"lua vim.treesitter.stop(" .. bufnr .. ")",
}, "\n")
