# AGENTS GUIDE

acp.nvim is a plugin that implement the [Agent Client Protocol](https://agentclientprotocol.com/) client for Neovim. It allows you to interact with agents that support the protocol, such as `gemini`, `opencode` and more.

See also [CONTRIBUTING.md](CONTRIBUTING.md)

## Critical

ALWAYS read file before attempting to write it.

Whenever you see a file being overrided, it is very likely that your user edited it. Try to understand the meaning of the edit before undoing that override. If you remove the change your user made without permission, you may make him lose his edit (if he hasn't commited it), and he will be VERY ANGRY at you.

## Coding styles

See `.editorconfig` for coding styles. Here are some more details:

### For Lua files

- For local variable, they must start with a lowercase letter, like `local_variable` or `localVariable`, even if it is a constant. This is because LuaLS could confuse a local variable that start with an uppercase letter with a global variable. It is often recommended to use `local_variable` form for local variables
- For any custom type, it must have prefix `acp.` and start with an uppercase letter, like `acp.CustomType`. This is because it is a convention to use uppercase letters for types in Lua, and it helps to distinguish them from regular variables. It also helps to avoid conflicts with other libraries that may have similar names.
- For user commands, don't use Lua callback for custom completion. This is because Nvim doesn't support `custom` completion for user commands, which mean plugins have to filter result by themselves. Instead use a string like `"custom,v:lua.require'myplugin'.my_complete"`
- Never create global functions.
