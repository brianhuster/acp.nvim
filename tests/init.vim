exe "set rtp+=" .. expand("<sfile>:p:h:h")
set clipboard=unnamedplus
set completeopt=menuone,noselect,preview,popup

au FileType acpchat inoremap <buffer> <CR> <S-CR>
au FileType acpchat nnoremap <buffer> <C-c> i<C-c><Esc>

lua << EOF
vim.g.acp = {
	agents = {
		test = {
			cmd = { "npx", "tsx", "agent.ts" },
			mcp = true
		}
	},
	mcp = {
		nvim = {
			cmd = { 'nvim-mcp' },
			env = {
				NVIM = vim.v.servername
			}
		}
	}
}
vim.api.nvim_create_autocmd('LspAttach', {
	callback = function(args)
		local client = vim.lsp.get_client_by_id(args.data.client_id)
		if not client then return end
		if client:supports_method('textDocument/completion') then
			vim.lsp.completion.enable(true, client.id, args.buf, { autotrigger = true })
		end
	end,
})
EOF
