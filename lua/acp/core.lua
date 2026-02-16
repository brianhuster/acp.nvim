local M = {}
local vim = vim
local api, fn, iter = vim.api, vim.fn, vim.iter
local utils = require("acp.utils")
local meta = require("acp.meta")
local rpc = require("acp.rpc")

local agent_methods = meta.agentMethods
local client_methods = meta.clientMethods

---@class acp.SessionTerminal : acp.TerminalOutputResponse
---@field id string
---@field instance vim.SystemObj
---@field outputByteLimit integer
---@field on_exit fun(exitStatus: acp.TerminalExitStatus)

---@class acp.Session : acp.NewSessionResponse
---@field agent_name string
---@field client acp.rpc.Client
---@field pending_permission { options: acp.PermissionOption[], response: fun(result: any?, error: acp.rpc.Error?) }>
---@field lastest_diff? acp.Diff
---@field available_commands? acp.AvailableCommand[]
---@field pending_attachments acp.ContentBlock[]
---@field terminals table<string, acp.SessionTerminal>

---@type table<number, acp.Session>
M.sessions = {}

---@type table<string, acp.rpc.Client>
M.agents = {}

---@type acp.Config
M.config = require("acp.config").config

local handlers = {
	---@param p acp.RequestPermissionRequest
	---@param response fun(result: acp.RequestPermissionResponse?, error: acp.rpc.Error?)
	[client_methods.session_request_permission] = function(buf, p, response)
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
		table.insert(lines, "Type number to choose:")
		utils.add_output(buf, table.concat(lines, "\n") .. " ")
	end,

	---@param p acp.ReadTextFileRequest
	---@param response fun(result: acp.ReadTextFileResponse?, error: acp.rpc.Error?)
	[client_methods.fs_read_text_file] = function(buf, p, response)
		local path = p.path
		local path_valid, err = utils.valid_file_path(path)
		if not path_valid then
			response(nil, { code = rpc.code.invalid_params, message = err })
			return
		end

		local content = utils.read_file(p.path, p)

		if not content then
			response(nil, { code = -32603, message = "Could not read file: " .. path })
			return
		end

		utils.add_output(buf, ("[Read %s (%d bytes)]\n"):format(path, #content))
		response({ content = content })
	end,

	---@param p acp.WriteTextFileRequest
	---@param response fun(result: acp.WriteTextFileResponse?, error: acp.rpc.Error?)
	[client_methods.fs_write_text_file] = function(buf, p, response)
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
			utils.add_output(buf, ("[Wrote %d bytes to buffer %s]\n"):format(#p.content, path))
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
			utils.add_output(buf, ("[Wrote %d bytes to %s]\n"):format(#p.content, path))
			response({})
		end
	end,

	---@param p acp.CreateTerminalRequest
	---@param response fun(result: acp.CreateTerminalResponse?, error: acp.rpc.Error?)
	[client_methods.terminal_create] = function(buf, p, response)
		local cmd = p.args or {}
		table.insert(cmd, 1, p.command)
		local term_id = utils.random_string()
		if M.sessions[buf].terminals[term_id] then
			term_id = utils.random_string()
		end
		local terminal = {
			id = term_id,
			output = "",
			outputByteLimit = p.outputByteLimit or 10000,
		}
		M.sessions[buf].terminals[term_id] = terminal

		local instance = vim.system(cmd, {
			text = true,
			env = p.env and utils.envVariables2ConfigEnv(p.env) or nil,
			stdout = function(err, data)
				if data then
					terminal.output = terminal.output .. data
				end
				if p.outputByteLimit then
					terminal.output = terminal.output:sub(-p.outputByteLimit)
					terminal.truncated = true
				end
			end,
		}, function(exit)
			terminal.exitStatus = {
				code = exit.code,
				signal = utils.get_signal_name(exit.signal),
			}
			if terminal.on_exit then
				terminal.on_exit(terminal.exitStatus)
			end
		end)

		terminal.instance = instance

		response({ terminalId = term_id })
	end,

	---@param p acp.TerminalOutputRequest
	---@param response fun(result: acp.TerminalOutputResponse?, error: acp.rpc.Error?)
	[client_methods.terminal_output] = function(buf, p, response)
		local terminal = M.sessions[buf].terminals[p.terminalId]
		if terminal then
			response({
				output = terminal.output,
				truncated = terminal.truncated,
				exitStatus = terminal.exitStatus,
			})
		else
			response(nil, { code = -32601, message = "Terminal not found: " .. p.terminalId })
		end
	end,

	---@param p acp.WaitForTerminalExitRequest
	---@param response fun(result: acp.TerminalExitStatus?, error: acp.rpc.Error?)
	[client_methods.terminal_wait_for_exit] = function(buf, p, response)
		local terminal = M.sessions[buf].terminals[p.terminalId]
		terminal.on_exit = function()
			response(terminal.exitStatus)
		end
	end,

	---@param p acp.KillTerminalCommandRequest
	---@param response fun(result: {}, error: acp.rpc.Error?)
	[client_methods.terminal_kill] = function(buf, p, response)
		local terminal = M.sessions[buf].terminals[p.terminalId]
		if terminal then
			if not terminal.instance:is_closing() then
				terminal.instance:kill("sigterm")
			end
			M.sessions[buf].terminals[p.terminalId] = nil
			response({})
		else
			response(nil, { code = -32601, message = "Terminal not found: " .. p.terminalId })
		end
	end,

	---@param p acp.ReleaseTerminalRequest
	---@param response fun(result: {}, error: acp.rpc.Error?)
	[client_methods.terminal_release] = function(buf, p, response)
		local terminal = M.sessions[buf].terminals[p.terminalId]
		if terminal then
			if not terminal.instance:is_closing() then
				terminal.instance:kill("sigterm")
			end
			M.sessions[buf].terminals[p.terminalId] = nil
			response({})
		else
			response(nil, { code = -32601, message = "Terminal not found: " .. p.terminalId })
		end
	end,

	[client_methods.session_update] = function(buf, params)
		local p = params
		local u = p.update

		local session = M.sessions[buf]

		if u.sessionUpdate == "agent_message_chunk" then
			local content = u.content
			if content and content.type == "text" then
				utils.add_output(buf, content.text)
			end
		elseif u.sessionUpdate == "user_message_chunk" then
			local content = u.content
			if content and content.type == "text" then
				utils.add_output(buf, "\n\n" .. vim.fn.prompt_getprompt(buf) .. content.text .. "\n\n")
			end
		elseif u.sessionUpdate == "tool_call" then
			utils.add_output(buf, ("\n🔧 %s (%s)\n"):format(u.title, u.status or "pending"))
			for _, tc in ipairs(u.content or {}) do
				if tc.content and tc.content.type == "text" then
					utils.add_output(buf, tc.content.text)
				elseif tc.newText then -- Diff
					session.lastest_diff = tc --[[@as acp.Diff ]]
					local old = tc.oldText or ""
					local diff = vim.text.diff(old, tc.newText, { result_type = "unified" })
					if diff ~= "" then
						utils.add_output(buf, ("\n```diff\n--- %s\n+++ %s\n%s\n```\n"):format(tc.path, tc.path, diff))
					end
				end
			end
		elseif u.sessionUpdate == "tool_call_update" then
			local has_title = u.title ~= nil
			local has_status = u.status ~= nil
			local has_content = u.content and #u.content > 0

			if has_title and has_status then
				utils.add_output(buf, ("\n🔧 %s (%s)\n"):format(u.title, u.status))
			elseif has_title then
				utils.add_output(buf, ("\n🔧 %s\n"):format(u.title))
			elseif has_status and has_content then
				utils.add_output(buf, ("\n🔧 %s\n"):format(u.status))
			end

			for _, tc in ipairs(u.content or {}) do
				if tc.content and tc.content.type == "text" then
					utils.add_output(buf, tc.content.text)
				elseif tc.newText then -- Diff
					session.lastest_diff = tc --[[@as acp.Diff ]]
					local old = tc.oldText or ""
					local diff = vim.text.diff(old, tc.newText, { result_type = "unified" })
					if diff ~= "" then
						utils.add_output(
							buf,
							("\nTo see this diff in a split view, run `:Acp view-diff`\n```diff\n--- %s\n+++ %s\n%s\n```\n"):format(
								tc.path,
								tc.path,
								diff
							)
						)
					end
				end
			end
		elseif u.sessionUpdate == "plan" then
			utils.add_output(buf, "[Plan updated]\n")
			local entries = u.entries
			---@param e acp.PlanEntry
			local lines = vim.tbl_map(function(e)
				local status_icons = {
					pending = "⏳",
					in_progress = "🔄",
					completed = "✅",
				}
				local icon = status_icons[e.status]
				return string.format("%s [%s] %s", icon, e.priority:upper(), e.content)
			end, entries)

			utils.add_output(buf, table.concat(lines, "\n") .. "\n")

			local plan_buf = utils.get_acp_buf(session.agent_name, p.sessionId, "plan", true) --[[@as integer]]
			api.nvim_buf_set_lines(plan_buf, 0, -1, false, lines)
		elseif u.sessionUpdate == "agent_thought_chunk" then
			local content = u.content
			if content and content.type == "text" then
				utils.add_output(buf, ("[Thought] %s\n"):format(content.text))
			end
		elseif u.sessionUpdate == "current_mode_update" then
			if session.modes and u.currentModeId then
				session.modes.currentModeId = u.currentModeId
			end
		elseif u.sessionUpdate == "available_commands_update" then
			session.available_commands = u.availableCommands
		end
	end,
}

---@param agent string
---@param method string
---@param params acp.RequestPermissionRequest|acp.ReadTextFileRequest|acp.WriteTextFileRequest
---@param response fun(result: any?, error: acp.rpc.Error?)
local function handle_server_request(agent, method, params, response)
	local buf = utils.get_acp_buf(agent, params.sessionId, "chat")

	if not buf then
		response(nil, { code = rpc.code.internal_error, message = "Session buffer not found for agent: " .. agent })
		return
	end

	if handlers[method] then
		handlers[method](buf, params, response)
	else
		response(nil, { code = rpc.code.method_not_found, message = "Method not found: " .. method })
	end
end

---@param agent string
---@param method string
---@param params any
local function handle_notification(agent, method, params)
	local buf = utils.get_acp_buf(agent, params.sessionId, "chat")
	if not buf then
		return
	end
	if handlers[method] then
		handlers[method](buf, params)
	end
end

---@param agent_name string
---@param callback fun(client: acp.rpc.Client)
local function start_agent(agent_name, callback)
	if M.agents[agent_name] then
		callback(M.agents[agent_name])
	end

	local agent_config = M.config.agents[agent_name]
	if not agent_config then
		vim.notify("No configuration found for agent: " .. agent_name, vim.log.levels.ERROR)
		return nil
	end

	local cmd = agent_config.cmd
	local env = agent_config.env or {}

	local client = require("acp.rpc").start(cmd, {
		on_error = function(code, err)
			vim.notify(("Agent '%s' error (%d): %s"):format(agent_name, code, err), vim.log.levels.ERROR)
		end,
		on_exit = function(code, _)
			vim.notify(("Agent '%s' exited with code %d"):format(agent_name, code), vim.log.levels.INFO)
			for buf, session in pairs(M.sessions) do
				if session.agent_name == agent_name then
					utils.add_output(buf, ("\n[Agent '%s' has exited]\n"):format(agent_name))
					M.agents[agent_name] = nil
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

	client.request(agent_methods.initialize, {
		protocolVersion = meta.version,
		clientCapabilities = {
			fs = { readTextFile = true, writeTextFile = true },
			terminal = true,
		},
		clientInfo = {
			name = "acp.nvim",
			version = "0.1.0",
			title = "ACP client for Neovim",
		},
		---@param err any
		---@param init_res acp.InitializeResponse
	}, function(err, init_res)
		if err then
			vim.notify("Initialize error: " .. vim.inspect(err), vim.log.levels.ERROR)
			return
		end
		client = vim.tbl_deep_extend("error", client, init_res)
		M.agents[agent_name] = client
		callback(client)
	end)
end

--- Create a new session or load existing one for an agent
---@param agent_name? string  if nil, will use default agent from config
---@param session_id? string  omit if creating new session
function M.create_or_load_session(agent_name, session_id)
	if not agent_name or agent_name == "" then
		agent_name = M.config.default_agent
		if not agent_name then
			vim.notify("No agent specified and no default agent configured", vim.log.levels.ERROR)
			return
		end
	end
	local buf
	local session = {
		agent_name = agent_name,
		sessionId = session_id,
		pending_permission = {},
		pending_attachments = {},
		lastest_diff = nil,
		available_commands = {},
		terminals = {},
	}

	local function setup_chatbuf()
		buf = utils.get_acp_buf(agent_name, session.sessionId, "chat", true) --[[@as integer]]
		M.sessions[buf] = session

		local found_win = false
		for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
			if api.nvim_win_get_buf(win) == buf then
				api.nvim_set_current_win(win)
				found_win = true
			end
		end

		if not found_win then
			vim.cmd.vsplit()
			local win = api.nvim_get_current_win()
			api.nvim_win_set_buf(win, buf)
		end
		vim.bo[buf].filetype = "acpchat"
		print(buf)
	end

	start_agent(agent_name, function(client)
		if session_id then
			if not client.agentCapabilities.loadSession then
				vim.notify(
					("Agent '%s' does not support loading existing sessions"):format(agent_name),
					vim.log.levels.ERROR
				)
				return
			end
			setup_chatbuf()
		end

		local mcp = {}
		if M.config.agents[agent_name].mcp then
			local mcp_names = M.config.agents[agent_name].mcp
			if vim.islist(mcp_names) then
				local mcp_config = {}
				for _, name in
					ipairs(mcp_names --[[@as string[] ]])
				do
					mcp_config[name] = M.config.mcp[name]
				end
				mcp = utils.configMcp2McpServer(mcp_config)
			elseif mcp_names == true then
				mcp = utils.configMcp2McpServer(M.config.mcp)
			end
		end

		-- Filter MCP servers based on agent capabilities
		local agent_caps = client.agentCapabilities or {}
		local mcp_caps = agent_caps.mcpCapabilities or {}
		local filtered_mcp = {}
		for _, srv in ipairs(mcp) do
			if srv.type == "stdio" or mcp_caps[srv.type] then
				table.insert(filtered_mcp, srv)
			end
		end

		local method = session_id and agent_methods.session_load or agent_methods.session_new

		client.request(method, {
			sessionId = session_id,
			cwd = fn.getcwd(),
			mcpServers = filtered_mcp,
			---@param err2 any
			---@param new_sess_res acp.NewSessionResponse|acp.LoadSessionResponse
		}, function(err2, new_sess_res)
			if err2 then
				vim.notify(method .. " error: " .. vim.inspect(err2), vim.log.levels.ERROR)
				return
			end

			session = vim.tbl_deep_extend("error", session, new_sess_res)

			--- Don't save client directly in M.sessions to avoid polluting
			--- checkhealth, etc
			setmetatable(session, {
				__index = function(t, k)
					if k == "client" then
						return client
					else
						return rawget(t, k)
					end
				end,
			})

			setup_chatbuf()

			vim.cmd("normal! G")
			vim.cmd("startinsert")
		end)
	end)
end

---@param path string
---@return acp.ContentBlock_5?
local function get_resource(path)
	local buf = api.nvim_get_current_buf()
	local session = M.sessions[buf]
	if not session then
		return
	end

	local client = session.client
	if not vim.tbl_get(client, "agentCapabilities", "promptCapabilities", "embeddedContext") then
		return {
			type = "resource_link",
			uri = utils.uri_from_fname(path),
			name = vim.fs.basename(path),
		}
	end

	local result = {
		type = "resource",
		resource = {
			uri = utils.uri_from_fname(path),
		},
	}

	local content = utils.read_file(path)

	if not content then
		vim.notify("Could not read file: " .. path, vim.log.levels.ERROR)
		return {
			type = "resource_link",
			uri = utils.uri_from_fname(path),
			name = vim.fs.basename(path),
		}
	end
	local is_binary = content:find("\0") ~= nil
	if is_binary then
		result.resource.blob = vim.base64.encode(content)
	else
		result.resource.text = content
	end

	result.resource.mimeType = require("acp.utils").get_mimetype(content)
	return result
end

-- Callback for the prompt buffer
---@param bufnr number
---@param text string
function M.prompt_callback(bufnr, text)
	local session = M.sessions[bufnr]
	if not session then
		return
	end

	if vim.b[bufnr].acp_requesting_permission then
		local choice = tonumber(text)
		local pending = session.pending_permission

		if choice and pending and pending.options[choice] then
			local option = pending.options[choice]
			utils.add_output(bufnr, "\n[Permission granted: " .. option.name .. "]\n")
			pending.response({ outcome = { outcome = "selected", optionId = option.optionId } })

			-- Clear state
			session.pending_permission[bufnr] = nil
			vim.b[bufnr].acp_requesting_permission = false
		else
			utils.add_output(bufnr, "\n[Invalid choice. Please type a number from the list above]\n")
		end
		return
	end

	utils.add_output(bufnr, "\n\n🤖 ")
	M.send_prompt(bufnr, text)
end

-- Send a prompt to agent
---@param bufnr number
---@param text string
function M.send_prompt(bufnr, text)
	local session = M.sessions[bufnr]
	if not session or session.sessionId == "" then
		vim.notify("No active ACP session in this buffer", vim.log.levels.WARN)
		return
	end

	local agent, session_id = session.agent_name, session.sessionId

	---@type acp.ContentBlock[]
	local prompt = {}
	if text ~= "" then
		prompt = { { type = "text", text = text } }
	end
	prompt = vim.list_extend(prompt, session.pending_attachments or {})
	session.pending_attachments = {}

	local resources_buf = utils.get_acp_buf(agent, session_id, "resources")
	if resources_buf then
		local lines = api.nvim_buf_get_lines(resources_buf, 0, -1, false)
		lines = iter(lines)
			:map(vim.trim)
			:filter(function(line)
				return line ~= ""
			end)
			:totable()
		lines = vim.list.unique(lines)
		for _, line in ipairs(lines) do
			local res = get_resource(line)
			if res then
				table.insert(prompt, res)
			end
		end

		-- Reset resources
		api.nvim_buf_set_lines(resources_buf, 0, -1, false, {})
	end
	if #prompt == 0 then
		return
	end

	session.client.request(agent_methods.session_prompt, {
		sessionId = session.sessionId,
		prompt = prompt,
		---@param err any
		---@param res acp.PromptResponse
	}, function(err, res)
		if err then
			utils.add_output(bufnr, "\nError: " .. vim.inspect(err) .. "\n")
		end
		if res and res.stopReason then
			local stop_reasons = {
				end_turn = "\n",
				max_tokens = "\n[Stopped: Reached maximum token limit]\n",
				max_turn_requests = "\n[Stopped: Reached maximum model requests in a single turn]\n",
				refusal = "\n[Stopped: Agent refused to respond]\n",
				user_cancel = "\n[Stopped: Operation cancelled by user]\n",
			}
			utils.add_output(bufnr, stop_reasons[res.stopReason])
		end
	end)
end

--- Change ACP mode for a buffer
---@param mode_id string
local function set_mode(mode_id)
	local buf = api.nvim_get_current_buf()
	local session = M.sessions[buf]
	if not session or session.sessionId == "" then
		return
	end

	session.client.request(agent_methods.session_set_mode, {
		sessionId = session.sessionId,
		modeId = mode_id,
	}, function(err, _)
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
	if not session or session.sessionId == "" then
		return
	end

	session.client.notify(agent_methods.session_cancel, { sessionId = session.sessionId })
end

--- View diff in a new tab with split windows
local function view_diff()
	local bufnr = api.nvim_get_current_buf()
	local session = M.sessions[bufnr]
	if not session then
		return
	end

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
end

---@class acp.SubCmd
---@field complete? fun(arg_lead: string): string
---@field callback fun(args: string)
---@field condition? fun(): boolean
M.ex_subcmd = {
	["new-session"] = {
		complete = function()
			return iter(vim.tbl_keys(M.config.agents)):join("\n")
		end,
		callback = M.create_or_load_session,
	},
	["set-mode"] = {
		complete = function()
			local buf = api.nvim_get_current_buf()
			local availableModes = vim.tbl_get(M.sessions, buf, "modes", "availableModes")
			if not availableModes then
				return ""
			end
			return iter(availableModes):map(function(mode)
				return mode.id
			end):join("\n")
		end,
		callback = set_mode,
		condition = function()
			local buf = api.nvim_get_current_buf()
			return not not vim.tbl_get(M.sessions, buf, "modes", "availableModes")
		end,
		nargs = 1,
	},
	["view-diff"] = {
		callback = view_diff,
		condition = function()
			local buf = api.nvim_get_current_buf()
			return not not vim.tbl_get(M.sessions, buf, "lastest_diff")
		end,
	},
	["resources"] = {
		callback = function()
			local buf = api.nvim_get_current_buf()
			local session = M.sessions[buf]
			if not session then
				return
			end
			local resource_cap =
				vim.tbl_get(session, "client", "agentCapabilities", "promptCapabilities", "embeddedContext")
			if not resource_cap then
				vim.notify(
					("Agent %s does not support embedded context in prompts"):format(session.agent_name),
					vim.log.levels.ERROR
				)
				return
			end
			local resources_buf = utils.get_acp_buf(session.agent_name, session.sessionId, "resources", true) --[[@as integer]]
			utils.open_win(
				resources_buf,
				true,
				{ title = ("Resources for ACP agent %s, session %s"):format(session.agent_name, session.sessionId) }
			)
		end,
		condition = function()
			local buf = api.nvim_get_current_buf()
			return not not vim.tbl_get(
				M.sessions,
				buf,
				"client",
				"agentCapabilities",
				"promptCapabilities",
				"embeddedContext"
			)
		end,
	},
	["view-plan"] = {
		callback = function()
			local buf = api.nvim_get_current_buf()
			local session = M.sessions[buf]
			if not session then
				return
			end

			local plan_buf = utils.get_acp_buf(session.agent_name, session.sessionId, "plan", true) --[[@as integer]]
			utils.open_win(plan_buf, true, {
				title = ("Plan for ACP agent %s, session %s"):format(session.agent_name, session.sessionId),
			})
		end,
		condition = function()
			return vim.bo.filetype == "acpchat"
		end,
	},
}

setmetatable(M.ex_subcmd, {
	__index = function(_, k)
		return require("acp").subcommands[k]
	end,
})

---@param arg_lead string
---@param cmd_line string
---@param cursor_pos integer
---@return string
function M.ex_complete(arg_lead, cmd_line, cursor_pos)
	local cmd = api.nvim_parse_cmd(cmd_line:sub(1, cursor_pos), {})
	local args = cmd.args or {}
	local result = ""
	if #args == 0 or (#args == 1 and arg_lead ~= "") then
		result = iter(vim.tbl_keys(M.ex_subcmd)):filter(function(sub)
			return M.ex_subcmd[sub].condition == nil or M.ex_subcmd[sub].condition()
		end):join("\n")
	elseif #args == 1 or (#args == 2 and arg_lead ~= "") then
		local subcmd = args[1]
		if M.ex_subcmd[subcmd] and M.ex_subcmd[subcmd].complete then
			result = M.ex_subcmd[subcmd].complete(arg_lead)
		end
	end
	return vim.fn.escape(result, [[ \]])
end

---@param fargs string[]
function M.ex(fargs)
	local subcmd = fargs[1]
	local arg = fargs[2]
	if M.ex_subcmd[subcmd] and M.ex_subcmd[subcmd].callback then
		if not arg and M.ex_subcmd[subcmd].nargs == 1 then
			vim.notify("Argument required for subcommand " .. subcmd, vim.log.levels.ERROR)
			return
		end
		M.ex_subcmd[subcmd].callback(arg)
	else
		vim.notify("Unknown subcommand: " .. subcmd, vim.log.levels.ERROR)
	end
end

return M
