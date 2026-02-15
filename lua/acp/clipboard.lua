-- Override vim.paste to support binary attachments in acpchat buffers
local M = {}

local supported = {
	{ type = "image", mimeType = "image/png", cls = "PNGf" },
	{ type = "image", mimeType = "image/jpeg", cls = "JPEG" },
}

---@type fun(): acp.ContentBlock_2[]|acp.ContentBlock_3[]|nil[]
M.get_data = nil

if vim.fn.has("win32") == 1 then
	M.get_data = function()
		local cmd = [=[
			Add-Type -AssemblyName System.Drawing;
			$img = Get-Clipboard -Format Image;
			if ($img) {
				$img.Save([Console]::OpenStandardOutput(), [System.Drawing.Imaging.ImageFormat]::Png); 
			}
		]=]
		local res = vim.system({ "powershell.exe", "-ExecutionPolicy", "Bypass", "-Command", cmd }, { text = false })
			:wait()
		if res.code == 0 and #res.stdout > 0 then
			return { {
				type = "image",
				mimeType = "image/png",
				data = vim.base64.encode(res.stdout),
			} }
		end
		return {}
	end
elseif vim.fn.has("mac") == 1 then
	M.get_data = function()
		for _, v in ipairs(supported) do
			local cls = v.cls
			if cls then
				local script = string.format("get the clipboard as «class %s»", cls)
				local res = vim.system({ "osascript", "-e", script }):wait()
				if res.code == 0 and res.stdout ~= "" then
					-- Strip «data CLASS...» wrapper and convert hex to binary
					local hex = res.stdout:gsub("^.-«data " .. cls, ""):gsub("».-$", "")
					local bin_res = vim.system({ "xxd", "-r", "-p" }, { stdin = hex, text = false }):wait()
					if bin_res.code == 0 then
						return {
							{
								type = v.type,
								mimeType = v.mimeType,
								data = vim.base64.encode(bin_res.stdout),
							},
						}
					end
				end
			end
		end
		return {}
	end
else
	local is_wayland = os.getenv("WAYLAND_DISPLAY") ~= nil
	M.executable = is_wayland and "wl-paste" or "xclip"
	M.get_data = function()
		local list_cmd = is_wayland and { M.executable, "--list-types" }
			or { M.executable, "-selection", "clipboard", "-o", "-t", "TARGETS" }
		local res = vim.system(list_cmd, { text = true }):wait()
		if res.code ~= 0 then
			return {}
		end

		for _, v in ipairs(supported) do
			local mime = v.mimeType
			if res.stdout:find(mime, 1, true) then
				local paste_cmd = is_wayland and { "wl-paste", "-t", mime }
					or { "xclip", "-selection", "clipboard", "-o", "-t", mime }
				local data_res = vim.system(paste_cmd, { text = false }):wait()
				if data_res.code == 0 then
					return {
						{
							type = v.type,
							mimeType = mime,
							data = vim.base64.encode(data_res.stdout),
						},
					}
				end
			end
		end
		return {}
	end
end

vim.paste = (function(overridden)
	return function(lines, phase)
		local bufnr = vim.api.nvim_get_current_buf()
		local session = require("acp.core").sessions[bufnr]
		local utils = require("acp.utils")

		if session and vim.bo[bufnr].filetype == "acpchat" then
			local prompt_cap = session.client.agentCapabilities.promptCapabilities or {}
			local data_list = M.get_data()
			for _, data in ipairs(data_list) do
				if data.type == "image" then
					if not prompt_cap.image then
						return utils.add_output(
							bufnr,
							("\n[Agent %s does not support %s]\n"):format(session.agent_name, data.type)
						)
					end
					table.insert(session.pending_attachments, data)
					utils.add_output(bufnr, "\n[Attached image from clipboard]\n")
				end
				return
			end
		end

		return overridden(lines, phase)
	end
end)(vim.paste)

return M
