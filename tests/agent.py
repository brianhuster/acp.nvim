import asyncio
import logging
import os
import secrets
from typing import Any

from acp import (
    PROTOCOL_VERSION,
    Agent,
    AuthenticateResponse,
    InitializeResponse,
    LoadSessionResponse,
    NewSessionResponse,
    PromptResponse,
    SetSessionModeResponse,
    run_agent,
    start_edit_tool_call,
    start_read_tool_call,
    text_block,
    tool_content,
    tool_diff_content,
    update_agent_message_text,
    update_user_message_text,
    update_tool_call,
)
from acp.helpers import (
    update_available_commands,
    update_current_mode,
)
from acp.interfaces import Client
from acp.schema import (
    AgentCapabilities,
    AvailableCommand,
    ClientCapabilities,
    HttpMcpServer,
    Implementation,
    McpServerStdio,
    PermissionOption,
    SessionMode,
    SessionModeState,
    SseMcpServer,
    ToolCallUpdate,
    AgentPlanUpdate,
    PlanEntry
)


class AgentSession:
    def __init__(self) -> None:
        self.pending_prompt: asyncio.Task[None] | None = None


class ExampleAgent(Agent):
    _conn: Client

    def __init__(self) -> None:
        self._sessions: dict[str, AgentSession] = {}

    def on_connect(self, conn: Client) -> None:
        self._conn = conn

    async def initialize(
        self,
        protocol_version: int,
        client_capabilities: ClientCapabilities | None = None,
        client_info: Implementation | None = None,
        **kwargs: Any,
    ) -> InitializeResponse:
        return InitializeResponse(
            protocol_version=PROTOCOL_VERSION,
            agent_capabilities=AgentCapabilities(load_session=True),
            agent_info=Implementation(name="example-agent", title="Example Agent", version="0.1.0"),
        )

    async def authenticate(self, method_id: str, **kwargs: Any) -> AuthenticateResponse | None:
        return AuthenticateResponse()

    async def new_session(
        self, cwd: str, mcp_servers: list[HttpMcpServer | SseMcpServer | McpServerStdio] | None = None, **kwargs: Any
    ) -> NewSessionResponse:
        session_id = secrets.token_hex(16)
        self._sessions[session_id] = AgentSession()

        # Send available commands update notification
        asyncio.create_task(self._send_available_commands(session_id))

        return NewSessionResponse(
            session_id=session_id,
            modes=SessionModeState(
                current_mode_id="ask",
                available_modes=[
                    SessionMode(
                        id="ask", name="Ask", description="Request permission before making any changes"),
                    SessionMode(
                        id="architect",
                        name="Architect",
                        description="Design and plan software systems without implementation",
                    ),
                    SessionMode(id="code", name="Code", description="Write and modify code with full tool access"),
                ],
            ),
        )

    async def _send_available_commands(self, session_id: str) -> None:
        try:
            await self._conn.session_update(
                session_id=session_id,
                update=update_available_commands(
                    [
                        AvailableCommand(name="test_text", description="Test simple text response"),
                        AvailableCommand(
                            name="test_read",
                            description="Test file read operation",
                            input={"hint": "[filename]"},
                        ),
                        AvailableCommand(
                            name="test_write",
                            description="Test file write operation with diff",
                            input={"hint": "[filename]"},
                        ),
                        AvailableCommand(
                            name="test_plan",
                            description="Test updating plan",
                        )
                    ]
                ),
            )
        except Exception:
            logging.exception("Error sending available commands")

    async def load_session(
        self,
        cwd: str,
        session_id: str,
        mcp_servers: list[HttpMcpServer | SseMcpServer | McpServerStdio] | None = None,
        **kwargs: Any,
    ) -> LoadSessionResponse | None:
        self._sessions[session_id] = AgentSession()

        if session_id == "123456789abc":
            await self._stream_history(session_id)

        return LoadSessionResponse(
            session_id=session_id,
            modes=SessionModeState(
                current_mode_id="ask",
                available_modes=[
                    SessionMode(
                        id="ask", name="Ask", description="Request permission before making any changes"),
                    SessionMode(
                        id="architect",
                        name="Architect",
                        description="Design and plan software systems without implementation",
                    ),
                    SessionMode(id="code", name="Code", description="Write and modify code with full tool access"),
                ],
            ),
        )

    async def _stream_history(self, session_id: str) -> None:
        updates = [
            update_user_message_text("Hello!"),
            update_agent_message_text("Hi! How are you?"),
            update_user_message_text("I'm fine, thank you. And you?"),
            update_agent_message_text("Fine, thanks"),
        ]
        for update in updates:
            await self._conn.session_update(session_id=session_id, update=update)
            await asyncio.sleep(0.01)


    async def set_session_mode(self, mode_id: str, session_id: str, **kwargs: Any) -> SetSessionModeResponse | None:
        await self._conn.session_update(session_id=session_id, update=update_current_mode(mode_id))
        return SetSessionModeResponse()

    async def prompt(
        self,
        prompt: list[Any],
        session_id: str,
        **kwargs: Any,
    ) -> PromptResponse:
        session = self._sessions.get(session_id)
        if not session:
            session = AgentSession()
            self._sessions[session_id] = session

        if session.pending_prompt:
            session.pending_prompt.cancel()

        session.pending_prompt = asyncio.create_task(self.handle_prompt(session_id, prompt))

        try:
            await session.pending_prompt
        except asyncio.CancelledError:
            return PromptResponse(stop_reason="cancelled")
        except Exception:
            logging.exception("Error handling prompt")
            raise
        finally:
            session.pending_prompt = None

        return PromptResponse(stop_reason="end_turn")

    async def handle_prompt(self, session_id: str, prompt: list[Any]) -> None:
        prompt_text = ""
        for block in prompt:
            if hasattr(block, "text"):
                prompt_text += block.text
            elif isinstance(block, dict) and block.get("type") == "text":
                prompt_text += block.get("text", "")

        parts = prompt_text.split()
        if not parts:
            return
        cmd = parts[0]
        args = parts[1:]

        if cmd == "/test_text":
            await self.handle_text_test(session_id)
        elif cmd == "/test_read":
            filename = args[0] if args else "Xtest/test-read.txt"
            await self.handle_read_test(session_id, filename)
        elif cmd == "/test_write":
            filename = args[0] if args else "Xtest/test-write.txt"
            await self.handle_write_test(session_id, filename)
        elif cmd == "/test_plan":
            await self._conn.session_update(
                session_id=session_id,
                update=AgentPlanUpdate(sessionUpdate="plan",
                    entries=[
                        PlanEntry(content="Analyze the existing codebase structure", priority="high", status="pending"),
                        PlanEntry(content="Identify components that need refactoring", priority="high", status="pending"),
                        PlanEntry(content="Create unit tests for critical functions", priority="medium", status="pending")
                    ]
                )
            )
        else:
            await self._conn.session_update(
                session_id=session_id,
                update=update_agent_message_text(
                    f'I received your message: "{prompt_text}". Use /test_text, /test_read, or /test_write for specific tests.'
                ),
            )

    async def handle_text_test(self, session_id: str) -> None:
        await self._conn.session_update(
            session_id=session_id,
            update=update_agent_message_text("This is a simple text response for testing. No file operations needed!"),
        )

    def format_file_content(self, content: str) -> str:
        lines = content.split("\n")
        total_lines = len(lines)
        formatted = "<file>\n"
        for i, line in enumerate(lines):
            line_num = str(i + 1).zfill(5)
            formatted += f"{line_num}| {line}\n"
        formatted += f"\n(End of file - total {total_lines} lines)\n</file>"
        return formatted

    async def handle_read_test(self, session_id: str, filename: str) -> None:
        test_file_path = os.path.abspath(filename)

        await self._conn.session_update(
            session_id=session_id,
            update=update_agent_message_text(
                f'I\'ll read the file "{os.path.basename(test_file_path)}" for you using the file system client.'
            ),
        )

        await asyncio.sleep(0.2)

        tool_call_id = "read_1"
        tc_start = start_read_tool_call(tool_call_id, f"Reading {os.path.basename(test_file_path)}", test_file_path)
        await self._conn.session_update(
            session_id=session_id,
            update=tc_start,
        )

        resp = await self._conn.request_permission(
            session_id=session_id,
            tool_call=ToolCallUpdate(
                tool_call_id=tool_call_id,
                title=tc_start.title,
                kind=tc_start.kind,
                status=tc_start.status,
                locations=tc_start.locations,
                raw_input=tc_start.raw_input,
            ),
            options=[
                PermissionOption(kind="allow_once", name="Allow reading", option_id="allow"),
                PermissionOption(kind="reject_once", name="Reject", option_id="reject"),
            ],
        )

        outcome = resp.outcome
        is_selected = getattr(outcome, "outcome", None) == "selected"
        opt_id = getattr(outcome, "option_id", getattr(outcome, "optionId", None))

        if is_selected and opt_id == "allow":
            try:
                result = await self._conn.read_text_file(path=test_file_path, session_id=session_id)
                formatted_content = self.format_file_content(result.content)

                await self._conn.session_update(
                    session_id=session_id,
                    update=update_tool_call(
                        tool_call_id=tool_call_id,
                        status="completed",
                        content=[tool_content(text_block(formatted_content))],
                        raw_output={"content": result.content},
                    ),
                )

                await asyncio.sleep(0.2)
                await self._conn.session_update(
                    session_id=session_id,
                    update=update_agent_message_text(" Successfully read the file!"),
                )
            except Exception as e:
                logging.exception("Error during read operation")
                await self._conn.session_update(
                    session_id=session_id,
                    update=update_tool_call(tool_call_id=tool_call_id, status="failed", raw_output={"error": str(e)}),
                )
        else:
            await self._conn.session_update(
                session_id=session_id,
                update=update_agent_message_text(" Read operation was cancelled."),
            )

    async def handle_write_test(self, session_id: str, filename: str) -> None:
        write_file_path = os.path.join(os.getcwd(), filename)
        write_content = "Test data written.\nNew line added!"

        await self._conn.session_update(
            session_id=session_id,
            update=update_agent_message_text(
                f'I\'ll write some test data to "{os.path.basename(write_file_path)}". I\'ll show you a diff first.'
            ),
        )

        await asyncio.sleep(0.2)

        old_text = None
        try:
            result = await self._conn.read_text_file(path=write_file_path, session_id=session_id)
            old_text = result.content
        except Exception:
            pass

        tool_call_id = "write_1"
        tc_start = start_edit_tool_call(
            tool_call_id,
            f"Writing {os.path.basename(write_file_path)}",
            write_file_path,
            write_content,
            extra_options=[tool_diff_content(write_file_path, write_content, old_text)],
        )
        await self._conn.session_update(
            session_id=session_id,
            update=tc_start,
        )

        resp = await self._conn.request_permission(
            session_id=session_id,
            tool_call=ToolCallUpdate(
                tool_call_id=tool_call_id,
                title=tc_start.title,
                kind=tc_start.kind,
                status=tc_start.status,
                locations=tc_start.locations,
                raw_input=tc_start.raw_input,
            ),
            options=[
                PermissionOption(kind="allow_once", name="Allow writing", option_id="allow"),
                PermissionOption(kind="reject_once", name="Reject", option_id="reject"),
            ],
        )

        outcome = resp.outcome
        is_selected = getattr(outcome, "outcome", None) == "selected"
        opt_id = getattr(outcome, "option_id", getattr(outcome, "optionId", None))

        if is_selected and opt_id == "allow":
            try:
                await self._conn.write_text_file(content=write_content, path=write_file_path, session_id=session_id)

                await self._conn.session_update(
                    session_id=session_id,
                    update=update_tool_call(
                        tool_call_id=tool_call_id,
                        status="completed",
                        raw_output={"success": True, "bytesWritten": len(write_content)},
                    ),
                )

                await asyncio.sleep(0.2)
                await self._conn.session_update(
                    session_id=session_id,
                    update=update_agent_message_text(f" Successfully wrote {len(write_content)} bytes!"),
                )
            except Exception as e:
                logging.exception("Error during write operation")
                await self._conn.session_update(
                    session_id=session_id,
                    update=update_tool_call(tool_call_id=tool_call_id, status="failed", raw_output={"error": str(e)}),
                )
        else:
            await self._conn.session_update(
                session_id=session_id,
                update=update_agent_message_text(" Write operation was cancelled."),
            )

    async def cancel(self, session_id: str, **kwargs: Any) -> None:
        session = self._sessions.get(session_id)
        if session and session.pending_prompt:
            session.pending_prompt.cancel()

    async def ext_method(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        return {"example": "response"}

    async def ext_notification(self, method: str, params: dict[str, Any]) -> None:
        pass


async def main() -> None:
    logging.basicConfig(level=logging.INFO)
    await run_agent(ExampleAgent())


if __name__ == "__main__":
    asyncio.run(main())
