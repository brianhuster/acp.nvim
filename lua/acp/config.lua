---@class acp.config.Agent
---@field cmd string[] Command to start the agent (e.g., {"opencode", "acp"})
---@field env? acp.config.Env Environment variables to set when starting the agent
---@field mcp? string[]|true List of context server names to use, or true to use all defined

---@alias acp.config.Env table<string, string>
---@alias acp.config.HttpHeader table<string, string>

---@alias acp.config.mcp.Stdio { cmd: string[], env?: acp.config.Env }
---@alias acp.config.mcp.Http { url: string, headers?: acp.config.HttpHeader, env?: acp.config.Env }
---@alias acp.config.Mcp table<string, acp.config.mcp.Stdio | acp.config.mcp.Http>

---@class acp.Config
---@field agents? table<string, acp.config.Agent> Mapping of agent names to their configurations
---@field mcp? acp.config.Mcp Mapping of context server names to their configurations
---@field default_agent? string Name of the default agent to use when starting a session without specifying an agent
---@field debug? boolean Whether to enable debug logging (default: false)

local M = {}

---@type acp.Config
M.config = {}

---@param opts acp.Config
M.set = function(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts)
end

return M
