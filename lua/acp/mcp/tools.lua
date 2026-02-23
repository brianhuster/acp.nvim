---@class acp.mcp.Tools
local M = {}
local api, iter = vim.api, vim.iter

---@type table<vim.diagnostic.Severity, string>
local severity_map = {}
for k, v in pairs(vim.diagnostic.severity) do
	severity_map[v] = k
end

---@param path string
---@param lnum integer 1-based
---@param col integer 1-based
---@param end_lnum integer? 1-based
---@param end_col integer? 1-based
---@return string
local function get_path_with_line_col(path, lnum, col, end_lnum, end_col)
	if not end_lnum then
		end_lnum = lnum
	end
	if not end_col then
		end_col = col
	end
	if end_lnum > lnum then
		return ("%s:%d.%d-%d:%d"):format(path, lnum + 1, col + 1, end_lnum + 1, end_col)
	elseif end_col > col then
		return ("%s:%d.%d-%d"):format(path, lnum + 1, col + 1, end_col)
	else
		return ("%s:%d.%d"):format(path, lnum + 1, col + 1)
	end
end

---@param path string
---@param load_buf boolean
---@return number|string
local function path_to_bufnr(path, load_buf)
	local buf = vim.fn.bufnr(path)
	if buf < 0 then
		if vim.fn.filereadable(path) == 0 then
			return "Error: File not found: " .. path
		else
			buf = vim.fn.bufadd(path)
		end
	end
	if load_buf then
		vim.fn.bufload(buf)
	end
	return buf
end

---@param bufname string?
---@return string
function M.get_diagnostics(bufname)
	local buf
	if bufname and bufname ~= "" then
		buf = path_to_bufnr(bufname, true)
		if type(buf) == "string" then
			return buf
		end
	end

	---@class mcpDiagnostic : vim.Diagnostic
	---@field path string?

	---@type vim.Diagnostic[]
	local diagnostics = vim.diagnostic.get(buf)
	---@param d mcpDiagnostic
	return iter(diagnostics)
		:map(function(d)
			local d_bufname = vim.api.nvim_buf_get_name(d.bufnr)
			local path = vim.fs.relpath(vim.fn.getcwd(), d_bufname)
			d.path = path
			return d
		end)
		:filter(function(d)
			return d.path
		end)
		:map(function(d)
			local lnum = d.lnum
			local path = d.path
			local path_with_lnum_col = get_path_with_line_col(path, lnum + 1, d.col + 1, d.end_lnum + 1, d.end_col + 1)
			return ("%s [%s] %s\n```%s\n%s\n```"):format(
				path_with_lnum_col,
				severity_map[d.severity],
				d.message,
				vim.bo[d.bufnr].filetype,
				iter(api.nvim_buf_get_lines(d.bufnr, lnum, d.end_lnum + 1, false)):join("\n")
			)
		end)
		:join("\n\n")
end

---@param relative_path string
---@return table
function M.format(relative_path)
	local bufnr = path_to_bufnr(relative_path, true)
	if type(bufnr) == "string" then
		return {
			error = bufnr,
		}
	end
	local prev_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
	vim.lsp.buf.format({ bufnr = bufnr })
	local new_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local diff = vim.text.diff(table.concat(prev_lines, "\n") .. "\n", table.concat(new_lines, "\n") .. "\n")
	return {
		message = "Format applied successfully",
		changes = diff,
	}
end

---@param bufnr number?
---@param callback fun(f: fun(qf_what: vim.lsp.LocationOpts.OnList))
---@return vim.quickfix.entry[]
local function get_lsp_items(bufnr, callback)
	local result ---@type vim.quickfix.entry[]
	---@param qf_what vim.lsp.LocationOpts.OnList
	local function on_list(qf_what)
		result = qf_what.items
	end
	if bufnr then
		api.nvim_buf_call(bufnr, function()
			callback(on_list)
		end)
	else
		callback(on_list)
	end
	vim.wait(1000, function()
		return not not result
	end, 10)
	return result
end

---@param items vim.quickfix.entry[]
---@return string
local function qf_items_to_string(items)
	local type_map = {
		E = "[ERROR] ",
		W = "[WARNING] ",
		N = "[NOTE] ",
	}
	---@param i vim.quickfix.entry
	return iter(items):map(function(i)
		local path = get_path_with_line_col(i.filename, i.lnum, i.col, i.end_lnum, i.end_col)
		local text = (type_map[i.type] or "") .. i.text
		return ("%s: %s"):format(path, text)
	end):join("\n")
end

---@param query string?
---@param include_external boolean?
---@return string
function M.get_workspace_symbols(query, include_external)
	query = query or ""
	local items = get_lsp_items(nil, function(on_list)
		vim.lsp.buf.workspace_symbol(query, { on_list = on_list })
	end)
	if not include_external then
		---@param i vim.quickfix.entry
		items = iter(items):filter(function(i)
			return not not vim.fs.relpath(vim.fn.getcwd(), i.filename)
		end):totable()
	end
	return qf_items_to_string(items)
end

---@param relative_path string
function M.get_document_symbols(relative_path)
	local bufnr = path_to_bufnr(relative_path, true)
	if type(bufnr) == "string" then
		return bufnr
	end
	local items = get_lsp_items(bufnr, function(on_list)
		vim.lsp.buf.document_symbol({ on_list = on_list })
	end)
	return qf_items_to_string(items)
end

return M
