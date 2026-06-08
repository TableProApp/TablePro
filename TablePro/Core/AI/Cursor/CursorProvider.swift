//
//  CursorProvider.swift
//  TablePro
//

import Foundation
import os

final class CursorProvider: ChatTransport {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CursorProvider")

    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(apiKey: String, model: String, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func streamChat(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let run = try await launchAgent(turns: turns, options: options)
                    let request = try streamRequest(run: run)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AIProviderError.networkError("Invalid response")
                    }
                    guard httpResponse.statusCode == 200 else {
                        let body = try await AIProvider.collectErrorBody(from: bytes)
                        throw AIProviderError.mapHTTPError(statusCode: httpResponse.statusCode, body: body)
                    }

                    var parser = StreamParser()
                    events: for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        switch parser.consume(line) {
                        case .text(let text):
                            continuation.yield(.textDelta(text))
                        case .done:
                            break events
                        case nil:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func fetchAvailableModels() async throws -> [String] {
        var request = URLRequest(url: try Self.url("/v1/models"))
        request.timeoutInterval = AIProvider.modelListTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.warning("Cursor model fetch failed: \(error.localizedDescription, privacy: .public)")
            throw AIProviderError.networkError("Failed to fetch models")
        }
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]]
        else {
            throw AIProviderError.networkError("Failed to fetch models")
        }
        let fetched = items.compactMap { $0["id"] as? String }
        let curated = Set(CursorAI.curatedModelIDs)
        return CursorAI.curatedModelIDs + fetched.filter { !curated.contains($0) }.sorted()
    }

    func testConnection() async throws -> Bool {
        var request = URLRequest(url: try Self.url("/v1/models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        if httpResponse.statusCode == 200 {
            return true
        }
        if httpResponse.statusCode == 401 {
            throw AIProviderError.authenticationFailed("")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        throw AIProviderError.mapHTTPError(statusCode: httpResponse.statusCode, body: body)
    }

    private func launchAgent(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) async throws -> (agentID: String, runID: String) {
        var request = URLRequest(url: try Self.url("/v1/agents"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body = Self.launchBody(prompt: Self.renderPrompt(turns: turns, options: options), model: model)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError("Invalid response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AIProviderError.mapHTTPError(
                statusCode: httpResponse.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agent = json["agent"] as? [String: Any],
              let agentID = agent["id"] as? String,
              let run = json["run"] as? [String: Any],
              let runID = run["id"] as? String
        else {
            throw AIProviderError.networkError("Cursor did not return an agent run")
        }
        return (agentID, runID)
    }

    private func streamRequest(run: (agentID: String, runID: String)) throws -> URLRequest {
        var request = URLRequest(url: try Self.url("/v1/agents/\(run.agentID)/runs/\(run.runID)/stream"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }

    static func renderPrompt(turns: [ChatTurnWire], options: ChatTransportOptions) -> String {
        var sections: [String] = []
        if let systemPrompt = options.systemPrompt, !systemPrompt.isEmpty {
            sections.append(systemPrompt)
        }
        for turn in turns {
            let text = turnText(turn)
            guard !text.isEmpty else { continue }
            switch turn.role {
            case .user:
                sections.append("User: \(text)")
            case .assistant:
                sections.append("Assistant: \(text)")
            case .system:
                sections.append(text)
            }
        }
        return sections.joined(separator: "\n\n")
    }

    static func launchBody(prompt: String, model: String) -> [String: Any] {
        var body: [String: Any] = ["prompt": ["text": prompt]]
        if !model.isEmpty {
            body["model"] = ["id": model]
        }
        return body
    }

    private static func turnText(_ turn: ChatTurnWire) -> String {
        var parts: [String] = []
        for block in turn.blocks {
            switch block.kind {
            case .text(let text):
                if !text.isEmpty { parts.append(text) }
            case .toolResult(let result):
                if !result.content.isEmpty { parts.append("Result: \(result.content)") }
            case .toolUse, .attachment, .reasoning, .image:
                continue
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func url(_ path: String) throws -> URL {
        guard let url = URL(string: CursorAI.baseURL + path) else {
            throw AIProviderError.invalidEndpoint(CursorAI.baseURL)
        }
        return url
    }

    private static func sseField(_ line: String, _ name: String) -> String? {
        let prefix = "\(name):"
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func decodeJSON(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    struct StreamParser {
        enum Output: Equatable {
            case text(String)
            case done
        }

        private var event = ""
        private var emittedText = false

        mutating func consume(_ line: String) -> Output? {
            if line.isEmpty {
                event = ""
                return nil
            }
            if let name = CursorProvider.sseField(line, "event") {
                event = name
                return nil
            }
            guard let payload = CursorProvider.sseField(line, "data"),
                  let json = CursorProvider.decodeJSON(payload) else {
                return nil
            }
            switch event {
            case "assistant":
                guard let text = json["text"] as? String, !text.isEmpty else { return nil }
                emittedText = true
                return .text(text)
            case "result":
                guard !emittedText, let text = json["text"] as? String, !text.isEmpty else { return nil }
                return .text(text)
            case "done":
                return .done
            default:
                return nil
            }
        }
    }
}
