.PHONY: test lint lintlua linthelp format

ifeq ($(OS),Windows_NT)
  PYTEST := .venv/Scripts/pytest.exe
else
  PYTEST := .venv/bin/pytest
endif

test:
	uv sync
	$(PYTEST) -s tests

lint:
	nvim --clean -l scripts/luals.lua

format:
	stylua .
