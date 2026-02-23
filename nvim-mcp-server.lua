local file_path = debug.getinfo(1, "S").source:sub(2)
local plugin_dir = vim.fs.dirname(file_path)
vim.opt.rtp:prepend(plugin_dir)

local NVIM = vim.env.NVIM
if not NVIM or NVIM == "" then
	io.stderr:write("Error: NVIM environment variable is not set.\n")
	os.exit(1)
end

local _, parent_chan = pcall(vim.fn.sockconnect, "pipe", NVIM, { rpc = true })
if not parent_chan or parent_chan == 0 then
	io.stderr:write("Nvim failed to connect to parent\n")
	os.exit(1)
end

---@param code string
---@param args any[]
local exec_lua = function(code, args)
	return vim.rpcrequest(parent_chan, "nvim_exec_lua", code, args)
end

---@type acp.mcp.Tools
local tools = setmetatable({}, {
	__index = function(_, key)
		return function(...)
			return exec_lua(string.format("return require('acp.mcp.tools').%s(...)", key), { ... })
		end
	end,
})

local mcp = require("acp.mcp.server")

local server = mcp.Server.new({
	name = "nvim-mcp-server",
	version = "0.1.0",
	instructions = [[If you see this MCP server, it means your user is using Neovim. You can use
    tools provided by this server to interact with the Neovim instance the user
    is using. This server also provides tools to use some language server
    protocol features, such as getting diagnostics and symbols, formatting code]],
})

server:tool(
	"get_diagnostics",
	[=[
	Get diagnostics for a given file or all opening files in Nvim.

    Use this tool to get information about errors, warnings, and other
    diagnostics reported by the language server. This should be called after
    performing edits to check for any new issues or to verify that existing
    issues have been resolved.

]=],
	{
		relative_path = {
			type = "string",
			description = [[Optional. The relative path to the file to get
		diagnostics for. If not provided, diagnostics for all open files will be
		returned.]],
		},
	},
	function(args, send)
		local ok, result = pcall(tools.get_diagnostics, args.relative_path)
		send({ content = { { type = "text", text = result } }, isError = not ok })
	end
)

server:tool("format", "Format a file using LSP", {
	relative_path = {
		type = "string",
		description = "Relative path to the file to format",
	},
}, function(args, send)
	local result = tools.format(args.relative_path)
	if result.error then
		send({ content = { { type = "text", text = result.error } }, isError = true })
		return
	end
	send({ content = { { type = "text", text = result.message .. "\n" .. result.changes } } })
end, { "relative_path" })

server:tool(
	"get_workspace_symbols",
	[[
	Use this tool to search for symbols across the entire workspace. This is
    useful when you are learning about the overall structure of the codebase or
    when you are looking for a specific symbol but don't know where it is
    defined.
]],
	{
		query = {
			type = "string",
			description = [[the query string to search for in the workspace symbols. If
    no query is provided, all symbols in the workspace will be returned.]],
		},
		include_external = {
			type = "boolean",
			description = "Whether to include symbols from external libraries outside current working directory. Default to false",
		},
	},
	function(args, send)
		local ok, result = pcall(tools.get_workspace_symbols, args.query, args.include_external)
		send({ content = { { type = "text", text = result } }, isError = not ok })
	end
)

server:tool(
	"get_document_symbols",
	[[Use this tool to get a high-level understanding of the code symbols in a
    file. This should be the first tool to call when you want to understand a
    new file, unless you already know what you are looking for.
	]],
	{
		relative_path = {
			type = "string",
			description = "Relative path to the file",
		},
	},
	function(args, send)
		local ok, result = pcall(tools.get_document_symbols, args.relative_path)
		send({ content = { { type = "text", text = result } }, isError = not ok })
	end,
	{ "relative_path" }
)

server:start()
