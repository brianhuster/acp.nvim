#!/usr/bin/env -S nvim -l

-- Schema to LuaCATS Type Annotations Converter
-- Converts JSON Schema files into LuaCATS type annotations
-- Uses Neovim's vim.json and vim.fn modules

-- Add scripts directory to package path
local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
package.path = package.path .. ";" .. script_dir .. "/?.lua"

---@class SchemaConverter
---@field output_file string
---@field output string[]
---@field processed_types table<string, boolean>
local SchemaConverter = {}
SchemaConverter.__index = SchemaConverter

---Creates a new schema converter
---@param output_file string The output file path for generated annotations
---@return SchemaConverter
function SchemaConverter.new(output_file)
	local self = setmetatable({}, SchemaConverter)
	self.output_file = output_file
	self.output = {}
	self.processed_types = {}
	return self
end

---Adds a line to the output
---@param line string
function SchemaConverter:add_line(line)
	table.insert(self.output, line)
end

---Converts a JSON schema type to LuaCATS type
---@param schema_type string|table
---@return string
function SchemaConverter:json_type_to_lua(schema_type)
	if type(schema_type) == "table" then
		local types = {}
		for _, t in ipairs(schema_type) do
			if t == "null" then
				table.insert(types, "nil")
			elseif t == "string" then
				table.insert(types, "string")
			elseif t == "number" or t == "integer" then
				table.insert(types, "number")
			elseif t == "boolean" then
				table.insert(types, "boolean")
			elseif t == "array" then
				table.insert(types, "table")
			elseif t == "object" then
				table.insert(types, "table")
			else
				table.insert(types, t)
			end
		end
		return table.concat(types, "|")
	end

	if schema_type == "null" then
		return "nil"
	elseif schema_type == "string" then
		return "string"
	elseif schema_type == "number" or schema_type == "integer" then
		return "number"
	elseif schema_type == "boolean" then
		return "boolean"
	elseif schema_type == "array" then
		return "table"
	elseif schema_type == "object" then
		return "table"
	else
		return schema_type or "any"
	end
end

---Processes enum/const values
---@param schema table
---@return string|nil
function SchemaConverter:process_enum(schema)
	if schema.const then
		if type(schema.const) == "string" then
			return '"' .. schema.const .. '"'
		else
			return tostring(schema.const)
		end
	end
	if schema.enum then
		local values = {}
		for _, v in ipairs(schema.enum) do
			if type(v) == "string" then
				table.insert(values, '"' .. v .. '"')
			else
				table.insert(values, tostring(v))
			end
		end
		return table.concat(values, "|")
	end
	return nil
end

---Processes a property definition
---@param prop_name string
---@param prop_schema table
---@param required boolean
---@return string
function SchemaConverter:process_property(prop_name, prop_schema, required)
	local lua_type = "any"
	local description = prop_schema.description

	if prop_schema["$ref"] then
		local ref = prop_schema["$ref"]:match("#/%$defs/(.+)")
		if ref then
			lua_type = "acp." .. ref
		end
	elseif prop_schema.allOf then
		if prop_schema.allOf[1] and prop_schema.allOf[1]["$ref"] then
			local ref = prop_schema.allOf[1]["$ref"]:match("#/%$defs/(.+)")
			if ref then
				lua_type = "acp." .. ref
			end
		end
	elseif prop_schema.anyOf then
		local types = {}
		for _, schema in ipairs(prop_schema.anyOf) do
			if schema["$ref"] then
				local ref = schema["$ref"]:match("#/%$defs/(.+)")
				if ref then
					table.insert(types, "acp." .. ref)
				end
			elseif schema.allOf and schema.allOf[1] and schema.allOf[1]["$ref"] then
				local ref = schema.allOf[1]["$ref"]:match("#/%$defs/(.+)")
				if ref then
					table.insert(types, "acp." .. ref)
				end
			elseif schema.type then
				table.insert(types, self:json_type_to_lua(schema.type))
			end
		end
		lua_type = #types > 0 and table.concat(types, "|") or "any"
	elseif prop_schema.oneOf then
		local types = {}
		for _, schema in ipairs(prop_schema.oneOf) do
			if schema.allOf and schema.allOf[1] and schema.allOf[1]["$ref"] then
				local ref = schema.allOf[1]["$ref"]:match("#/%$defs/(.+)")
				if ref then
					table.insert(types, "acp." .. ref)
				end
			elseif schema["$ref"] then
				local ref = schema["$ref"]:match("#/%$defs/(.+)")
				if ref then
					table.insert(types, "acp." .. ref)
				end
			end
		end
		lua_type = #types > 0 and table.concat(types, "|") or "any"
	elseif
		prop_schema.type == "array"
		or (type(prop_schema.type) == "table" and vim.tbl_contains(prop_schema.type, "array"))
	then
		local is_nullable = type(prop_schema.type) == "table" and vim.tbl_contains(prop_schema.type, "null")

		if prop_schema.items then
			if prop_schema.items["$ref"] then
				local ref = prop_schema.items["$ref"]:match("#/%$defs/(.+)")
				if ref then
					lua_type = "acp." .. ref .. "[]"
				end
			elseif prop_schema.items.type then
				lua_type = self:json_type_to_lua(prop_schema.items.type) .. "[]"
			else
				lua_type = "table[]"
			end
		else
			lua_type = "table[]"
		end

		if is_nullable then
			lua_type = lua_type .. "|nil"
		end
	elseif prop_schema.const or prop_schema.enum then
		lua_type = self:process_enum(prop_schema) or lua_type
	elseif prop_schema.type then
		lua_type = self:json_type_to_lua(prop_schema.type)
		if prop_schema.type == "object" and prop_schema.additionalProperties then
			lua_type = "table<string, any>"
		end
	end

	if not required then
		lua_type = lua_type .. "?"
	end
	local result = "---@field " .. prop_name .. " " .. lua_type
	if description then
		result = result .. " " .. description:gsub("\n", " ")
	end
	return result
end

---Processes a type definition
---@param type_name string
---@param type_schema table
function SchemaConverter:process_type(type_name, type_schema)
	if self.processed_types[type_name] then
		return
	end
	self.processed_types[type_name] = true

	if type_schema.description then
		self:add_line("")
		local desc = vim.split(type_schema.description, "\n")
		for _, line in ipairs(desc) do
			self:add_line("---" .. line)
		end
	else
		self:add_line("")
	end

	local union_key = type_schema.oneOf and "oneOf" or (type_schema.anyOf and "anyOf")
	if union_key then
		local variants = type_schema[union_key]
		local all_const = true
		for _, variant in ipairs(variants) do
			if not variant.const then
				all_const = false
				break
			end
		end
		if all_const then
			local values = {}
			for _, variant in ipairs(variants) do
				table.insert(values, self:process_enum(variant))
			end
			self:add_line("---@alias acp." .. type_name .. " " .. table.concat(values, "|"))
			return
		end

		local refs = {}
		for i, variant in ipairs(variants) do
			local parent_ref = nil
			if variant.allOf and variant.allOf[1] and variant.allOf[1]["$ref"] then
				parent_ref = variant.allOf[1]["$ref"]:match("#/%$defs/(.+)")
			elseif variant["$ref"] then
				parent_ref = variant["$ref"]:match("#/%$defs/(.+)")
			end

			-- Use schema name/title if available, otherwise index
			if variant.title or variant.properties then
				local variant_suffix = variant.title or tostring(i)
				local variant_name = type_name .. "_" .. variant_suffix

				self:add_line("")
				if variant.description then
					self:add_line("---" .. variant.description:gsub("\n", " "))
				end

				if variant.type == "array" then
					local item_type = "table"
					if variant.items then
						if variant.items["$ref"] then
							local ref = variant.items["$ref"]:match("#/%$defs/(.+)")
							if ref then
								item_type = "acp." .. ref
							end
						elseif variant.items.type then
							item_type = self:json_type_to_lua(variant.items.type)
						end
					end
					self:add_line("---@alias acp." .. variant_name .. " " .. item_type .. "[]")
				else
					local class_def = "---@class acp." .. variant_name
					if parent_ref then
						class_def = class_def .. " : acp." .. parent_ref
					end
					self:add_line(class_def)

					if variant.properties then
						local req = {}
						if variant.required then
							for _, f in ipairs(variant.required) do
								req[f] = true
							end
						end
						-- Ensure properties are sorted for deterministic output
						local props = vim.tbl_keys(variant.properties)
						table.sort(props)
						for _, p_name in ipairs(props) do
							self:add_line(
								self:process_property(p_name, variant.properties[p_name], req[p_name] or false)
							)
						end
					end
				end
				table.insert(refs, "acp." .. variant_name)
			elseif parent_ref then
				table.insert(refs, "acp." .. parent_ref)
			elseif variant.type then
				table.insert(refs, self:json_type_to_lua(variant.type))
			end
		end
		if #refs > 0 then
			self:add_line("---@alias acp." .. type_name .. " " .. table.concat(refs, "|"))
			return
		end
	end

	if type_schema.type and not type_schema.properties and not type_schema.allOf then
		self:add_line("---@alias acp." .. type_name .. " " .. self:json_type_to_lua(type_schema.type))
	else
		self:add_line("---@class acp." .. type_name)
		if type_schema.properties then
			local req = {}
			if type_schema.required then
				for _, f in ipairs(type_schema.required) do
					req[f] = true
				end
			end
			local props = vim.tbl_keys(type_schema.properties)
			table.sort(props)
			for _, p_name in ipairs(props) do
				self:add_line(self:process_property(p_name, type_schema.properties[p_name], req[p_name] or false))
			end
		end
	end
end

---Processes a schema file
function SchemaConverter:process_schema(schema_path)
	local content = vim.fn.readfile(schema_path)
	local schema = vim.json.decode(table.concat(content, "\n"))
	if schema["$defs"] then
		local keys = vim.tbl_keys(schema["$defs"])
		table.sort(keys)
		for _, name in ipairs(keys) do
			if not schema["$defs"][name]["x-docs-ignore"] then
				self:process_type(name, schema["$defs"][name])
			end
		end
	end
end

---Writes the output to file
function SchemaConverter:write_output()
	table.insert(self.output, 1, "--- This file was generated by ./scripts/convert_schema.lua. Do not edit it manually")
	vim.fn.writefile(self.output, self.output_file)
end

local sc = SchemaConverter.new("lua/acp/types/schema.lua")
sc:process_schema("schema/schema.json")
sc:write_output()
