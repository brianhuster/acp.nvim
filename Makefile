.PHONY: test lint lintlua linthelp format

test:
	uv sync
	uv run pytest -s -vv

lint:
	nvim --clean -l scripts/luals.lua

format:
	stylua .
