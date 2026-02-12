vim.cmd([[set rtp+=]] .. vim.fn.getcwd())

vim.cmd([[
set noswapfile
set clipboard=unnamedplus
set completeopt=menuone,noselect,preview,popup

au FileType acpchat inoremap <buffer> <CR> <S-CR>
au FileType acpchat nnoremap <buffer> <C-c> i<C-c><Esc>
]])

require("acp").config({
	agents = {
		test = {
			cmd = { "uv", "run", "tests/agent.py" },
			mcp = true,
		},
	},
	mcp = {
		nvim = {
			cmd = { "nvim-mcp" },
			env = {
				NVIM = vim.v.servername,
			},
		},
	},
	default_agent = "test",
})
vim.api.nvim_create_autocmd("LspAttach", {
	callback = function(args)
		local client = vim.lsp.get_client_by_id(args.data.client_id)
		if not client then
			return
		end
		if client:supports_method("textDocument/completion") then
			vim.lsp.completion.enable(true, client.id, args.buf, { autotrigger = true })
		end
	end,
})

require("acp").register_subcommand("--dumb", {
	callback = function() end,
})
