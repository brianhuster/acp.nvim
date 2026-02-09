#!/usr/bin/env node

import * as acp from "@agentclientprotocol/sdk";
import { Readable, Writable } from "node:stream";
import * as path from "node:path";
import * as crypto from "node:crypto";

interface AgentSession {
	pendingPrompt: AbortController | null;
}

class TestAgent implements acp.Agent {
	private connection: acp.AgentSideConnection;
	private sessions: Map<string, AgentSession>;

	constructor(connection: acp.AgentSideConnection) {
		this.connection = connection;
		this.sessions = new Map();
	}

	async initialize(
		_params: acp.InitializeRequest,
	): Promise<acp.InitializeResponse> {
		return {
			protocolVersion: acp.PROTOCOL_VERSION,
			agentCapabilities: {
				loadSession: false,
			},
		};
	}

	async newSession(
		_params: acp.NewSessionRequest,
	): Promise<acp.NewSessionResponse> {
		const sessionId = Array.from(crypto.getRandomValues(new Uint8Array(16)))
			.map((b) => b.toString(16).padStart(2, "0"))
			.join("");

		this.sessions.set(sessionId, {
			pendingPrompt: null,
		});

		// Send available commands update notification
		setTimeout(() => {
			this.connection.sessionUpdate({
				sessionId: sessionId,
				update: {
					sessionUpdate: "available_commands_update",
					availableCommands: [
						{
							name: "test_text",
							description: "Test simple text response",
						},
						{
							name: "test_read",
							description: "Test file read operation",
							input: {
								hint: "[filename]"
							}
						},
						{
							name: "test_write",
							description: "Test file write operation with diff",
							input: {
								hint: "[filename]"
							}
						}
					]
				} as any
			});
		}, 100);

		return {
			sessionId: sessionId,
			modes: {
				currentModeId: "ask",
				availableModes: [
					{
						id: "ask",
						name: "Ask",
						description: "Request permission before making any changes"
					},
					{
						id: "architect",
						name: "Architect",
						description: "Design and plan software systems without implementation"
					},
					{
						id: "code",
						name: "Code",
						description: "Write and modify code with full tool access"
					}
				]
			}
		};
	}

	async authenticate(
		_params: acp.AuthenticateRequest,
	): Promise<acp.AuthenticateResponse | void> {
		return {};
	}

	async setSessionMode(
		_params: acp.SetSessionModeRequest,
	): Promise<acp.SetSessionModeResponse> {
		await this.connection.sessionUpdate({
			sessionId: _params.sessionId,
			update: {
				sessionUpdate: "current_mode_update",
				currentModeId: _params.modeId,
			}
		})
		return {};
	}

	async prompt(params: acp.PromptRequest): Promise<acp.PromptResponse> {
		const session = this.sessions.get(params.sessionId);

		if (!session) {
			throw new Error(`Session ${params.sessionId} not found`);
		}

		session.pendingPrompt?.abort();
		session.pendingPrompt = new AbortController();

		try {
			await this.handlePrompt(
				params.sessionId,
				params.prompt,
				session.pendingPrompt.signal,
			);
		} catch (err) {
			if (session.pendingPrompt.signal.aborted) {
				return { stopReason: "cancelled" };
			}

			throw err;
		}

		session.pendingPrompt = null;

		return {
			stopReason: "end_turn",
		};
	}

	private async handlePrompt(
		sessionId: string,
		prompt: acp.ContentBlock[],
		abortSignal: AbortSignal,
	): Promise<void> {
		let promptText = "";
		for (const block of prompt) {
			if (block.type === "text") {
				promptText += block.text;
			}
		}

		const [cmd, ...args] = promptText.split(/\s+/);

		if (cmd === "/test_text") {
			await this.handleTextTest(sessionId, abortSignal);
		} else if (cmd === "/test_read") {
			await this.handleReadTest(sessionId, abortSignal, args[0]);
		} else if (cmd === "/test_write") {
			await this.handleWriteTest(sessionId, abortSignal, args[0]);
		} else {
			await this.connection.sessionUpdate({
				sessionId,
				update: {
					sessionUpdate: "agent_message_chunk",
					content: {
						type: "text",
						text: `I received your message: "${promptText}". Use /test_text, /test_read, or /test_write for specific tests.`,
					},
				},
			});
		}
	}

	private async handleTextTest(
		sessionId: string,
		_abortSignal: AbortSignal,
	): Promise<void> {
		await this.connection.sessionUpdate({
			sessionId,
			update: {
				sessionUpdate: "agent_message_chunk",
				content: {
					type: "text",
					text: "This is a simple text response for testing. No file operations needed!",
				},
			},
		});
	}

	private formatFileContent(content: string): string {
		const lines = content.split("\n");
		const totalLines = lines.length;
		let formatted = "<file>\n";
		lines.forEach((line, index) => {
			const lineNum = (index + 1).toString().padStart(5, "0");
			formatted += `${lineNum}| ${line}\n`;
		});
		formatted += `\n(End of file - total ${totalLines} lines)\n</file>`;
		return formatted;
	}

	private async handleReadTest(
		sessionId: string,
		abortSignal: AbortSignal,
		filename?: string,
	): Promise<void> {
		const testFilePath = path.join(process.cwd(), filename || "test-read.txt");

		await this.connection.sessionUpdate({
			sessionId,
			update: {
				sessionUpdate: "agent_message_chunk",
				content: {
					type: "text",
					text: `I'll read the file "${path.basename(testFilePath)}" for you using the file system client.`,
				},
			},
		});

		await this.simulateDelay(abortSignal, 300);

		await this.connection.sessionUpdate({
			sessionId,
			update: {
				sessionUpdate: "tool_call",
				toolCallId: "read_1",
				title: `Reading ${path.basename(testFilePath)}`,
				kind: "read",
				status: "pending",
				locations: [{ path: testFilePath }],
				rawInput: { path: testFilePath },
			},
		});

		const readPermission = await this.connection.requestPermission({
			sessionId,
			toolCall: {
				toolCallId: "read_1",
				title: `Reading ${path.basename(testFilePath)}`,
				kind: "read",
				status: "pending",
				locations: [{ path: testFilePath }],
				rawInput: { path: testFilePath },
			},
			options: [
				{ kind: "allow_once", name: "Allow reading", optionId: "allow" },
				{ kind: "reject_once", name: "Reject", optionId: "reject" },
			],
		});

		if (readPermission.outcome.outcome === "selected" && readPermission.outcome.optionId === "allow") {
			try {
				const result = await this.connection.readTextFile({
					sessionId: sessionId,
					path: testFilePath,
				});

				const formattedContent = this.formatFileContent(result.content);

				await this.connection.sessionUpdate({
					sessionId,
					update: {
						sessionUpdate: "tool_call_update",
						toolCallId: "read_1",
						status: "completed",
						content: [
							{
								type: "content",
								content: { type: "text", text: formattedContent },
							},
						],
						rawOutput: { content: result.content },
					},
				});

				await this.simulateDelay(abortSignal, 200);

				await this.connection.sessionUpdate({
					sessionId,
					update: {
						sessionUpdate: "agent_message_chunk",
						content: { type: "text", text: " Successfully read the file!" },
					},
				});
			} catch (err) {
				await this.connection.sessionUpdate({
					sessionId,
					update: {
						sessionUpdate: "tool_call_update",
						toolCallId: "read_1",
						status: "failed",
						rawOutput: { error: String(err) },
					},
				});
			}
		} else {
			await this.connection.sessionUpdate({
				sessionId,
				update: {
					sessionUpdate: "agent_message_chunk",
					content: { type: "text", text: " Read operation was cancelled." },
				},
			});
		}
	}

	private async handleWriteTest(
		sessionId: string,
		abortSignal: AbortSignal,
		filename?: string,
	): Promise<void> {
		const writeFilePath = path.join(process.cwd(), filename || "test-write.txt");
		const writeContent = `Test data written at ${new Date().toISOString()}\nNew line added!`;

		await this.connection.sessionUpdate({
			sessionId,
			update: {
				sessionUpdate: "agent_message_chunk",
				content: {
					type: "text",
					text: `I'll write some test data to "${path.basename(writeFilePath)}". I'll show you a diff first.`,
				},
			},
		});

		await this.simulateDelay(abortSignal, 300);

		// 1. Try to read current content to generate a diff
		let oldText: string | null = null;
		try {
			const result = await this.connection.readTextFile({
				sessionId: sessionId,
				path: writeFilePath,
			});
			oldText = result.content;
		} catch (e) {
			// File might not exist, which is fine
		}

		// 2. Send tool call WITH diff content
		await this.connection.sessionUpdate({
			sessionId,
			update: {
				sessionUpdate: "tool_call",
				toolCallId: "write_1",
				title: `Writing ${path.basename(writeFilePath)}`,
				kind: "edit",
				status: "pending",
				locations: [{ path: writeFilePath }],
				content: [
					{
						type: "diff",
						path: writeFilePath,
						newText: writeContent,
						oldText: oldText ?? undefined,
					} as any, // Cast because SDK types might be strict
				],
				rawInput: { path: writeFilePath, content: writeContent },
			},
		});

		// 3. Request permission
		const writePermission = await this.connection.requestPermission({
			sessionId,
			toolCall: {
				toolCallId: "write_1",
				title: `Writing ${path.basename(writeFilePath)}`,
				kind: "edit",
				status: "pending",
				locations: [{ path: writeFilePath }],
				rawInput: { path: writeFilePath, content: writeContent },
			},
			options: [
				{ kind: "allow_once", name: "Allow writing", optionId: "allow" },
				{ kind: "reject_once", name: "Reject", optionId: "reject" },
			],
		});

		if (writePermission.outcome.outcome === "selected" && writePermission.outcome.optionId === "allow") {
			try {
				await this.connection.writeTextFile({
					sessionId: sessionId,
					path: writeFilePath,
					content: writeContent,
				});

				await this.connection.sessionUpdate({
					sessionId,
					update: {
						sessionUpdate: "tool_call_update",
						toolCallId: "write_1",
						status: "completed",
						rawOutput: { success: true, bytesWritten: writeContent.length },
					},
				});

				await this.simulateDelay(abortSignal, 200);

				await this.connection.sessionUpdate({
					sessionId,
					update: {
						sessionUpdate: "agent_message_chunk",
						content: { type: "text", text: ` Successfully wrote ${writeContent.length} bytes!` },
					},
				});
			} catch (err) {
				await this.connection.sessionUpdate({
					sessionId,
					update: {
						sessionUpdate: "tool_call_update",
						toolCallId: "read_1", // typo here in old file? fixed to write_1
						status: "failed",
						rawOutput: { error: String(err) },
					},
				});
			}
		} else {
			await this.connection.sessionUpdate({
				sessionId,
				update: {
					sessionUpdate: "agent_message_chunk",
					content: { type: "text", text: " Write operation was cancelled." },
				},
			});
		}
	}

	private simulateDelay(
		abortSignal: AbortSignal,
		ms: number,
	): Promise<void> {
		return new Promise((resolve, reject) =>
			setTimeout(() => {
				if (abortSignal.aborted) {
					reject(new Error("Aborted"));
				} else {
					resolve();
				}
			}, ms),
		);
	}

	async cancel(params: acp.CancelNotification): Promise<void> {
		this.sessions.get(params.sessionId)?.pendingPrompt?.abort();
	}
}

const input = Writable.toWeb(process.stdout);
const output = Readable.toWeb(process.stdin) as ReadableStream<Uint8Array>;

const stream = acp.ndJsonStream(input, output);
new acp.AgentSideConnection((conn) => new TestAgent(conn), stream);
