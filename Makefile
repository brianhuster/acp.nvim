.PHONY: test lint lintlua linthelp format schema

ACP_LINK = "https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/refs/heads/main/schema/"

schema:
	curl $(ACP_LINK)schema.json -o schema/schema.json
	curl $(ACP_LINK)meta.json -o schema/meta.json
	nvim -l scripts/convert_schema.lua
	nvim -l scripts/convert_meta.lua

test:
	uv sync
	uv run pytest -s -vv $(TEST_FILE)

lint:
	nvim --clean -l scripts/luals.lua

format:
	stylua .

inspect-mcp:
	npx @modelcontextprotocol/inspector nvim -l nvim-mcp-server.lua
