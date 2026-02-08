exe "set rtp+=" .. expand("<sfile>:p:h:h")
set clipboard=unnamedplus

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
EOF
