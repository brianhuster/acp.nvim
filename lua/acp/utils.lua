local M = {}
local api, fn = vim.api, vim.fn

---@param env acp.config.Env
---@return acp.EnvVariable[]
function M.configEnv2EnvVariables(env)
	local env_variables = {}
	for key, value in pairs(env) do
		table.insert(env_variables, { name = key, value = value })
	end
	return env_variables
end

---@param headers acp.config.HttpHeader
---@return acp.HttpHeader[]
function M.configHttpHeaders2HttpHeaderList(headers)
	local header_list = {}
	for key, value in pairs(headers) do
		table.insert(header_list, { name = key, value = value })
	end
	return header_list
end

---@param mcp_config acp.config.Mcp
---@return acp.McpServer[]
function M.configMcp2McpServer(mcp_config)
	local result = {}
	for name, config in pairs(mcp_config) do
		if config.cmd then
			table.insert(result, {
				name = name,
				command = config.cmd[1],
				args = vim.list_slice(config.cmd, 2),
				env = config.env and M.configEnv2EnvVariables(config.env) or nil,
			})
		elseif config.url then
			table.insert(result, {
				name = name,
				url = config.url,
				headers = config.headers and M.configHttpHeaders2HttpHeaderList(config.headers) or nil,
				env = config.env and M.configEnv2EnvVariables(config.env) or nil,
			})
		end
	end
	return result
end

---@param buf number
---@param text string
function M.append_text(buf, text)
	if not api.nvim_buf_is_valid(buf) then
		return
	end

	-- Get the prompt line position using the ': mark
	local prompt_pos = api.nvim_buf_get_mark(buf, ":")
	local prompt_line = prompt_pos[1] -- 1-indexed line number

	-- Get the line just before the prompt (where we append content)
	local content_line_idx = prompt_line - 2 -- 0-indexed (prompt_line - 1 - 1)

	if content_line_idx < 0 then
		-- No content line exists yet, insert a new line before prompt
		api.nvim_buf_set_lines(buf, 0, 0, false, { "" })
		content_line_idx = 0
	end

	-- Get the current content of that line
	local current_line = api.nvim_buf_get_lines(buf, content_line_idx, content_line_idx + 1, false)[1] or ""

	-- Append the new text to the current line
	local new_text = current_line .. text

	-- Split by newlines if the text contains them
	local lines = vim.split(new_text, "\n", { plain = true })

	-- Replace the current line and add any additional lines
	api.nvim_buf_set_lines(buf, content_line_idx, content_line_idx + 1, false, lines)

	for _, win in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_get_buf(win) == buf then
			local total_lines = api.nvim_buf_line_count(buf)
			local last_visible_line = fn.line("w$", win)

			-- Only auto-scroll if user was already at bottom
			if last_visible_line >= total_lines - 1 then
				api.nvim_win_set_cursor(win, { total_lines, 0 })
			end
		end
	end
end

---@param path string
---@return boolean, string
function M.valid_file_path(path)
	if fn.isabsolutepath(path) ~= 1 then
		return false, ("Path %s is not an absolute path"):format(path)
	end
	if fn.filereadable(path) ~= 1 and vim.fn.bufnr(path) < 0 then
		return false, ("File %s does not exist or is not readable"):format(path)
	end
	return true, ""
end

--- Get or create the buffer for the given agent and session
---@param agent_name string
---@param session_id string
---@param create? true whether to create the buffer if it doesn't exist
---@return number?
function M.get_acpchat_buf(agent_name, session_id, create)
	local bufname = ("acp://%s/%s"):format(agent_name, session_id)
	local buf = fn.bufnr(bufname, create)
	return buf > -1 and buf or nil
end

function M.get_acpplan_buf(agent_name, session_id, create)
	local bufname = ("acp-plan://%s/%s"):format(agent_name, session_id)
	local buf = fn.bufnr(bufname, create)
	return buf > -1 and buf or nil
end

return M
