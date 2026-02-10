--- Simple JSON-RPC client for Agent Client Protocol (ACP)
--- Uses newline-delimited JSON messages over stdio

local M = {}

---@class acp.rpc.Error
---@field code integer
---@field message string

---@class acp.rpc.Client : acp.InitializeResponse
---@field request fun(method: string, params: any, callback: fun(err: acp.rpc.Error?, result: any?))
---@field notify fun(method: string, params: any)
---@field response fun(id: string, result: any?, error: acp.rpc.Error?)
---@field terminate fun()

---@class acp.rpc.Dispatchers
---@field notification? fun(method: string, params: any)
---@field server_request? fun(id: acp.RequestId, method: string, params: any, response: fun(result: any?, error: acp.rpc.Error?))
---@field on_exit? fun(code: integer, signal: integer)
---@field on_error? fun(code: integer, err: string)

M.code = {
	parse_error = -32700,
	invalid_request = -32600,
	method_not_found = -32601,
	invalid_params = -32602,
	internal_error = -32603,
}

---Start an RPC client
---@param cmd string[] Command to start the agent
---@param dispatchers acp.rpc.Dispatchers
---@param opts? { cwd?: string, env?: table<string, string> }
---@return acp.rpc.Client
function M.start(cmd, dispatchers, opts)
	opts = opts or {}
	local state = {
		buffer = "",
		next_id = 1,
		pending = {},
		closing = false,
	}

	---@type vim.SystemObj
	local system_obj

	---@param id acp.RequestId
	---@param result any
	---@param error acp.rpc.Error
	local function send_response(id, result, error)
		if state.closing then return false end

		local response = { jsonrpc = "2.0", id = id }
		if error then
			response.error = error
		else
			response.result = result or {}
		end

		system_obj:write(vim.json.encode(response) .. "\n")
		return true
	end

	-- Handle stdout data
	--- @param data string
	local function handle_data(data)
		state.buffer = state.buffer .. data

		-- Process complete lines
		while true do
			local pos = state.buffer:find("\n", 1, true)
			if not pos then break end

			local line = state.buffer:sub(1, pos - 1)
			state.buffer = state.buffer:sub(pos + 1)

			if line ~= "" then
				-- Parse JSON
				local ok, msg = pcall(vim.json.decode, line)
				if not ok then
					if dispatchers.on_error then
						dispatchers.on_error(1, "Invalid JSON: " .. line)
					end
				else
					-- Dispatch message
					if msg.method and msg.id then
						-- Request from agent (has method AND id)
						if dispatchers.server_request then
							dispatchers.server_request(msg.id, msg.method, msg.params, function(result, err)
								send_response(msg.id, result, err)
							end)
						else
							send_response(msg.id, nil, { code = -32601, message = "Method not found" })
						end

					elseif msg.method then
						-- Notification from agent (has method but NO id)
						if dispatchers.notification then
							dispatchers.notification(msg.method, msg.params)
						end
					elseif msg.id then
						-- Response to our request (has id but no method)
						local cb = state.pending[msg.id]
						if cb then
							state.pending[msg.id] = nil
							cb(msg.error, msg.result)
						end
					end
				end
			end
		end
	end

	-- Start process with vim.system
	system_obj = vim.system(cmd, {
		cwd = opts.cwd or vim.fn.getcwd(),
		env = opts.env,
		stdin = true,
		stdout = function(err, data)
			if err then
				if dispatchers.on_error then
					vim.schedule(function()
						dispatchers.on_error(2, err)
					end)
				end
				return
			end

			if not data then
				return
			end

			vim.schedule(function()
				handle_data(data)
			end)
		end,
		stderr = function(_, data)
			if data then
				vim.schedule(function()
					vim.notify("[Agent] " .. data, vim.log.levels.DEBUG)
				end)
			end
		end,
	}, function(result)
		-- on_exit callback
		vim.schedule(function()
			if dispatchers.on_exit then
				dispatchers.on_exit(result.code or 0, result.signal or 0)
			end
		end)
	end)

	-- Public API
	return {
		request = function(method, params, callback)
			if state.closing then return false end

			local id = state.next_id
			state.next_id = state.next_id + 1
			state.pending[id] = callback

			system_obj:write(vim.json.encode({
				jsonrpc = "2.0",
				id = id,
				method = method,
				params = params,
			}) .. "\n")

			return true, id
		end,

		response = send_response,

		notify = function(method, params)
			if state.closing then return false end

			system_obj:write(vim.json.encode({
				jsonrpc = "2.0",
				method = method,
				params = params,
			}) .. "\n")

			return true
		end,

		terminate = function()
			state.closing = true
			system_obj:kill(15) -- SIGTERM
		end,
	}
end

return M
