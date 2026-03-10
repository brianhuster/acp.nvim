local M = {}

local file_path = debug.getinfo(1, "S").source:sub(2)
local dirname = vim.fs.dirname
local dir_path = dirname(dirname(dirname(file_path)))

---@param opts acp.Config
M.config = function(opts)
	require("acp.config").set(opts)
end

---@param buf number
---@param path string
---@return boolean, any
M.add_resource = function(buf, path)
	local session = require("acp.core").sessions[buf]
	if not session then
		return false, "No active session for buffer " .. buf
	end
	local agent_name, session_id = session.agent_name, session.sessionId

	local resources_buf = require("acp.utils").get_acp_buf(agent_name, session_id, "resources", true) --[[@as integer]]
	vim.api.nvim_buf_set_lines(resources_buf, -1, -1, false, { path })
	return true
end

---@param name string name of the subcommand, must start with a non-alphanumeric character (e.g "-list")
---@param opts { callback: function }
M.register_subcommand = function(name, opts)
	-- name must start with non-alphanumeric character
	assert(name:match("^[^%w]"), "Subcommand name must start with a non-alphanumeric character")
	require("acp.core").ex_subcmd[name] = opts
end

return M
