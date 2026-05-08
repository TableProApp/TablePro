//
//  AIChatInlineSource.swift
//  TablePro
//

import Foundation
import os

@MainActor
final class AIChatInlineSource: InlineSuggestionSource {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AIChatInlineSource")

    private weak var schemaProvider: SQLSchemaProvider?
    var connectionPolicy: AIConnectionPolicy?

    init(schemaProvider: SQLSchemaProvider?, connectionPolicy: AIConnectionPolicy?) {
        self.schemaProvider = schemaProvider
        self.connectionPolicy = connectionPolicy
    }

    var isAvailable: Bool {
        let settings = AppSettingsManager.shared.ai
        guard settings.enabled, settings.hasActiveProvider else { return false }
        if connectionPolicy == .never { return false }
        return true
    }

    func requestSuggestion(context: SuggestionContext) async throws -> InlineSuggestion? {
        let settings = AppSettingsManager.shared.ai

        guard let resolved = AIProviderFactory.resolve(settings: settings) else {
            return nil
        }

        let userMessage = AIPromptTemplates.inlineSuggest(textBefore: context.textBefore, fullQuery: context.fullText)
        let turns = [
            ChatTurn(role: .user, blocks: [.text(userMessage)])
        ]

        let systemPrompt = await buildSystemPrompt()

        var accumulated = ""
        let stream = resolved.provider.streamChat(
            turns: turns,
            options: ChatTransportOptions(model: resolved.model, systemPrompt: systemPrompt)
        )

        for try await event in stream {
            if case .textDelta(let token) = event {
                accumulated += token
            }
        }

        let cleaned = cleanSuggestion(accumulated)
        guard !cleaned.isEmpty else { return nil }

        return InlineSuggestion(
            text: cleaned,
            replacementRange: nil,
            replacementText: cleaned
        )
    }

    // MARK: - Private

    private func buildSystemPrompt() async -> String {
        let settings = AppSettingsManager.shared.ai

        guard settings.includeSchema,
              let provider = schemaProvider else {
            return AIPromptTemplates.inlineSuggestSystemPrompt()
        }

        let schemaContext = await provider.buildSchemaContextForAI(settings: settings)

        if let schemaContext, !schemaContext.isEmpty {
            return AIPromptTemplates.inlineSuggestSystemPrompt(schemaContext: schemaContext)
        }
        return AIPromptTemplates.inlineSuggestSystemPrompt()
    }

    /// Clean the AI suggestion: strip thinking blocks, leading newlines,
    /// and trailing whitespace, but preserve leading spaces.
    private func cleanSuggestion(_ raw: String) -> String {
        var result = raw

        result = stripThinkingBlocks(result)

        // Strip leading newlines only (preserve leading spaces)
        while result.first?.isNewline == true {
            result.removeFirst()
        }
        // Strip trailing whitespace and newlines
        while result.last?.isWhitespace == true {
            result.removeLast()
        }
        return result
    }

    private static let thinkingRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<think>.*?</think>|<think>.*$",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// Remove `<think>...</think>` blocks (case-insensitive) from AI output.
    /// Handles partial/unclosed tags too.
    private func stripThinkingBlocks(_ text: String) -> String {
        guard let regex = Self.thinkingRegex else { return text }

        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: ""
        )
    }
}
