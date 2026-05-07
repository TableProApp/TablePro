//
//  InlineAssistantSession.swift
//  TablePro
//

import Foundation
import os

@Observable
@MainActor
final class InlineAssistantSession {
    private static let logger = Logger(subsystem: "com.TablePro", category: "InlineAssistantSession")

    enum Phase: Equatable {
        case idle
        case streaming
        case ready
        case failed(message: String)
    }

    let originalText: String
    let fullQuery: String
    let databaseType: DatabaseType?

    private(set) var prompt: String = ""
    private(set) var proposedText: String = ""
    private(set) var phase: Phase = .idle

    private weak var schemaProvider: SQLSchemaProvider?
    private var task: Task<Void, Never>?

    init(
        originalText: String,
        fullQuery: String,
        databaseType: DatabaseType?,
        schemaProvider: SQLSchemaProvider?
    ) {
        self.originalText = originalText
        self.fullQuery = fullQuery
        self.databaseType = databaseType
        self.schemaProvider = schemaProvider
    }

    var hasResponse: Bool { !proposedText.isEmpty }

    var isStreaming: Bool {
        if case .streaming = phase { return true }
        return false
    }

    var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming
    }

    func updatePrompt(_ value: String) {
        prompt = value
    }

    func start() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isStreaming else { return }

        let settings = AppSettingsManager.shared.ai
        guard let resolved = AIProviderFactory.resolve(settings: settings) else {
            phase = .failed(message: String(localized: "Configure an AI provider in Settings to use the inline assistant."))
            return
        }

        proposedText = ""
        phase = .streaming

        let language = languageTag()
        let original = originalText
        let full = fullQuery
        let schemaProvider = schemaProvider

        task?.cancel()
        task = Task { @MainActor [weak self] in
            let systemPrompt = await Self.buildSystemPrompt(
                language: language,
                settings: settings,
                schemaProvider: schemaProvider
            )
            let userMessage = AIPromptTemplates.rewriteSelection(
                instruction: trimmed,
                selection: original,
                fullQuery: full
            )
            let turns = [ChatTurn(role: .user, blocks: [.text(userMessage)])]

            var accumulated = ""
            do {
                let stream = resolved.provider.streamChat(
                    turns: turns,
                    options: ChatTransportOptions(model: resolved.model, systemPrompt: systemPrompt)
                )
                for try await event in stream {
                    if Task.isCancelled { return }
                    if case .textDelta(let token) = event {
                        accumulated += token
                        guard let self else { return }
                        self.proposedText = Self.cleanResponse(accumulated)
                    }
                }
            } catch {
                if Task.isCancelled { return }
                guard let self else { return }
                Self.logger.error("Inline assistant stream failed: \(error.localizedDescription, privacy: .public)")
                self.phase = .failed(message: error.localizedDescription)
                return
            }

            guard let self, !Task.isCancelled else { return }
            let final = Self.cleanResponse(accumulated)
            self.proposedText = final
            self.phase = final.isEmpty ? .failed(message: String(localized: "The model returned an empty response.")) : .ready
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isStreaming {
            phase = proposedText.isEmpty ? .idle : .ready
        }
    }

    func teardown() {
        task?.cancel()
        task = nil
    }

    // MARK: - Helpers

    private func languageTag() -> String {
        guard let databaseType else { return "SQL" }
        return PluginManager.shared.queryLanguageName(for: databaseType)
    }

    private static func buildSystemPrompt(
        language: String,
        settings: AISettings,
        schemaProvider: SQLSchemaProvider?
    ) async -> String {
        guard settings.includeSchema, let provider = schemaProvider else {
            return AIPromptTemplates.rewriteSelectionSystemPrompt(language: language)
        }
        let context = await provider.buildSchemaContextForAI(settings: settings)
        if let context, !context.isEmpty {
            return AIPromptTemplates.rewriteSelectionSystemPrompt(language: language, schemaContext: context)
        }
        return AIPromptTemplates.rewriteSelectionSystemPrompt(language: language)
    }

    private static let fenceRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^\\s*```[a-zA-Z0-9_+-]*\\s*\\n?|\\n?```\\s*$",
        options: []
    )

    private static let thinkingRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<think>.*?</think>|<think>.*$",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static func cleanResponse(_ raw: String) -> String {
        var result = raw
        if let regex = thinkingRegex {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: ""
            )
        }
        if let regex = fenceRegex {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: ""
            )
        }
        while result.first?.isNewline == true {
            result.removeFirst()
        }
        while result.last?.isWhitespace == true {
            result.removeLast()
        }
        return result
    }
}
