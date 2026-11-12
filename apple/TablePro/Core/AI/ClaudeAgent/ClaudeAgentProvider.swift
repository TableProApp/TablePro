//
//  ClaudeAgentProvider.swift
//  TablePro
//

import Foundation
import os

final class ClaudeAgentProvider: ChatTransport {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ClaudeAgentProvider")

    private let model: String
    private let cli: ClaudeAgentCLI
    private let toolBridge: ClaudeAgentMCPBridging

    init(
        model: String,
        cli: ClaudeAgentCLI = ClaudeAgentCLI(),
        toolBridge: ClaudeAgentMCPBridging = ClaudeAgentMCPBridge()
    ) {
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cli = cli
        self.toolBridge = toolBridge
    }

    func streamChat(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var grant: ClaudeAgentToolGrant?
                do {
                    grant = await toolBridge.makeGrant(connectionId: options.connectionId)
                    let prompt = AgentPromptRenderer.renderPrompt(turns: turns, includingSystemPrompt: nil)
                    let lines = try cli.streamLines(
                        arguments: Self.inferenceArguments(
                            prompt: prompt,
                            model: model,
                            systemPrompt: options.systemPrompt ?? ClaudeAgent.systemPrompt,
                            mcpConfigPath: grant?.configPath
                        ),
                        currentDirectory: FileManager.default.temporaryDirectory
                    )

                    for try await line in lines {
                        if Task.isCancelled { break }
                        guard let event = Self.decodeEvent(line) else { continue }
                        switch event {
                        case .text(let text):
                            continuation.yield(.textDelta(text))
                        case .usage(let usage):
                            continuation.yield(.usage(usage))
                        case .outputLimit(let limit):
                            continuation.yield(.outputLimitReached(limit))
                        case .failure(let message):
                            await toolBridge.release(grant)
                            grant = nil
                            continuation.finish(throwing: AIProviderError.authenticationFailed(message))
                            return
                        }
                    }
                    await toolBridge.release(grant)
                    grant = nil
                    continuation.finish()
                } catch {
                    await toolBridge.release(grant)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func fetchAvailableModels() async throws -> [AIModelInfo] {
        ClaudeAgent.curatedModels.map { AIModelInfo(id: $0.id, displayName: $0.displayName) }
    }

    func testConnection() async throws -> Bool {
        let status = try await cli.authStatus()
        guard status.loggedIn else {
            throw AIProviderError.authenticationFailed(
                String(localized: "Not signed in to Claude. Run \"claude /login\" in Terminal, then try again.")
            )
        }
        return true
    }

    enum DecodedEvent: Equatable {
        case text(String)
        case usage(AITokenUsage)
        case outputLimit(ChatOutputLimit)
        case failure(String)
    }

    static func inferenceArguments(
        prompt: String,
        model: String,
        systemPrompt: String?,
        mcpConfigPath: String?
    ) -> [String] {
        var arguments = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--setting-sources", "",
            "--tools", ""
        ]

        if let mcpConfigPath {
            arguments += ["--mcp-config", mcpConfigPath, "--allowedTools", "mcp__\(ClaudeAgent.mcpServerName)__*"]
        }
        arguments.append("--strict-mcp-config")

        if let systemPrompt, !systemPrompt.isEmpty {
            arguments += ["--system-prompt", systemPrompt]
        }
        if !model.isEmpty {
            arguments += ["--model", model]
        }
        arguments += ["--", prompt]
        return arguments
    }

    static func decodeEvent(_ line: String) -> DecodedEvent? {
        guard let json = decodeJSON(line), let type = json["type"] as? String else { return nil }
        switch type {
        case "stream_event":
            if let limit = outputLimit(json) { return .outputLimit(limit) }
            guard let text = partialText(json) else { return nil }
            return .text(text)
        case "result":
            return resultEvent(json)
        default:
            return nil
        }
    }

    static func partialText(_ json: [String: Any]) -> String? {
        guard let event = json["event"] as? [String: Any],
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String,
              !text.isEmpty else {
            return nil
        }
        return text
    }

    // The CLI passes the Messages API stream through, so a cut response ends with its message_delta stop reason.
    static func outputLimit(_ json: [String: Any]) -> ChatOutputLimit? {
        guard let event = json["event"] as? [String: Any],
              event["type"] as? String == "message_delta",
              let delta = event["delta"] as? [String: Any] else { return nil }
        switch delta["stop_reason"] as? String {
        case "max_tokens": return .outputTokens
        case "model_context_window_exceeded": return .contextWindow
        default: return nil
        }
    }

    static func resultEvent(_ json: [String: Any]) -> DecodedEvent? {
        if json["is_error"] as? Bool == true {
            let message = (json["result"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "Claude Code reported an error.")
            return .failure(message)
        }
        guard let usage = json["usage"] as? [String: Any] else { return nil }
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        guard input > 0 || output > 0 else { return nil }
        return .usage(AITokenUsage(inputTokens: input, outputTokens: output))
    }

    private static func decodeJSON(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
