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

enum InlineSuggestionText {
    private static let thinkingRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<think>.*?</think>|<think>.*$",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    // Leading spaces stay: a completion that starts a new token needs the one before it.
    static func clean(_ raw: String) -> String {
        var result = raw
        if let regex = thinkingRegex {
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
