---MCP types for the Model Context Protocol
---Types are based on the MCP specification: https://spec.modelcontextprotocol.io

local M = {}

---@class acp.mcp.Implementation
---@field name string
---@field version string
---@field description string?

---@class acp.mcp.ServerCapabilities
---@field tools { listChanged?: boolean }?
---@field resources { subscribe?: boolean, listChanged?: boolean }?
---@field prompts { listChanged?: boolean }?
---@field logging {}

---@class acp.mcp.ClientCapabilities
---@field tools { listChanged?: boolean }?
---@field resources { subscribe?: boolean, listChanged?: boolean }?
---@field prompts { listChanged?: boolean }?
---@field logging {}
---@field roots { listChanged?: boolean }?
---@field sampling {}

---@class acp.mcp.InitializeParams
---@field protocolVersion string
---@field capabilities acp.mcp.ClientCapabilities
---@field clientInfo acp.mcp.Implementation

---@class acp.mcp.InitializeResult
---@field protocolVersion string
---@field capabilities acp.mcp.ServerCapabilities
---@field serverInfo acp.mcp.Implementation

---@class acp.mcp.Icon
---@field src string
---@field mimeType string
---@field sizes string[]?

---@class acp.mcp.Tool
---@field name string
---@field description string
---@field inputSchema acp.mcp.JsonSchema
---@field icons acp.mcp.Icon[]?

---@class acp.mcp.JsonSchema
---@field type string?
---@field properties table<string, acp.mcp.JsonSchema>?
---@field required string[]?
---@field items acp.mcp.JsonSchema?
---@field additionalProperties boolean?

---@class acp.mcp.ListToolsParams
---@field cursor string?

---@class acp.mcp.ListToolsResult
---@field tools acp.mcp.Tool[]
---@field nextCursor string?

---@class acp.mcp.CallToolParams
---@field name string
---@field arguments table<string, any>?

---@class acp.mcp.TextContent
---@field type "text"
---@field text string

---@class acp.mcp.ImageContent
---@field type "image"
---@field data string
---@field mimeType string

---@class acp.mcp.ResourceContent
---@field type "resource"
---@field resource acp.mcp.TextResourceContents|acp.mcp.BlobResourceContents

---@class acp.mcp.TextResourceContents
---@field uri string
---@field mimeType string?
---@field text string

---@class acp.mcp.BlobResourceContents
---@field uri string
---@field mimeType string?
---@field blob string

---@alias acp.mcp.Content acp.mcp.TextContent|acp.mcp.ImageContent|acp.mcp.ResourceContent

---@class acp.mcp.CallToolResult
---@field content acp.mcp.Content[]
---@field isError boolean?

---@class acp.mcp.Prompt
---@field name string
---@field description string
---@field arguments acp.mcp.PromptArgument[]?

---@class acp.mcp.PromptArgument
---@field name string
---@field description string
---@field required boolean?
---@field type string?

---@class acp.mcp.ListPromptsResult
---@field prompts acp.mcp.Prompt[]

---@class acp.mcp.GetPromptParams
---@field name string
---@field arguments table<string, any>?

---@class acp.mcp.PromptMessage
---@field role "user"|"assistant"
---@field content acp.mcp.TextContent|acp.mcp.ResourceContent

---@class acp.mcp.GetPromptResult
---@field messages acp.mcp.PromptMessage[]

---@class acp.mcp.Resource
---@field uri string
---@field name string?
---@field description string?
---@field mimeType string?

---@class acp.mcp.ListResourcesResult
---@field resources acp.mcp.Resource[]

---Read resource request params
---@class acp.mcp.ReadResourceParams
---@field uri string

---@class acp.mcp.ReadResourceResult
---@field contents acp.mcp.TextResourceContents|acp.mcp.BlobResourceContents[]

return M
