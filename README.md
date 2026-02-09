# acp.nvim

Agent Client Protocol (ACP) client for Neovim.

NOTE: this plugin is in early development. Use at your own risk

## Requirements

- Neovim >= 0.12
- An ACP-compatible agent installed (e.g., `opencode`)

## Installation

You can install `acp.nvim` using any plugin manager that supports `git`, like [lazy.nvim](https://github.com/folke/lazy.nvim), [vim-plug](https://github.com/junegunn/vim-plug), etc. See the documentation of your plugin manager for how to install a plugin with them.

Nvim 0.12 has a built-in plugin manager, so you can also install `unnest.nvim` using
```lua
vim.pack.add { "https://github.com/brianhuster/unnest.nvim" }
```

## Usage

See [`:h acp`](./doc/acp.txt) for more details.
