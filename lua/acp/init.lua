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
---@field window? number
---@field modes? acp.SessionModeState
---@field pending_permissions table<number, { options: acp.PermissionOption[], response: fun(result: any?, error: acp.rpc.Error?) }>
---@field lastest_diff? acp.Diff
---@field available_commands? acp.AvailableCommand[]

---@type table<number, acp.Session>
M.sessions = {}

---@type acp.Config
local default_config = {
	agents = {},
	mcp = {},
}

---@type acp.Config
M.config = vim.tbl_deep_extend("force", default_config, vim.g.acp or {})

---@param bufnr number
---@param method string
---@param params any
---@param response fun(result: any?, error: acp.rpc.Error?)
local function handle_server_request(bufnr, method, params, response)
	local session = M.sessions[bufnr]
	if not session then
		response(nil, { code = -32603, message = "Session not found" })
		return
	end

	if method == client_methods.session_request_permission then
		---@type acp.RequestPermissionRequest
		local p = params
		local title = p.toolCall.title or "Unknown tool"
		local options = p.options

		-- Store request context in the session
		session.pending_permissions[bufnr] = { options = options, response = response }
		vim.b[bufnr].acp_requesting_permission = true

		local lines = { "\n⚠️ Permission required: " .. title }
		for i, o in ipairs(options) do
			table.insert(lines, ("  %d. %s"):format(i, o.name))
		end
		table.insert(lines, "Type number to choose (or use :AcpViewDiff to review):")
		utils.append_text(bufnr, table.concat(lines, "\n") .. " ")
	elseif method == client_methods.fs_read_text_file then
		---@type acp.ReadTextFileRequest
        local p = params
        local path = p.path
        local path_valid, err = utils.valid_file_path(path)
		if not path_valid then
			response(nil, { code = rpc.code.invalid_params, message = err })
			return
		end

		local bufnr_target = fn.bufnr(p.path)

		local content
		local source = "file"

		if bufnr_target ~= -1 and api.nvim_buf_is_loaded(bufnr_target) then
			local start = (p.line or 1) - 1
			local limit = p.limit or -1
			local lines = api.nvim_buf_get_lines(bufnr_target, start, limit == -1 and -1 or start + limit, false)
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

		utils.append_text(bufnr, ("[Read %s (%d bytes) from %s]\n"):format(path, #content, source))
		response({ content = content })

	elseif method == client_methods.fs_write_text_file then
		---@type acp.WriteTextFileRequest
		local p = params
        local path = p.path
        local path_valid, err = utils.valid_file_path(path)
        if not path_valid then
            response(nil, { code = rpc.code.invalid_params, message = err })
            return
        end

		local bufnr_target = fn.bufnr(path)

		if bufnr_target ~= -1 and api.nvim_buf_is_loaded(bufnr_target) then
			local lines = vim.split(p.content, "\n", { plain = true })
			api.nvim_buf_set_lines(bufnr_target, 0, -1, false, lines)
			utils.append_text(bufnr, ("[Wrote %d bytes to buffer %s]\n"):format(#p.content, path))
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
			utils.append_text(bufnr, ("[Wrote %d bytes to %s]\n"):format(#p.content, path))
			response({})
		end
	else
		response(nil, { code = -32601, message = "Method not found: " .. method })
	end
end

---@param bufnr number
---@param _method string
---@param params any
local function handle_notification(bufnr, _method, params)
	local session = M.sessions[bufnr]
	if not session then return end

	if _method == client_methods.session_update then
		---@type acp.SessionNotification
		local p = params
		local u = p.update

        if u.sessionUpdate == "agent_message_chunk" then
            local content = u.content
            if content and content.type == "text" then
                utils.append_text(bufnr, content.text, session.window)
            end
        elseif u.sessionUpdate == "tool_call" then
            utils.append_text(bufnr, ("\n🔧 %s (%s)\n"):format(u.title, u.status or "pending"), session.window)
            for _, tc in ipairs(u.content or {}) do
                if tc.content and tc.content.type == "text" then
                    utils.append_text(bufnr, tc.content.text, session.window)
                elseif tc.newText then -- Diff
                    session.lastest_diff = tc --[[@as acp.Diff ]]
                    local old = tc.oldText or ""
                    local diff = vim.text.diff(old, tc.newText, { result_type = "unified" })
                    if diff ~= "" then
                        utils.append_text(bufnr, ("\n```diff\n--- %s\n+++ %s\n%s\n```\n"):format(tc.path, tc.path, diff),
                            session.window)
                    end
                end
            end
        elseif u.sessionUpdate == "tool_call_update" then
            local has_title = u.title ~= nil
            local has_status = u.status ~= nil
            local has_content = u.content and #u.content > 0

            if has_title and has_status then
                utils.append_text(bufnr, ("\n🔧 %s (%s)\n"):format(u.title, u.status), session.window)
            elseif has_title then
                utils.append_text(bufnr, ("\n🔧 %s\n"):format(u.title), session.window)
            elseif has_status and has_content then
                utils.append_text(bufnr, ("\n🔧 %s\n"):format(u.status), session.window)
            end

            for _, tc in ipairs(u.content or {}) do
                if tc.content and tc.content.type == "text" then
                    utils.append_text(bufnr, tc.content.text, session.window)
                elseif tc.newText then -- Diff
                    session.lastest_diff = tc
                    local old = tc.oldText or ""
                    local diff = vim.text.diff(old, tc.newText, { result_type = "unified" })
                    if diff ~= "" then
						utils.append_text(bufnr,
							("\nTo see this diff in a split view, run `:AcpViewDiff`\n```diff\n--- %s\n+++ %s\n%s\n```\n")
							:format(tc.path, tc.path, diff),
                            session.window)
                    end
                end
            end
        elseif u.sessionUpdate == "plan" then
            utils.append_text(bufnr, "[Plan update]\n", session.window)
        elseif u.sessionUpdate == "agent_thought_chunk" then
            local content = u.content
            if content and content.type == "text" then
                utils.append_text(bufnr, ("[Thought] %s\n"):format(content.text), session.window)
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
---@param bufnr number
local function start_agent(agent_name, bufnr)
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
			M.sessions[bufnr] = nil
		end,
		notification = function(_method, params)
			handle_notification(bufnr, _method, params)
		end,
		server_request = function(_id, method, params, response)
			handle_server_request(bufnr, method, params, response)
		end,
	}, { env = env })

	return rpc_client
end

--- Start the ACP connection for a buffer
---@param agent_name string
function M.new_session(agent_name)
	local bufnr = api.nvim_create_buf(false, true)
	local client = start_agent(agent_name, bufnr)
	if not client then return end

	M.sessions[bufnr] = {
		agent_name = agent_name,
		client = client,
		session_id = "",
		auto_approve = false,
		pending_permissions = {},
		lastest_diff = nil,
		available_commands = {},
	}

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

			local session = M.sessions[bufnr]
			session.session_id = new_sess_res.sessionId
			session.modes = new_sess_res.modes

			-- Setup buffer and window
			api.nvim_buf_set_name(bufnr, ("acp://%s/%s"):format(agent_name, session.session_id))
			vim.cmd("vsplit")
			local win = api.nvim_get_current_win()
			api.nvim_win_set_buf(win, bufnr)
			session.window = win

			vim.bo[bufnr].filetype = "acpchat"
			vim.wo[win].wrap = true
			vim.wo[win].linebreak = true

			utils.append_text(bufnr, "ACP session started. Agent: " .. agent_name .. "\n")
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
		local pending = session.pending_permissions[bufnr]

		if choice and pending and pending.options[choice] then
			local option = pending.options[choice]
			utils.append_text(bufnr, "\n[Permission granted: " .. option.name .. "]\n")
			pending.response({ outcome = { outcome = "selected", optionId = option.optionId } })

			-- Clear state
			session.pending_permissions[bufnr] = nil
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
	}, function(err, _res)
		if err then
			utils.append_text(bufnr, "\nError: " .. vim.inspect(err) .. "\n")
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
	utils.append_text(bufnr, "Cancelled.\n")
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
