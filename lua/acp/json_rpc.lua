---Shared JSON-RPC utilities for ACP and MCP implementations
---Provides base functionality for parsing and handling JSON-RPC messages

local M = {}

M.code = {
	parse_error = -32700,
	invalid_request = -32600,
	method_not_found = -32601,
	invalid_params = -32602,
	internal_error = -32603,
	server_error = -32000,
	server_not_initialized = -32002,
}

M.BufferParser = {}

---Parse a JSON-RPC message
---@param line string
---@return {ok: boolean, data?: any, err?: string}
function M.parse_message(line)
	if line == "" then
		return { ok = false, err = "empty line" }
	end

	local ok, msg = pcall(vim.json.decode, line)
	if not ok then
		return { ok = false, err = "Invalid JSON: " .. line }
	end

	return { ok = true, data = msg }
end

---Encode a JSON-RPC message
---@param msg any
---@return string
function M.encode_message(msg)
	return vim.json.encode(msg) .. "\n"
end

---Create a JSON-RPC request message
---@param method string
---@param params any
---@param id? number|string
---@return string
function M.encode_request(method, params, id)
	local msg = {
		jsonrpc = "2.0",
		method = method,
		params = params or vim.empty_dict(),
	}
	if id ~= nil then
		msg.id = id
	end
	return M.encode_message(msg)
end

---Create a JSON-RPC response message
---@param id number|string|nil|acp.RequestId
---@param result? any
---@param error? {code: integer, message: string, data?: any}
---@return string
function M.encode_response(id, result, error)
	local msg = {
		jsonrpc = "2.0",
		id = id,
	}
	if error then
		msg.error = error
	else
		-- MCP yêu cầu result thường phải là object {}
		msg.result = result or vim.empty_dict()
	end
	return M.encode_message(msg)
end

---Create a JSON-RPC notification message
---@param method string
---@param params any
---@return string
function M.encode_notification(method, params)
	local msg = {
		jsonrpc = "2.0",
		method = method,
		params = params or vim.empty_dict(),
	}
	return M.encode_message(msg)
end

---Create an error response
---@param id number|string|nil
---@param code integer
---@param message string
---@param data? any
---@return string
function M.encode_error(id, code, message, data)
	return M.encode_response(id, nil, {
		code = code,
		message = message,
		data = data,
	})
end

---Buffer-based message parser
---@class acp.json_rpc.BufferParser
---@field buffer string
---@field on_message fun(msg: any)

---Create a new buffer parser
---@param on_message fun(msg: any) Callback for complete messages
---@return acp.json_rpc.BufferParser
function M.BufferParser.new(on_message)
	local self = setmetatable({}, { __index = M.BufferParser })
	self.buffer = ""
	self.on_message = on_message
	return self
end

---Feed data into the parser
---@param data string
function M.BufferParser:feed(data)
	self.buffer = self.buffer .. data

	while true do
		local pos = self.buffer:find("\n", 1, true)
		if not pos then
			break
		end

		local line = self.buffer:sub(1, pos - 1)
		self.buffer = self.buffer:sub(pos + 1)

		line = line:gsub("\r$", "")
		if line ~= "" then
			local parsed = M.parse_message(line)
			if parsed.ok then
				self.on_message(parsed.data)
			end
		end
	end
end

---Get any remaining buffered data
---@return string
function M.BufferParser:remaining()
	return self.buffer
end

return M
