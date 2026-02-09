# acp.nvim

A Neovim client for the [Agent Client Protocol (ACP)](https://agentclientprotocol.com/). Interact with AI agents directly in your editor with a non-blocking UI, asynchronous tool permissions, and side-by-side diff reviews.

## Features

- **Non-blocking Chat**: Communicate with agents in a dedicated prompt buffer.
- **Asynchronous Permissions**: Approve or reject tool calls (like file reads/writes) without freezing Neovim.
- **Side-by-side Diff Review**: Review proposed changes in a new tab with standard `vimdiff` styling via `:AcpViewDiff`.
- **Slash Commands**: Rich completion, signature help, and navigation for agent-defined commands using an in-process LSP.
- **Mode Support**: Toggle between different agent behaviors (e.g., Architect, Code, Ask).
- **MCP Integration**: Fully supports Model Context Protocol servers.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "brianhuster/acp.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
        vim.g.acp = {
            agents = {
                ["my-agent"] = {
                    cmd = { "node", "/path/to/agent.js" },
                    -- mcp = { "server-1", "server-2" } -- optional
                }
            }
        }
    end
}
```

## Usage

1.  **Start a session**: Run `:AcpStart <agent_name>`.
2.  **Interact**: Type your prompt. Use `/` to trigger slash command completion.
3.  **Permissions**: When an agent requests permission, type the corresponding number in the prompt.
4.  **Review Diffs**: Use `:AcpViewDiff` to see a side-by-side comparison of proposed file changes.
5.  **Change Modes**: Use `:AcpSetMode <mode_id>` to switch agent behavior.

## Commands

- `:AcpStart <name>`: Open a new chat buffer with the specified agent.
- `:AcpSetMode <mode>`: Switch the current session's mode (buffer-local).
- `:AcpViewDiff`: Open a side-by-side review tab for the last proposed diff.

## License

MIT
