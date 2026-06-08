//
//  AppleIntelligenceTransport.swift
//  TablePro
//

import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, *)
final class AppleIntelligenceTransport: ChatTransport {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AppleIntelligenceTransport")

    func fetchAvailableModels() async throws -> [String] {
        [AIProviderType.appleIntelligenceModelID]
    }

    func testConnection() async throws -> Bool {
        AppleIntelligenceAvailability.currentStatus() == .available
    }

    func streamChat(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.run(turns: turns, options: options, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        turns: [ChatTurnWire],
        options: ChatTransportOptions,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        guard AppleIntelligenceAvailability.currentStatus() == .available else {
            throw AIProviderError.streamingFailed(String(localized: "Apple Intelligence is not available."))
        }

        let tools = try options.tools.map { spec -> AppleIntelligenceTool in
            let schema = try AppleIntelligenceSchemaBuilder.buildGenerationSchema(from: spec)
            return AppleIntelligenceTool(spec: spec, schema: schema) { spec, content in
                await Self.invokeTool(spec: spec, content: content, continuation: continuation)
            }
        }

        let history = Array(turns.dropLast())
        let promptText = turns.last?.plainText ?? ""
        let transcript = Self.buildTranscript(systemPrompt: options.systemPrompt, history: history, tools: tools)

        let session = LanguageModelSession(model: .default, tools: tools, transcript: transcript)
        var generationOptions = GenerationOptions()
        if let temperature = options.temperature {
            generationOptions.temperature = temperature
        }
        if let maxTokens = options.maxOutputTokens {
            generationOptions.maximumResponseTokens = maxTokens
        }

        var previous = ""
        let responseStream = session.streamResponse(options: generationOptions) { promptText }
        for try await snapshot in responseStream {
            if Task.isCancelled { break }
            let current = snapshot.content
            if current.hasPrefix(previous) {
                let delta = String(current.dropFirst(previous.count))
                if !delta.isEmpty {
                    continuation.yield(.textDelta(delta))
                }
            } else {
                continuation.yield(.textDelta(current))
            }
            previous = current
        }
    }

    static func buildTranscript(
        systemPrompt: String?,
        history: [ChatTurnWire],
        tools: [AppleIntelligenceTool]
    ) -> Transcript {
        var entries: [Transcript.Entry] = []
        let instructionText = (systemPrompt?.isEmpty == false) ? systemPrompt : nil
        if instructionText != nil || !tools.isEmpty {
            var segments: [Transcript.Segment] = []
            if let instructionText {
                segments.append(.text(Transcript.TextSegment(id: UUID().uuidString, content: instructionText)))
            }
            entries.append(.instructions(Transcript.Instructions(
                id: UUID().uuidString,
                segments: segments,
                toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }
            )))
        }
        for turn in history {
            let text = turn.plainText
            guard !text.isEmpty else { continue }
            let segment = Transcript.Segment.text(Transcript.TextSegment(id: UUID().uuidString, content: text))
            switch turn.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(
                    id: UUID().uuidString,
                    segments: [segment],
                    options: GenerationOptions(),
                    responseFormat: nil
                )))
            case .assistant:
                entries.append(.response(Transcript.Response(
                    id: UUID().uuidString,
                    assetIDs: [],
                    segments: [segment]
                )))
            case .system:
                continue
            }
        }
        return Transcript(entries: entries)
    }

    private static func invokeTool(
        spec: ChatToolSpec,
        content: GeneratedContent,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async -> String {
        let input: JsonValue
        do {
            input = try AppleIntelligenceSchemaBuilder.generatedContentToJsonValue(content)
        } catch {
            logger.error("Tool argument decoding failed for \(spec.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return String(localized: "Could not read tool arguments.")
        }
        let block = ToolUseBlock(id: UUID().uuidString, name: spec.name, input: input, approvalState: .pending)
        return await withCheckedContinuation { (reply: CheckedContinuation<String, Never>) in
            let token = ToolReplyToken { result in
                reply.resume(returning: result.isError ? "Error: \(result.content)" : result.content)
            }
            continuation.yield(.toolInvocationRequest(block: block, replyToken: token))
        }
    }

    static func mapError(_ error: Error) -> Error {
        if error is CancellationError {
            return error
        }
        if let toolCallError = error as? LanguageModelSession.ToolCallError {
            return mapError(toolCallError.underlyingError)
        }
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize:
                return AIProviderError.streamingFailed(
                    String(localized: "This conversation is too long for the on-device model. Start a new chat.")
                )
            case .guardrailViolation:
                return AIProviderError.streamingFailed(
                    String(localized: "The request was blocked by on-device safety.")
                )
            case .rateLimited:
                return AIProviderError.rateLimited
            default:
                break
            }
        }
        logger.error("Apple Intelligence failed: \(String(reflecting: type(of: error)), privacy: .public) \(diagnostic(for: error), privacy: .public)")
        let message = String(localized: "Apple Intelligence couldn't finish this request. Try again or start a new chat for long tool conversations.")
        return AIProviderError.streamingFailed(message)
    }

    static func diagnostic(for error: Error) -> String {
        let nsError = error as NSError
        var parts = ["\(nsError.domain) code=\(nsError.code)"]
        var underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        while let current = underlying {
            parts.append("← \(current.domain) code=\(current.code)")
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " ")
    }
}
#endif
