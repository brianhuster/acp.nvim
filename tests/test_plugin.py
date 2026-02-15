import pynvim
from pynvim import Nvim
import pytest
import utils
import time


def feed_keys(vim: Nvim, keys: str, mode: str = "n"):
    escaped = vim.api.replace_termcodes(keys, True, False, True)
    vim.api.feedkeys(escaped, mode, True)


@pytest.fixture
def vim():
    utils.init_env()
    vim = pynvim.attach(
        'child', argv=["nvim", "--headless", "--embed"])

    yield vim

    assert vim.vvars["errmsg"] == ""
    vim.close()
    utils.clean()


prompt = '\x1b]133;A\x07'


def test_cmdline_completion(vim: Nvim):
    """ Just test if completion for `:Acp` works
    """
    candidates = vim.funcs.getcompletion("Acp ", "cmdline")
    assert "new-session" in candidates
    assert "--dumb" in candidates


@pytest.mark.flaky(reruns=3)
def test_read(vim: Nvim):
    import os

    vim.command("edit Xtest/test-read.txt")
    vim.api.buf_set_lines(0, 0, -1, False, ["line1", "line2", "line3"])
    vim.command("Acp new-session")
    time.sleep(0.5)

    vim.command("startinsert")
    feed_keys(vim, "/test_read<CR>")  # Run slash command `/test_read`
    time.sleep(0.5)

    vim.command("startinsert")
    feed_keys(vim, "1<CR>")  # Accept permission
    time.sleep(0.5)

    vim.command("startinsert")
    feed_keys(vim, "/test_text<CR>")
    time.sleep(0.5)

    lines = vim.api.buf_get_lines(0, 0, -1, False)
    assert lines == [
            '\x1b]133;A\x07 /test_read',
            '',
            '🤖 I\'ll read the file "test-read.txt" for you using the file system client.',
            '🔧 Reading test-read.txt (pending)',
            '',
            '⚠️ Permission required: Reading test-read.txt',
            '  1. Allow reading',
            '  2. Reject',
            'Type number to choose: ',
            '\x1b]133;A\x07 1',
            '[Permission granted: Allow reading]',
            f'[Read {os.path.abspath("Xtest/test-read.txt")} (17 bytes)]',
            '',
            '🔧 completed',
            '<file>',
            '00001| line1',
            '00002| line2',
            '00003| line3',
            '',
            '(End of file - total 3 lines)',
            '</file> Successfully read the file!',
            '',
            '\x1b]133;A\x07 /test_text',
            '',
            '🤖 This is a simple text response for testing. No file operations needed!',
            '',
            '\x1b]133;A\x07 ']


@pytest.mark.flaky(reruns=3)
def test_write(vim: Nvim):
    file = "Xtest/test-write.txt"
    vim.command("edit " + file)
    vim.command("Acp new-session")
    time.sleep(0.5)
    vim.command("startinsert")
    feed_keys(vim, "/test_write<CR>")  # Run slash command `/test_write`
    time.sleep(0.5)
    vim.command("startinsert")
    feed_keys(vim, "1<CR>")  # Accept permission
    time.sleep(0.5)

    lines = vim.api.buf_get_lines(vim.funcs.bufnr(file), 0, -1, False)
    assert lines == ["Test data written.", "New line added!"]

    # The file Xtest/test-write.txt should not exist, as we only write to the
    # buffer
    import os
    assert not os.path.exists(file)


@pytest.mark.flaky(reruns=3)
def test_load_session(vim: Nvim):
    vim.command("edit acp://test/123456789abc")
    time.sleep(1.0)
    lines = vim.api.buf_get_lines(0, 0, -1, False)
    assert lines == [
            '',
            '',
            f'{prompt} Hello!',
            '',
            'Hi! How are you?',
            '',
            f"{prompt} I'm fine, thank you. And you?",
            '',
            'Fine, thanks',
            '\x1b]133;A\x07 ',
    ]


# @pytest.mark.flaky(reruns=3)
def test_agent_plan(vim: Nvim):
    vim.command("Acp new-session")
    time.sleep(0.5)
    vim.command("startinsert")
    feed_keys(vim, "/test_plan<CR>")
    time.sleep(0.5)

    lines = vim.api.buf_get_lines(0, 0, -1, False)
    assert lines == [
        '\x1b]133;A\x07 /test_plan',
        '',
        '🤖 [Plan updated]',
        '⏳ [HIGH] Analyze the existing codebase structure',
        '⏳ [HIGH] Identify components that need refactoring',
        '⏳ [MEDIUM] Create unit tests for critical functions',
        '',
        '',
        '\x1b]133;A\x07 ',
    ]

    vim.command("Acp view-plan")
    lines = vim.api.buf_get_lines(0, 0, -1, False)
    assert lines == [
        '⏳ [HIGH] Analyze the existing codebase structure',
        '⏳ [HIGH] Identify components that need refactoring',
        '⏳ [MEDIUM] Create unit tests for critical functions',
    ]


@pytest.mark.flaky(reruns=3)
def test_modes(vim: Nvim):
    vim.command("Acp new-session")
    time.sleep(0.5)
    candidates = vim.funcs.getcompletion("Acp set-mode ", "cmdline")
    assert set(candidates) == set(['architect', 'ask', 'code'])


def test_clipboard_image(vim: Nvim):
    import subprocess
    import time
    import requests
    import io
    from base64 import b64decode
    from PIL import Image, ImageChops, ImageStat

    # --- Download image ---
    img_file = "Xtest/test.png"
    url = "https://avatars.githubusercontent.com/u/6471485?s=48&v=4"
    response = requests.get(url)
    with open(img_file, "wb") as f:
        f.write(response.content)

    # --- Start clipboard owner in separate process ---
    proc = subprocess.Popen(
        ["uv", "run", "tests/clipboard_owner.py", "image", img_file]
    )

    try:
        # Give Qt time to start event loop and own clipboard.
        time.sleep(1.5)

        # --- Call Neovim ---
        vim.exec_lua("AcpClipboard = require 'acp.clipboard'")
        res = vim.lua.AcpClipboard.get_data()

        assert res is not None
        assert res["type"] == "image"

        blob = b64decode(res["data"])

        img_expected = Image.open(io.BytesIO(response.content)).convert("RGB")
        img_actual = Image.open(io.BytesIO(blob)).convert("RGB")

        assert img_expected.size == img_actual.size

        diff = ImageChops.difference(img_expected, img_actual)
        stat = ImageStat.Stat(diff)

        avg_diff = sum(stat.mean) / 3
        assert avg_diff < 5, f"Images are too different: {avg_diff}"

    finally:
        # Kill clipboard owner
        proc.terminate()
        proc.wait(timeout=2)


def test_clipboard_uri(vim: Nvim):
    import subprocess
    import time
    from pathlib import Path

    # Create dummy files because AppleScript's 'POSIX file' requires them to exist
    paths = ["Xtest/file1.txt", "Xtest/file2.txt"]
    for p in paths:
        with open(p, "w") as f:
            f.write("test")

    proc = subprocess.Popen(
        ["uv", "run", "tests/clipboard_owner.py", "uri", *paths],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True
    )

    try:
        time.sleep(2.0)

        # Check if process is still running and report error if it crashed
        if proc.poll() is not None:
            print(f"Clipboard owner exited early with code {proc.returncode}")
            print(f"Output: {proc.stdout.read()}")
            assert False, "Clipboard owner failed to start"

        vim.exec_lua("AcpClipboard = require 'acp.clipboard'")
        res = vim.lua.AcpClipboard.get_data()
        assert res == [Path(f).absolute().as_uri() for f in paths]

    finally:
        proc.terminate()
        proc.wait(timeout=2)
