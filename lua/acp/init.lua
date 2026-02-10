local M = {}
local vim = vim
local api, fn, iter = vim.api, vim.fn, vim.iter
local utils = require("acp.utils")
local meta = require("acp.meta")
local rpc = require("acp.rpc")

local agent_methods = meta.agentMethods
local client_methods = meta.clientMethods

---@class acp.AgentConfig
---@field cmd string[] Command to start the agent (e.g., {"opencode", "acp"})
---@field env? acp.config.Env Environment variables to set when starting the agent
---@field mcp? string[]|true List of context server names to use, or true to use all defined

---@class acp.Config
---@field agents? table<string, acp.AgentConfig> Mapping of agent names to their configurations
---@field mcp? acp.config.Mcp Mapping of context server names to their configurations

---@class acp.Session
---@field agent_name string
---@field client acp.rpc.Client
---@field session_id string
---@field modes? acp.SessionModeState
---@field pending_permission { options: acp.PermissionOption[], response: fun(result: any?, error: acp.rpc.Error?) }>
---@field lastest_diff? acp.Diff
---@field available_commands? acp.AvailableCommand[]

---@type table<number, acp.Session>
M.sessions = {}

---@type table<string, acp.rpc.Client>
M.agents = {}

---@type acp.Config
local default_config = {
	agents = {},
	mcp = {},
}

---@type acp.Config
M.config = vim.tbl_deep_extend("force", default_config, vim.g.acp or {})

---@param agent string
---@param method string
---@param params acp.RequestPermissionRequest|acp.ReadTextFileRequest|acp.WriteTextFileRequest
---@param response fun(result: any?, error: acp.rpc.Error?)
local function handle_server_request(agent, method, params, response)
	local buf = utils.get_acpchat_buf(agent, params.sessionId)

	if method == client_methods.session_request_permission then
		local p = params --[[@as acp.RequestPermissionRequest ]]
		local title = p.toolCall.title or "Unknown tool"
		local options = p.options
		local session = M.sessions[buf]

		-- Store request context in the session
		session.pending_permission = { options = options, response = response }
		vim.b.acp_requesting_permission = true

		local lines = { "\n⚠️ Permission required: " .. title }
		for i, o in ipairs(options) do
			table.insert(lines, ("  %d. %s"):format(i, o.name))
		end
		table.insert(lines, "Type number to choose (or use :AcpViewDiff to review):")
		utils.append_text(buf, table.concat(lines, "\n") .. " ")

	elseif method == client_methods.fs_read_text_file then
        local p = params --[[@as acp.ReadTextFileRequest ]]
        local path = p.path
        local path_valid, err = utils.valid_file_path(path)
		if not path_valid then
			response(nil, { code = rpc.code.invalid_params, message = err })
			return
		end

		local buf_to_read = fn.bufnr(p.path)

		local content
		local source = "file"

		if buf_to_read ~= -1 and api.nvim_buf_is_loaded(buf_to_read) then
			local start = (p.line or 1) - 1
			local limit = p.limit or -1
			local lines = api.nvim_buf_get_lines(buf_to_read, start, limit == -1 and -1 or start + limit, false)
			content = table.concat(lines, "\n")
			source = "buffer"
		else
			local f = io.open(p.path, "r")
			if not f then
				response(nil, { code = -32603, message = "Could not open file: " .. path })
				return
			end
			content = f:read("*a")
			f:close()

			if p.line or p.limit then
				local lines = vim.split(content, "\n", { plain = true })
				local start = (p.line or 1)
				local end_idx = p.limit and (start + p.limit - 1) or #lines
				content = table.concat(iter(lines):slice(start, end_idx):totable(), "\n")
			end
		end

		utils.append_text(buf, ("[Read %s (%d bytes) from %s]\n"):format(path, #content, source))
		response({ content = content })

	elseif method == client_methods.fs_write_text_file then
		local p = params --[[@as acp.WriteTextFileRequest ]]
        local path = p.path
        local path_valid, err = utils.valid_file_path(path)
        if not path_valid then
            response(nil, { code = rpc.code.invalid_params, message = err })
            return
        end

		local buf_to_write = fn.bufnr(path)

		if buf_to_write ~= -1 and api.nvim_buf_is_loaded(buf_to_write) then
			local lines = vim.split(p.content, "\n", { plain = true })
			api.nvim_buf_set_lines(buf_to_write, 0, -1, false, lines)
			utils.append_text(buf, ("[Wrote %d bytes to buffer %s]\n"):format(#p.content, path))
			response({})
		else
			local dir = fn.fnamemodify(path, ":h")
			fn.mkdir(dir, "p")
			local f = io.open(path, "w")
			if not f then
				response(nil, { code = -32603, message = "Could not open file for writing: " .. path })
				return
			end
			f:write(p.content)
			f:close()
			utils.append_text(buf, ("[Wrote %d bytes to %s]\n"):format(#p.content, path))
			response({})
		end
	else
		response(nil, { code = -32601, message = "Method not found: " .. method })
	end
end

---@param agent string
---@param method string
---@param params any
local function handle_notification(agent, method, params)
	if method == client_methods.session_update then
		---@type acp.SessionNotification
		local p = params
		local u = p.update
		local buf = utils.get_acpchat_buf(agent, p.sessionId)
		local session = M.sessions[buf]

        if u.sessionUpdate == "agent_message_chunk" then
            local content = u.content
            if content and content.type == "text" then
                utils.append_text(buf, content.text)
            end
        elseif u.sessionUpdate == "tool_call" then
            utils.append_text(buf, ("\n🔧 %s (%s)\n"):format(u.title, u.status or "pending"))
            for _, tc in ipairs(u.content or {}) do
                if tc.content and tc.content.type == "text" then
                    utils.append_text(buf, tc.content.text)
                elseif tc.newText then -- Diff
                    session.lastest_diff = tc --[[@as acp.Diff ]]
                    local old = tc.oldText or ""
                    local diff = vim.text.diff(old, tc.newText, { result_type = "unified" })
                    if diff ~= "" then
                        utils.append_text(buf, ("\n```diff\n--- %s\n+++ %s\n%s\n```\n"):format(tc.path, tc.path, diff))
                    end
                end
            end
        elseif u.sessionUpdate == "tool_call_update" then
            local has_title = u.title ~= nil
            local has_status = u.status ~= nil
            local has_content = u.content and #u.content > 0

            if has_title and has_status then
                utils.append_text(buf, ("\n🔧 %s (%s)\n"):format(u.title, u.status))
            elseif has_title then
                utils.append_text(buf, ("\n🔧 %s\n"):format(u.title))
            elseif has_status and has_content then
                utils.append_text(buf, ("\n🔧 %s\n"):format(u.status))
            end

            for _, tc in ipairs(u.content or {}) do
                if tc.content and tc.content.type == "text" then
                    utils.append_text(buf, tc.content.text)
                elseif tc.newText then -- Diff
                    session.lastest_diff = tc
                    local old = tc.oldText or ""
                    local diff = vim.text.diff(old, tc.newText, { result_type = "unified" })
                    if diff ~= "" then
						utils.append_text(buf,
							("\nTo see this diff in a split view, run `:AcpViewDiff`\n```diff\n--- %s\n+++ %s\n%s\n```\n")
							:format(tc.path, tc.path, diff))
                    end
                end
            end
        elseif u.sessionUpdate == "plan" then
            utils.append_text(buf, "[Plan update]\n")
        elseif u.sessionUpdate == "agent_thought_chunk" then
            local content = u.content
            if content and content.type == "text" then
                utils.append_text(buf, ("[Thought] %s\n"):format(content.text))
            end
        elseif u.sessionUpdate == "current_mode_update" then
            if session.modes and u.currentModeId then
                session.modes.currentModeId = u.currentModeId
            end
        elseif u.sessionUpdate == "available_commands_update" then
			session.available_commands = u.availableCommands
        end
	end
end

---@param agent_name string
---@return acp.rpc.Client?
local function start_agent(agent_name)
	if M.agents[agent_name] then
		return M.agents[agent_name]
	end

	local agent_config = M.config.agents[agent_name]
	if not agent_config then
		vim.notify("No configuration found for agent: " .. agent_name, vim.log.levels.ERROR)
		return nil
	end

	local cmd = agent_config.cmd
	local env = agent_config.env or {}

	local rpc_client = require("acp.rpc").start(cmd, {
		on_error = function(code, err)
			vim.notify(("Agent '%s' error (%d): %s"):format(agent_name, code, err), vim.log.levels.ERROR)
		end,
		on_exit = function(code, _)
			vim.notify(("Agent '%s' exited with code %d"):format(agent_name, code), vim.log.levels.INFO)
			for buf, session in pairs(M.sessions) do
				if session.agent_name == agent_name then
					utils.append_text(buf, ("\n[Agent '%s' has exited]\n"):format(agent_name))
					M.sessions[buf] = nil
				end
			end
		end,
		notification = function(_method, params)
			handle_notification(agent_name, _method, params)
		end,
		server_request = function(_id, method, params, response)
			handle_server_request(agent_name, method, params, response)
		end,
	}, { env = env })

	return rpc_client
end

--- Start the ACP connection for a buffer
---@param agent_name string
function M.new_session(agent_name)
	local client = start_agent(agent_name)
	if not client then return end

	-- 1. Initialize
	client.request(agent_methods.initialize, {
		protocolVersion = meta.version,
		clientCapabilities = {
			fs = { readTextFile = true, writeTextFile = true },
			terminal = false,
		},
		clientInfo = {
			name = "acp.nvim",
			version = "0.1.0",
			title = "ACP client for Neovim",
		},
	}, function(err, init_res)
		if err then
			vim.notify("Initialize error: " .. vim.inspect(err), vim.log.levels.ERROR)
			return
		end

		-- 2. Create Session
		local mcp = {}
		if M.config.agents[agent_name].mcp then
			local mcp_names = M.config.agents[agent_name].mcp
			if vim.islist(mcp_names) then
				local mcp_config = {}
				for _, name in ipairs(mcp_names --[[@as string[] ]]) do
					mcp_config[name] = M.config.mcp[name]
				end
				mcp = utils.configMcp2McpServer(mcp_config)
			elseif mcp_names == true then
				mcp = utils.configMcp2McpServer(M.config.mcp)
			end
		end

		-- Filter MCP servers based on agent capabilities
		local agent_caps = init_res.agentCapabilities or {}
		local mcp_caps = agent_caps.mcpCapabilities or {}
		local filtered_mcp = {}
		for _, srv in ipairs(mcp) do
			if srv.url then
				local is_sse = srv.url:match("^sse%+") or srv.url:match("^http") -- simplified
				if is_sse and mcp_caps.sse then
					table.insert(filtered_mcp, srv)
				elseif not is_sse and mcp_caps.http then
					table.insert(filtered_mcp, srv)
				end
			else
				table.insert(filtered_mcp, srv) -- stdio usually always supported
			end
		end

		client.request(agent_methods.session_new, {
			cwd = fn.getcwd(),
			mcpServers = filtered_mcp,
		}, function(err2, new_sess_res)
            if err2 then
                vim.notify("session/new error: " .. vim.inspect(err2), vim.log.levels.ERROR)
                return
            end

			local session = {
				agent_name = agent_name,
				session_id = new_sess_res.sessionId,
				modes = new_sess_res.modes,
				pending_permission = {},
				lastest_diff = nil,
				available_commands = {},
			}

			setmetatable(session, {
				__index = function(t, k)
					if k == "client" then
						return client
					else
						return rawget(t, k)
					end
				end,
			})

			local buf = utils.get_acpchat_buf(agent_name, session.session_id, true) --[[@as integer]]
			M.sessions[buf] = session

			-- Setup buffer and window
			api.nvim_buf_set_name(buf, ("acp://%s/%s"):format(agent_name, session.session_id))
			vim.cmd.vsplit()
			local win = api.nvim_get_current_win()
			api.nvim_win_set_buf(win, buf)

			vim.bo[buf].filetype = "acpchat"
			vim.wo[win].wrap = true
			vim.wo[win].linebreak = true

			utils.append_text(buf, "ACP session started. Agent: " .. agent_name .. "\n")
			vim.cmd("normal! G")
			vim.cmd("startinsert")
		end)
	end)
end

-- Callback for the prompt buffer
---@param bufnr number
---@param text string
function M.prompt_callback(bufnr, text)
	local session = M.sessions[bufnr]
	if not session then return end

	if vim.b[bufnr].acp_requesting_permission then
		local choice = tonumber(text)
		local pending = session.pending_permission

		if choice and pending and pending.options[choice] then
			local option = pending.options[choice]
			utils.append_text(bufnr, "\n[Permission granted: " .. option.name .. "]\n")
			pending.response({ outcome = { outcome = "selected", optionId = option.optionId } })

			-- Clear state
			session.pending_permission[bufnr] = nil
			vim.b[bufnr].acp_requesting_permission = false
		else
			utils.append_text(bufnr, "\n[Invalid choice. Please type a number from the list above]\n")
		end
		return
	end

	utils.append_text(bufnr, "\n🤖 ")
	M.send_prompt(bufnr, text)
end

-- Send a prompt to agent
---@param bufnr number
---@param text string
function M.send_prompt(bufnr, text)
	local session = M.sessions[bufnr]
	if not session or session.session_id == "" then
		vim.notify("No active ACP session in this buffer", vim.log.levels.WARN)
		return
	end

	if not text or text == "" then return end

	session.client.request(agent_methods.session_prompt, {
		sessionId = session.session_id,
		prompt = { { type = "text", text = text } },
		---@param err any
		---@param res acp.PromptResponse
	}, function(err, res)
		if err then
			utils.append_text(bufnr, "\nError: " .. vim.inspect(err) .. "\n")
		end
		if res and res.stopReason then
			local stop_reasons = {
				end_turn = "\n",
				max_tokens = "\n[Stopped: Reached maximum token limit]\n",
				max_turn_requests = "\n[Stopped: Reached maximum model requests in a single turn]\n",
				refusal = "\n[Stopped: Agent refused to respond]\n",
				user_cancel = "\n[Stopped: Operation cancelled by user]\n",
			}
			utils.append_text(bufnr, stop_reasons[res.stopReason])
		end
	end)
end

--- Change ACP mode for a buffer
---@param bufnr number
---@param mode_id string
function M.set_mode(bufnr, mode_id)
	local session = M.sessions[bufnr]
	if not session or session.session_id == "" then return end

	session.client.request(agent_methods.session_set_mode, {
		sessionId = session.session_id,
		modeId = mode_id,
	}, function(err, _res)
		if err then
			vim.notify("Failed to set ACP mode: " .. vim.inspect(err), vim.log.levels.ERROR)
		else
			if session.modes then
				session.modes.currentModeId = mode_id
			end
		end
	end)
end

-- Cancel the current operation
---@param bufnr number
function M.cancel(bufnr)
	local session = M.sessions[bufnr]
	if not session or session.session_id == "" then return end

	session.client.notify(agent_methods.session_cancel, { sessionId = session.session_id })
end

--- View diff in a new tab with split windows
---@param bufnr number
function M.view_diff(bufnr)
	local session = M.sessions[bufnr]
    if not session then return end

    local diff = session.lastest_diff

	if not diff then
		vim.notify("No diff available to view", vim.log.levels.INFO)
		return
	end

	vim.cmd("tabnew")
	vim.cmd("edit " .. fn.fnameescape(diff.path))
	local original_win = api.nvim_get_current_win()
	vim.wo[original_win].diff = true

	vim.cmd("rightbelow vsplit")
	local diff_buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_name(diff_buf, "acp-diff:/" .. diff.path)
	api.nvim_buf_set_lines(diff_buf, 0, -1, false, vim.split(diff.newText, "\n", { plain = true }))
	api.nvim_win_set_buf(0, diff_buf)
	vim.wo.diff = true

	api.nvim_set_current_win(original_win)
end

---@return string
function M.acpstart_complete()
	return iter(vim.tbl_keys(M.config.agents)):join("\n")
end

function M.acpsetmode_complete()
	local buf = api.nvim_get_current_buf()
	local session = M.sessions[buf]
	if not session or not session.modes then return "" end
	return iter(session.modes.availableModes):map(function(mode)
		return mode.id
	end):join("\n")
end

return M
