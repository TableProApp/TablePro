//
//  InlineSuggestionSource.swift
//  TablePro
//

import Foundation

struct SuggestionContext: Sendable {
    let textBefore: String
    let fullText: String
    let cursorOffset: Int
    let cursorLine: Int
    let cursorCharacter: Int
}

struct InlineSuggestion: Sendable, Identifiable {
    let id: UUID
    let text: String
    let replacementRange: NSRange?
    let replacementText: String

    init(
        id: UUID = UUID(),
        text: String,
        replacementRange: NSRange? = nil,
        replacementText: String
    ) {
        self.id = id
        self.text = text
        self.replacementRange = replacementRange
        self.replacementText = replacementText
    }
}

@MainActor
protocol InlineSuggestionSource: AnyObject {
    var sourceIdentity: ObjectIdentifier { get }
    var isAvailable: Bool { get }
    func requestSuggestion(context: SuggestionContext) async throws -> InlineSuggestion?
    func didShowSuggestion(_ suggestion: InlineSuggestion)
    func didAcceptSuggestion(_ suggestion: InlineSuggestion)
    func didDismissSuggestion(_ suggestion: InlineSuggestion)
}

extension InlineSuggestionSource {
    var sourceIdentity: ObjectIdentifier { ObjectIdentifier(self) }
    func didShowSuggestion(_ suggestion: InlineSuggestion) {}
    func didAcceptSuggestion(_ suggestion: InlineSuggestion) {}
    func didDismissSuggestion(_ suggestion: InlineSuggestion) {}
}
