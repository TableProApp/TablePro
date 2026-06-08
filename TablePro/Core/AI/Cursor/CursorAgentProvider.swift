//
//  CursorAgentProvider.swift
//  TablePro
//

import Foundation
import os

final class CursorAgentProvider: ChatTransport {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CursorAgentProvider")

    private let model: String
    private let cli: CursorAgentCLI

    init(model: String, cli: CursorAgentCLI = CursorAgentCLI()) {
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cli = cli
    }

    func streamChat(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let workspace = Self.makeWorkspace()
            let prompt = CursorProvider.renderPrompt(turns: turns, options: options)
            let lines = cli.stream(Self.inferenceArguments(prompt: prompt, model: model, workspace: workspace?.path))

            let task = Task {
                do {
                    for try await line in lines {
                        if Task.isCancelled { break }
                        guard let json = Self.decodeJSON(line),
                              let text = Self.incrementalText(json) else { continue }
                        continuation.yield(.textDelta(text))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                Self.removeWorkspace(workspace)
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func fetchAvailableModels() async throws -> [String] {
        CursorAI.curatedModelIDs
    }

    func testConnection() async throws -> Bool {
        let result = try await cli.run(["status"])
        if result.code == 0 { return true }
        throw AIProviderError.authenticationFailed(String(localized: "Not signed in to Cursor. Sign in first."))
    }

    static func inferenceArguments(prompt: String, model: String, workspace: String?) -> [String] {
        var arguments = ["-p", "--output-format", "stream-json", "--stream-partial-output", "--trust"]
        if let workspace {
            arguments += ["--workspace", workspace]
        }
        if !model.isEmpty {
            arguments += ["--model", model]
        }
        arguments += ["--", prompt]
        return arguments
    }

    static func incrementalText(_ json: [String: Any]) -> String? {
        guard json["type"] as? String == "assistant",
              json["timestamp_ms"] != nil,
              let text = assistantText(json), !text.isEmpty else {
            return nil
        }
        return text
    }

    static func assistantText(_ json: [String: Any]) -> String? {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            return nil
        }
        return text
    }

    private static func decodeJSON(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func makeWorkspace() -> URL? {
        let url = FileManager.default.temporaryDirectory.appending(path: "cursor-agent-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func removeWorkspace(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
