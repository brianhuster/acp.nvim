-- Override vim.paste to support binary attachments in acpchat buffers
local M = {}

local supported = {
	{ type = "image", mimeType = "image/png", cls = "PNGf", fmt = "PNG" },
	{ type = "image", mimeType = "image/jpeg", cls = "JPEG", fmt = "JFIF" },
}

---@type fun(): acp.ContentBlock_2|acp.ContentBlock_3|nil
M.get_image = nil

if vim.fn.has("linux") == 1 then
	local is_wayland = os.getenv("WAYLAND_DISPLAY") ~= nil
	M.executable = is_wayland and "wl-paste" or "xclip"
	M.get_image = function()
		local list_cmd = is_wayland and { M.executable, "--list-types" }
			or { M.executable, "-selection", "clipboard", "-o", "-t", "TARGETS" }
		local res = vim.system(list_cmd, { text = true }):wait()
		if res.code ~= 0 then
			return nil
		end

		for _, v in ipairs(supported) do
			local mime = v.mimeType
			if res.stdout:find(mime, 1, true) then
				local paste_cmd = is_wayland and { "wl-paste", "-t", mime }
					or { "xclip", "-selection", "clipboard", "-o", "-t", mime }
				local data_res = vim.system(paste_cmd, { text = false }):wait()
				if data_res.code == 0 then
					return {
						type = v.type,
						mimeType = mime,
						data = vim.base64.encode(data_res.stdout),
					}
				end
			end
		end
	end
elseif vim.fn.has("mac") == 1 then
	M.get_image = function()
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
							type = v.type,
							mimeType = v.mimeType,
							data = vim.base64.encode(bin_res.stdout),
						}
					end
				end
			end
		end
	end
elseif vim.fn.has("win32") == 1 then
	M.get_image = function()
		for _, v in ipairs(supported) do
			local fmt = v.fmt
			local cmd = [=[
				Add-Type -AssemblyName System.Windows.Forms;
				Add-Type -AssemblyName System.Drawing;
				$d = [Windows.Forms.Clipboard]::GetDataObject();
				if ($d.GetDataPresent(']=] .. fmt .. [=[')) {
					$v = $d.GetData(']=] .. fmt .. [=[');
					if ($v -is [System.Drawing.Image]) {
						$ms = New-Object System.IO.MemoryStream;
						$v.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png);
						$bytes = $ms.ToArray();
						[Console]::OpenStandardOutput().Write($bytes, 0, $bytes.Length);
					} elseif ($v -is [System.IO.Stream]) {
						$v.CopyTo([Console]::OpenStandardOutput());
					} elseif ($v -is [byte[]]) {
						[Console]::OpenStandardOutput().Write($v, 0, $v.Length);
					}
				}
			]=]
			local res = vim.system(
				{ "powershell.exe", "-ExecutionPolicy", "Bypass", "-Command", cmd },
				{ text = false }
			)
				:wait()
			if res.code == 0 and #res.stdout > 0 then
				return {
					type = v.type,
					mimeType = v.mimeType,
					data = vim.base64.encode(res.stdout),
				}
			end
		end

		-- Final fallback for Windows: use GetImage() which handles standard Bitmap formats
		local fallback_cmd = [=[
			Add-Type -AssemblyName System.Windows.Forms;
			Add-Type -AssemblyName System.Drawing;
			if ([Windows.Forms.Clipboard]::ContainsImage()) {
				$v = [Windows.Forms.Clipboard]::GetImage();
				$ms = New-Object System.IO.MemoryStream;
				$v.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png);
				$bytes = $ms.ToArray();
				[Console]::OpenStandardOutput().Write($bytes, 0, $bytes.Length);
			}
		]=]
		local res = vim.system(
			{ "powershell.exe", "-ExecutionPolicy", "Bypass", "-Command", fallback_cmd },
			{ text = false }
		)
			:wait()
		if res.code == 0 and #res.stdout > 0 then
			return {
				type = "image",
				mimeType = "image/png",
				data = vim.base64.encode(res.stdout),
			}
		end
	end
end

vim.paste = (function(overridden)
	return function(lines, phase)
		local bufnr = vim.api.nvim_get_current_buf()
		local session = require("acp.core").sessions[bufnr]
		local utils = require("acp.utils")

		if session and vim.bo[bufnr].filetype == "acpchat" then
			local prompt_cap = session.client.agentCapabilities.promptCapabilities or {}
			local data = M.get_image()
			if not data then
				return overridden(lines, phase)
			end
			if not prompt_cap[data.type] then
				utils.append_text(bufnr, ("\n[Agent %s does not support %s]\n"):format(session.agent_name, data.type))
			end
			table.insert(session.pending_attachments, data)
			utils.append_text(bufnr, ("\n[Attached %s from clipboard]\n"):format(data.type))
		end

		return overridden(lines, phase)
	end
end)(vim.paste)

return M
