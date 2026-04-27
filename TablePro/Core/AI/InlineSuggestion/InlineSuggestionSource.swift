//
//  InlineSuggestionSource.swift
//  TablePro
//

import Foundation

/// Context passed to an inline suggestion source
struct SuggestionContext: Sendable {
    let textBefore: String
    let fullText: String
    let cursorOffset: Int
    let cursorLine: Int
    let cursorCharacter: Int
}

/// A completed inline suggestion
struct InlineSuggestion: Sendable {
    /// Text to show as ghost text (only the part after the cursor)
    let text: String
    /// Range to replace on accept (nil = insert at cursor)
    let replacementRange: NSRange?
    /// Full text to insert when accepted (replaces range)
    let replacementText: String
    let acceptCommand: LSPCommand?
}

/// Protocol for inline suggestion sources
@MainActor
protocol InlineSuggestionSource: AnyObject {
    var isAvailable: Bool { get }
    func requestSuggestion(context: SuggestionContext) async throws -> InlineSuggestion?
    func didShowSuggestion(_ suggestion: InlineSuggestion)
    func didAcceptSuggestion(_ suggestion: InlineSuggestion)
    func didDismissSuggestion(_ suggestion: InlineSuggestion)
}

extension InlineSuggestionSource {
    func didShowSuggestion(_ suggestion: InlineSuggestion) {}
    func didAcceptSuggestion(_ suggestion: InlineSuggestion) {}
    func didDismissSuggestion(_ suggestion: InlineSuggestion) {}
}
