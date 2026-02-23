---MCP Server implementation for Neovim
---Provides tools and prompts capabilities to MCP clients

local json_rpc = require("acp.json_rpc")

local M = {}

---@class acp.mcp.ToolHandler
---@field name string
---@field description string
---@field inputSchema table
---@field handler fun(arguments: table<string, any>, send: fun(result: acp.mcp.CallToolResult))

---@class acp.mcp.PromptHandler
---@field name string
---@field description string
---@field arguments {name: string, description: string, required?: boolean}[]
---@field handler fun(arguments: table<string, any>, send: fun(result: acp.mcp.GetPromptResult))

---@class acp.mcp.Server
---@field name string
---@field version string
---@field capabilities acp.mcp.ServerCapabilities
---@field instructions string?
---@field tools acp.mcp.ToolHandler[]
---@field prompts acp.mcp.PromptHandler[]
---@field initialized boolean
---@field protocolVersion string
local Server = {}
Server.__index = Server
M.Server = Server

---@class acp.mcp.ServerOpts
---@field name string
---@field version string
---@field capabilities? acp.mcp.ServerCapabilities
---@field instructions? string

local SUPPORTED_PROTOCOL_VERSION = "2025-11-25"

---@param opts acp.mcp.ServerOpts
---@return acp.mcp.Server
function Server.new(opts)
	local self = setmetatable({}, Server)
	self.name = opts.name
	self.version = opts.version
	self.capabilities = opts.capabilities
		or {
			tools = { listChanged = true },
			prompts = { listChanged = true },
			resources = { listChanged = true, subscribe = false },
		}
	self.instructions = opts.instructions
	self.tools = {}
	self.prompts = {}
	self.initialized = false
	self.protocolVersion = SUPPORTED_PROTOCOL_VERSION
	return self
end

function Server:add_tool(tool)
	table.insert(self.tools, tool)
end

function Server:add_prompt(prompt)
	table.insert(self.prompts, prompt)
end

---@param name string
---@param description string
---@param properties table
---@param handler fun(arguments: table<string, any>, send: fun(result: acp.mcp.CallToolResult))
---@param required? string[]
function Server:tool(name, description, properties, handler, required)
	self:add_tool({
		name = name,
		description = description,
		inputSchema = {
			type = "object",
			properties = properties,
			required = required or {},
		},
		handler = handler,
	})
end

---@param name string
---@param description string
---@param arguments {name: string, description: string, required?: boolean}[]
---@param handler fun(arguments: table<string, any>, send: fun(result: acp.mcp.GetPromptResult))
function Server:prompt(name, description, arguments, handler)
	self:add_prompt({
		name = name,
		description = description,
		arguments = arguments,
		handler = handler,
	})
end

---@param id number|string
---@param params table
---@param send fun(response: string)
function Server:handle_initialize(id, params, send)
	self.initialized = true
	local result = {
		protocolVersion = self.protocolVersion,
		capabilities = self.capabilities,
		serverInfo = { name = self.name, version = self.version },
	}
	if self.instructions then
		result.instructions = self.instructions
	end
	send(json_rpc.encode_response(id, result))
end

---@param id number|string
---@param send fun(response: string)
function Server:handle_list_tools(id, send)
	local tools = {}
	for _, tool in ipairs(self.tools) do
		table.insert(tools, {
			name = tool.name,
			description = tool.description,
			inputSchema = tool.inputSchema,
		})
	end
	send(json_rpc.encode_response(id, { tools = tools }))
end

---@param id number|string
---@param params { name: string, arguments?: table<string, any> }
---@param send fun(response: string)
function Server:handle_call_tool(id, params, send)
	for _, tool in ipairs(self.tools) do
		if tool.name == params.name then
			local ok, err = pcall(tool.handler, params.arguments or {}, function(result)
				send(json_rpc.encode_response(id, result))
			end)
			if not ok then
				send(json_rpc.encode_response(id, {
					content = { { type = "text", text = "Error: " .. tostring(err) } },
					isError = true,
				}))
			end
			return
		end
	end
	send(json_rpc.encode_response(id, {
		content = { { type = "text", text = "Unknown tool: " .. params.name } },
		isError = true,
	}))
end

---@param id number|string
---@param send fun(response: string)
function Server:handle_list_prompts(id, send)
	local prompts = {}
	for _, prompt in ipairs(self.prompts) do
		table.insert(prompts, {
			name = prompt.name,
			description = prompt.description,
			arguments = prompt.arguments,
		})
	end
	send(json_rpc.encode_response(id, { prompts = prompts }))
end

---@param id number|string
---@param params { name: string, arguments?: table<string, any> }
---@param send fun(response: string)
function Server:handle_get_prompt(id, params, send)
	for _, prompt in ipairs(self.prompts) do
		if prompt.name == params.name then
			local ok, err = pcall(prompt.handler, params.arguments or {}, function(result)
				send(json_rpc.encode_response(id, result))
			end)
			if not ok then
				send(json_rpc.encode_response(id, {
					messages = {
						{
							role = "user",
							content = { type = "text", text = "Error: " .. tostring(err) },
						},
					},
				}))
			end
			return
		end
	end
	send(json_rpc.encode_response(id, {
		messages = {
			{
				role = "user",
				content = { type = "text", text = "Unknown prompt: " .. params.name },
			},
		},
	}))
end

---@param msg { method: string, params?: any, id: number|string }
---@param send fun(response: string)
function Server:handle_request(msg, send)
	local method = msg.method
	local id = msg.id

	if not self.initialized and method ~= "initialize" and method ~= "ping" then
		send(json_rpc.encode_error(id, json_rpc.code.server_error, "Server not initialized"))
		return
	end

	if method == "initialize" then
		self:handle_initialize(id, msg.params or {}, send)
	elseif method == "ping" then
		send(json_rpc.encode_response(id, vim.empty_dict()))
	elseif method == "tools/list" then
		self:handle_list_tools(id, send)
	elseif method == "tools/call" then
		self:handle_call_tool(id, msg.params or {}, send)
	elseif method == "prompts/list" then
		self:handle_list_prompts(id, send)
	elseif method == "prompts/get" then
		self:handle_get_prompt(id, msg.params or {}, send)
	else
		send(json_rpc.encode_error(id, json_rpc.code.method_not_found, "Method not found: " .. method))
	end
end

---@param msg { method: string, params?: any }
function Server:handle_notification(msg)
	if msg.method == "notifications/initialized" then
		-- Initialized confirmed
	else
		io.stderr:write("[mcp] Unhandled notification: " .. tostring(msg.method) .. "\n")
	end
end

---@param msg any
---@param send fun(response: string)
function Server:process_message(msg, send)
	if msg.method and msg.id ~= nil then
		self:handle_request(msg, send)
	elseif msg.method then
		self:handle_notification(msg)
	elseif msg.id ~= nil then
		io.stderr:write("[mcp] Received unexpected response with id: " .. tostring(msg.id) .. "\n")
	else
		io.stderr:write("[mcp] Received malformed message\n")
	end
end

function Server:start()
	local server = self

	-- Sử dụng io.write + io.flush để đảm bảo phản hồi đi ngay lập tức và không bị đệm
	local function send(response)
		io.write(response)
		io.flush()
	end

	-- Vòng lặp đọc đồng bộ trong main thread.
	-- Tránh hoàn toàn fast event loop và cho phép dùng vim.rpcrequest (blocking) an toàn.
	while true do
		local line = io.read("*l")
		if not line then
			break -- EOF: Client ngắt kết nối
		end

		if line ~= "" then
			-- Loại bỏ \r nếu có
			line = line:gsub("\r$", "")
			local parsed = json_rpc.parse_message(line)

			if parsed.ok then
				local ok, err = pcall(server.process_message, server, parsed.data, send)
				if not ok then
					io.stderr:write("[mcp] Error processing message: " .. tostring(err) .. "\n")
				end
			else
				io.stderr:write("[mcp] JSON Parse error: " .. tostring(parsed.err) .. " in line: " .. line .. "\n")
			end
		end
	end
end

return M
