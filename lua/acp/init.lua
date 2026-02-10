local M = {}

---@param opts acp.Config
M.config = function(opts)
	require("acp.config").set(opts)
end

return M
