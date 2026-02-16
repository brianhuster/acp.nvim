local M = {}
local api, fn = vim.api, vim.fn
local config = require("acp.config").config

local log_path

---@param sig_num number
---@return string? name of the signal, or nil if not found
function M.get_signal_name(sig_num)
	-- Duyệt qua các hằng số của libuv để tìm tên tương ứng
	for name, val in pairs(vim.uv.constants) do
		if val == sig_num and name:match("^SIG") then
			return name
		end
	end
	return nil
end

---@return string
function M.random_string()
	local random_bytes = vim.uv.random(16) --[[@as string]]
	return vim.base64.encode(random_bytes)
end

---@param env acp.config.Env
---@return acp.EnvVariable[]
function M.configEnv2EnvVariables(env)
	local env_variables = {}
	for key, value in pairs(env) do
		table.insert(env_variables, { name = key, value = value })
	end
	return env_variables
end

---@param env_variables acp.EnvVariable[]
---@return acp.config.Env
function M.envVariables2ConfigEnv(env_variables)
	local env = {}
	for _, variable in ipairs(env_variables) do
		env[variable.name] = variable.value
	end
	return env
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
function M.add_output(buf, text)
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
	if not vim.fs.relpath(vim.fn.getcwd(), path) then
		return false, "Agents are not allowed to access paths outside the current working directory"
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
---@param type "chat"|"plan"|"resources"
---@return number?
function M.get_acp_buf(agent_name, session_id, type, create)
	local schemes = {
		chat = "acp",
		resources = "acp-resources",
		plan = "acp-plan",
	}
	local bufname = ("%s://%s/%s"):format(schemes[type], agent_name, session_id)
	local buf = fn.bufnr(bufname, create)
	if buf < 0 then
		return nil
	end
	if type ~= "chat" and create then
		vim.bo[buf].buftype = "nofile"
	end
	return buf
end

if vim.fn.executable("file") == 1 then
	---@type fun(content: string): string?
	M.get_mimetype = function(content)
		local res = vim.system({ "file", "--mime-type", "-b", "-" }, { stdin = content }):wait()
		if res.code == 0 then
			return vim.trim(res.stdout)
		end
	end
else
	M.get_mimetype = function()
		return nil
	end
end

---@param path string
---@param opts? { line?: number, limit?: number }
---@return string?
function M.read_file(path, opts)
	opts = opts or {}
	local buf_to_read = fn.bufnr(path)

	local content

	if buf_to_read ~= -1 and api.nvim_buf_is_loaded(buf_to_read) then
		local start = (opts.line or 1) - 1
		local limit = opts.limit or -1
		local lines = api.nvim_buf_get_lines(buf_to_read, start, limit == -1 and -1 or start + limit, false)
		content = table.concat(lines, "\n")
	else
		local f = io.open(path, "r")
		if not f then
			return
		end
		content = f:read("*a")
		f:close()
		if opts.line or opts.limit then
			local lines = vim.split(content, "\n", { plain = true })
			local start = (opts.line or 1)
			local end_idx = opts.limit and (start + opts.limit - 1) or #lines
			content = vim.iter(lines):slice(start, end_idx):join("\n")
		end
	end
	return content
end

---@param buf number
---@param enter boolean
---@param opts? vim.api.keyset.win_config
---@return number win_id 0 if failed
function M.open_win(buf, enter, opts)
	local buf_line_count = api.nvim_buf_line_count(buf)
	local default_opts = {
		relative = "win",
		win = api.nvim_get_current_win(),
		row = 0,
		col = 1,
		width = api.nvim_win_get_width(0),
		height = buf_line_count > 2 and buf_line_count or 2,
		noautocmd = true,
		border = vim.o.winborder ~= "" and vim.o.winborder or "rounded",
	}
	opts = vim.tbl_deep_extend("force", default_opts, opts or {})
	local win_id = api.nvim_open_win(buf, enter, opts)
	vim.wo[win_id].wrap = false
	vim.keymap.set("n", "q", function()
		api.nvim_win_close(win_id, true)
	end, { buffer = buf, nowait = true, silent = true })

	return win_id
end

--- Convert a file path to a URI. Unlike `vim.uri_from_fname`, this first
--- normalizes and absolutizes the path before converting it to a URI.
---@param path string
---@return string
function M.uri_from_fname(path)
	return vim.uri_from_fname(vim.fs.abspath(vim.fs.normalize(path)))
end

---@return string
function M.get_log_path()
	if not log_path then
		log_path = vim.fn.stdpath("log") .. "/acp.log"
	end
	return log_path
end

if config.debug then
	---@param table table
	function M.log(table)
		local content = vim.inspect(table, {
			process = function(item)
				if type(item) == "string" then
					local len = #item
					if len > 80 then
						return item:sub(1, 80) .. ("[...+%d bytes]"):format(len - 80)
					else
						return item
					end
				end
			end,
		})
		local file = io.open(M.get_log_path(), "a")
		if file then
			file:write(("[%s][%s] %s\n"):format("DEBUG", os.date("%Y-%m-%d %H:%M:%S"), content))
			file:close()
		end
	end
else
	M.log = function() end
end

return M
