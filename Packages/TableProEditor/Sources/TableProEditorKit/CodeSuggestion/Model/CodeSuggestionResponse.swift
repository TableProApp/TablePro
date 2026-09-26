import Foundation

public struct CodeSuggestionResponse {
    public let items: [CodeSuggestionEntry]
    public let windowPosition: CursorPosition
    public let prefix: CodeSuggestionPrefix

    public init(items: [CodeSuggestionEntry], windowPosition: CursorPosition, prefix: CodeSuggestionPrefix) {
        self.items = items
        self.windowPosition = windowPosition
        self.prefix = prefix
    }
}

public struct CodeSuggestionPrefix: Equatable, Sendable {
    public let range: NSRange
    public let text: String

    public init(range: NSRange, text: String) {
        self.range = range
        self.text = text
    }
}

internal extension CodeSuggestionPrefix {
    @MainActor
    func isCurrent(at cursor: CursorPosition, in textView: TextViewController) -> Bool {
        guard range.location != NSNotFound,
              cursor.range == NSRange(location: range.upperBound, length: 0),
              let storage = textView.textView.textStorage,
              range.upperBound <= storage.length else {
            return false
        }
        return storage.mutableString.substring(with: range) == text
    }
}
