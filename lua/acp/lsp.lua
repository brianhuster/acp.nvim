local M = {}
local api = vim.api

---@param bufnr number
function M.start(bufnr)
	local acp = require("acp.core")

	vim.lsp.start({
		name = "acp-lsp",
		cmd = function(_)
			local handlers = {}

			handlers["initialize"] = function()
				return {
					capabilities = {
						completionProvider = {
							triggerCharacters = { "/" },
							resolveProvider = false,
						},
						signatureHelpProvider = {
							triggerCharacters = { " " },
						},
						documentSymbolProvider = true,
					},
				}
			end

			handlers["shutdown"] = function()
				return nil
			end

			handlers["exit"] = function()
				return nil
			end

			local function get_prompt_text(b, line_idx, char_idx)
				local line = api.nvim_buf_get_lines(b, line_idx, line_idx + 1, false)[1] or ""
				local mark = api.nvim_buf_get_mark(b, ":")
				-- Ensure we are on the prompt line
				if mark[1] - 1 ~= line_idx then
					return nil, nil
				end
				-- Prompt ends at mark[2]. User input starts after it.
				local start_col = mark[2]
				return line:sub(start_col + 1, char_idx), start_col
			end

			handlers["textDocument/completion"] = function(params)
				local b = vim.uri_to_bufnr(params.textDocument.uri)
				local session = acp.sessions[b]
				if not session or not session.available_commands then
					return nil
				end

				local input, start_col = get_prompt_text(b, params.position.line, params.position.character)
				if not input then
					return nil
				end

				-- Find the start of the command (the /)
				local cmd_start = input:find("/[^/]*$")
				if not cmd_start then
					return nil
				end

				local range = {
					start = { line = params.position.line, character = start_col + cmd_start - 1 },
					["end"] = { line = params.position.line, character = params.position.character },
				}

				local items = {}
				for _, cmd in ipairs(session.available_commands) do
					local new_text = "/" .. cmd.name
					table.insert(items, {
						label = new_text,
						kind = 14, -- Keyword
						detail = cmd.description,
						documentation = cmd.input and cmd.input.hint or nil,
						textEdit = {
							range = range,
							newText = new_text,
						},
					})
				end

				return items
			end

			handlers["textDocument/signatureHelp"] = function(params)
				local b = vim.uri_to_bufnr(params.textDocument.uri)
				local session = acp.sessions[b]
				if not session or not session.available_commands then
					return nil
				end

				local line_idx = params.position.line
				local input = get_prompt_text(b, line_idx, params.position.character)

				if not input or not input:match("^/") then
					return nil
				end

				local cmd_name = input:match("^/([^%s]+)")
				if not cmd_name then
					return nil
				end

				local found_cmd
				for _, cmd in ipairs(session.available_commands) do
					if cmd.name == cmd_name then
						found_cmd = cmd
						break
					end
				end

				if not found_cmd then
					return nil
				end

				local label = "/" .. found_cmd.name
				if found_cmd.input and found_cmd.input.hint then
					label = label .. " " .. found_cmd.input.hint
				end

				return {
					signatures = {
						{
							label = label,
							documentation = found_cmd.description,
							parameters = found_cmd.input and {
								{
									label = found_cmd.input.hint,
								},
							} or {},
						},
					},
					activeSignature = 0,
					activeParameter = 0,
				}
			end

			handlers["textDocument/documentSymbol"] = function(params)
				local b = vim.uri_to_bufnr(params.textDocument.uri)
				local lines = api.nvim_buf_get_lines(b, 0, -1, false)
				local symbols = {}
				local signature = "\027]133;A\a"

				for i, line in ipairs(lines) do
					if line:sub(1, #signature) == signature then
						local name = line:sub(#signature + 1):gsub("^%s*", "")
						if name == "" then
							name = "(empty prompt)"
						end
						local range = {
							start = { line = i - 1, character = 0 },
							["end"] = { line = i - 1, character = #line },
						}
						table.insert(symbols, {
							name = name,
							kind = 12, -- Function
							range = range,
							selectionRange = range,
						})
					end
				end

				return symbols
			end

			return {
				request = function(method, params, callback)
					if handlers[method] then
						local ok, result = pcall(handlers[method], params)
						if ok then
							-- Avoid error when calling with omnifunc
							if method == "textDocument/completion" then
								vim.schedule(function()
									callback(nil, result)
								end)
							else
								callback(nil, result)
							end
						else
							callback({ code = -32603, message = result })
						end
					else
						callback({ code = -32601, message = "Method not found" })
					end
					return true, 1
				end,
				notify = function() end,
				is_closing = function()
					return false
				end,
				terminate = function() end,
			}
		end,
		root_dir = vim.fn.getcwd(),
	}, {
		bufnr = bufnr,
	})
end

return M
