-- Override vim.paste to support binary attachments in acpchat buffers
local M = {}
local testing = vim.v.testing

local b64_encode = vim.base64.encode
local img_types = {
	{ type = "image", mimeType = "image/png", cls = "PNGf" },
	{ type = "image", mimeType = "image/jpeg", cls = "JPEG" },
}

local systemlist = function(cmd)
	local res = vim.system(cmd, { text = true }):wait()
	if res.code == 0 then
		return vim.split(res.stdout, "\n", { plain = true, trimempty = true })
	elseif testing then
		error(("Command failed: %s\nstdout: %s\nstderr: %s"):format(table.concat(cmd, " "), res.stdout, res.stderr))
	else
		return {}
	end
end

--- Allow users to paste images/files to chat buffers
---@type fun(): acp.ContentBlock_2|acp.ContentBlock_3|string[]|nil
M.get_data = nil

if vim.fn.has("win32") == 1 then
	M.get_data = function()
		local res = vim.system({
			"powershell.exe",
			"-ExecutionPolicy",
			"Bypass",
			"-Command",
			[=[
				Add-Type -AssemblyName System.Drawing;
				$img = Get-Clipboard -Format Image;
				if ($img) {
					$img.Save([Console]::OpenStandardOutput(), [System.Drawing.Imaging.ImageFormat]::Png);
				}
			]=],
		}, { text = false }):wait()
		if res.code == 0 and #res.stdout > 0 then
			return {
				type = "image",
				mimeType = "image/png",
				data = b64_encode(res.stdout),
			}
		else
			return systemlist({
				"powershell.exe",
				"-ExecutionPolicy",
				"Bypass",
				"-Command",
				"(Get-Clipboard -Format FileDropList) | ForEach-Object { ([System.Uri]$_.FullName).AbsoluteUri }",
			})
		end
	end
elseif vim.fn.has("mac") == 1 then
	M.get_data = function()
		local clipinfo = vim.system({ "osascript", "-e", "clipboard info" }, { text = true }):wait().stdout
		if not clipinfo then
			return
		end
		for _, v in ipairs(img_types) do
			local cls = v.cls
			if clipinfo:find(("«class %s»"):format(cls), 1, true) then
				local script = string.format("get the clipboard as «class %s»", cls)
				local res = vim.system({ "osascript", "-e", script }):wait()
				if res.code == 0 and res.stdout ~= "" then
					-- Strip «data CLASS...» wrapper and convert hex to binary
					local hex = res.stdout:gsub("^.-«data " .. cls, ""):gsub("».-$", "")
					local decoded = vim.text.hexdecode(hex)
					if decoded then
						return {
							type = v.type,
							mimeType = v.mimeType,
							data = b64_encode(decoded),
						}
					end
				end
			end
		end
		-- Use AppleScriptObjC to reliably retrieve all URLs (Finder or Qt6)
		local script = [[
			use framework "Foundation"
			use scripting additions
			set pb to current application's NSPasteboard's generalPasteboard()
			set theURLs to pb's readObjectsForClasses:{current application's NSURL} options:(missing value)
			set out to {}
			repeat with aURL in theURLs
				copy (aURL's absoluteString() as string) to end of out
			end repeat
			set AppleScript's text item delimiters to linefeed
			return out as string
		]]
		return systemlist({ "osascript", "-e", script })
	end
else
	local is_wayland = os.getenv("WAYLAND_DISPLAY") ~= nil
	M.executable = is_wayland and "wl-paste" or "xclip"
	M.get_data = function()
		local list_cmd = is_wayland and { M.executable, "--list-types" }
			or { M.executable, "-selection", "clipboard", "-o", "-t", "TARGETS" }
		local res = vim.system(list_cmd, { text = true }):wait()
		if res.code ~= 0 then
			return
		end

		local get_paste_cmd ---@type fun(mime: string): string[]
		if is_wayland then
			function get_paste_cmd(mime)
				return { "wl-paste", "-t", mime }
			end
		else
			function get_paste_cmd(mime)
				return { "xclip", "-selection", "clipboard", "-o", "-t", mime }
			end
		end

		for _, v in ipairs(img_types) do
			local mime = v.mimeType
			if res.stdout:find(mime, 1, true) then
				local paste_cmd = get_paste_cmd(mime)
				local data_res = vim.system(paste_cmd, { text = false }):wait()
				if data_res.code == 0 then
					return {
						type = v.type,
						mimeType = mime,
						data = b64_encode(data_res.stdout),
					}
				end
			end
		end
		if res.stdout:find("text/uri-list", 1, true) then
			local paste_cmd = get_paste_cmd("text/uri-list")
			return systemlist(paste_cmd)
		end
	end
end

vim.paste = (function(overridden)
	return function(lines, phase)
		local buf = vim.api.nvim_get_current_buf()
		local session = require("acp.core").sessions[buf]

		if (phase == 1 or phase == -1) and session and vim.bo[buf].filetype == "acpchat" then
			local utils = require("acp.utils")
			local prompt_cap = session.client.agentCapabilities.promptCapabilities or {}
			local data = M.get_data()
			if data then
				if data.type == "image" then
					if not prompt_cap.image then
						return utils.add_output(
							buf,
							("\n[Agent %s does not support %s]\n"):format(session.agent_name, data.type)
						)
					end
					table.insert(session.pending_attachments, data)
					utils.add_output(buf, "\n[Attached image from clipboard]\n")
					return false
				else -- data is a list of urls
					for _, path in ipairs(data) do
						require("acp").add_resource(buf, vim.uri_to_fname(path))
						utils.add_output(buf, ("\n[Attached file: %s]\n"):format(path))
					end
					return false
				end
			end
		end
		return overridden(lines, phase)
	end
end)(vim.paste)

return M
