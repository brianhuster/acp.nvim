require("acp.clipboard")

local buf = vim.api.nvim_get_current_buf()
local acp = require("acp.core")
local prompt = "▶ "
local prompt_regex = "^" .. prompt

vim.bo[buf].buftype = "prompt"
vim.bo[buf].swapfile = false
vim.wo[0][0].statusline = "%!v:lua.require'acp.utils'.get_status_line()"

vim.treesitter.start(buf, "markdown")
vim.cmd(([[syntax match acpPrompt /%s/
highlight link acpPrompt Comment]]):format(prompt_regex))

require("acp.lsp").start(buf)
vim.lsp.inlay_hint.enable(true, { bufnr = buf })

vim.fn.prompt_setprompt(buf, prompt)
vim.fn.prompt_setcallback(buf, function(text)
	acp.prompt_callback(buf, text)
end)
vim.fn.prompt_setinterrupt(buf, function()
	acp.cancel(buf)
end)

vim.keymap.set("n", "[[", function()
	vim.fn.search(prompt_regex, "b")
end, { buffer = buf, desc = "Go to previous prompt" })

vim.keymap.set("n", "]]", function()
	vim.fn.search(prompt_regex)
end, { buffer = buf, desc = "Go to next prompt" })

vim.b.undo_ftplugin = table.concat({
	vim.b.undo_ftplugin or "",
	"setlocal buftype< swapfile< statusline<",
	"nunmap <buffer> [[",
	"nunmap <buffer> ]]",
	"lua vim.treesitter.stop(" .. buf .. ")",
}, "\n")
