//
//  CopilotInlineSource.swift
//  TablePro
//

import Foundation
import os

@MainActor
final class CopilotInlineSource: InlineSuggestionSource {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CopilotInlineSource")

    private let documentSync: CopilotDocumentSync
    private var pendingCommands: [UUID: LSPCommand] = [:]

    init(documentSync: CopilotDocumentSync) {
        self.documentSync = documentSync
    }

    var isAvailable: Bool {
        CopilotService.shared.status == .running && CopilotService.shared.isAuthenticated
    }

    func requestSuggestion(context: SuggestionContext) async throws -> InlineSuggestion? {
        guard let client = CopilotService.shared.client else { return nil }
        guard let docInfo = documentSync.currentDocumentInfo() else { return nil }

        let editorSettings = AppSettingsManager.shared.editor
        let preambleOffset = documentSync.preambleBuilder.preambleLineCount
        let params = LSPInlineCompletionParams(
            textDocument: LSPVersionedTextDocumentIdentifier(uri: docInfo.uri, version: docInfo.version),
            position: LSPPosition(line: context.cursorLine + preambleOffset, character: context.cursorCharacter),
            context: LSPInlineCompletionContext(triggerKind: 2),
            formattingOptions: LSPFormattingOptions(
                tabSize: editorSettings.clampedTabWidth,
                insertSpaces: true
            )
        )

        let result = try await client.inlineCompletion(params: params)
        guard let first = result.items.first, !first.insertText.isEmpty else { return nil }

        let ghostText: String
        var replacementRange: NSRange?

        if let range = first.range {
            let adjustedStart = LSPPosition(line: range.start.line - preambleOffset, character: range.start.character)
            let adjustedEnd = LSPPosition(line: range.end.line - preambleOffset, character: range.end.character)
            let nsText = context.fullText as NSString
            let rangeStartOffset = Self.offsetForPosition(adjustedStart, in: nsText)
            let rangeEndOffset = Self.offsetForPosition(adjustedEnd, in: nsText)
            let rangeLength = rangeEndOffset - rangeStartOffset

            if rangeLength >= 0, rangeStartOffset >= 0, rangeStartOffset + rangeLength <= nsText.length {
                let existingLen = context.cursorOffset - rangeStartOffset
                if existingLen > 0, existingLen <= (first.insertText as NSString).length {
                    ghostText = (first.insertText as NSString).substring(from: existingLen)
                } else {
                    ghostText = first.insertText
                }
                replacementRange = NSRange(location: rangeStartOffset, length: rangeLength)
            } else {
                ghostText = first.insertText
            }
        } else {
            ghostText = first.insertText
        }

        guard !ghostText.isEmpty else { return nil }

        let suggestion = InlineSuggestion(
            text: ghostText,
            replacementRange: replacementRange,
            replacementText: first.insertText
        )

        if let command = first.command {
            pendingCommands[suggestion.id] = command
        }

        return suggestion
    }

    func didAcceptSuggestion(_ suggestion: InlineSuggestion) {
        guard let command = pendingCommands.removeValue(forKey: suggestion.id) else { return }
        Task {
            guard let client = CopilotService.shared.client else { return }
            try? await client.executeCommand(command: command.command, arguments: command.arguments)
        }
    }

    func didDismissSuggestion(_ suggestion: InlineSuggestion) {
        pendingCommands.removeValue(forKey: suggestion.id)
    }

    // MARK: - Private

    private static func offsetForPosition(_ position: LSPPosition, in text: NSString) -> Int {
        var offset = 0
        var line = 0
        let length = text.length

        while offset < length, line < position.line {
            if text.character(at: offset) == 0x0A {
                line += 1
            }
            offset += 1
        }
        return min(offset + position.character, length)
    }
}
