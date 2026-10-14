import Foundation

public enum SQLCompletionInsertion {
    public struct Resolution: Sendable {
        public let text: String
        public let cursorOffset: Int  // UTF-16 units from the insertion start
    }

    public static func resolve(for item: SQLCompletionItem) -> Resolution {
        if item.kind == .favorite, let expansion = SQLSnippetMarker.expand(item.insertText) {
            return Resolution(text: expansion.text, cursorOffset: expansion.cursorOffset)
        }
        let length = (item.insertText as NSString).length
        let cursorOffset = item.insertText.hasSuffix("()") ? length - 1 : length
        return Resolution(text: item.insertText, cursorOffset: cursorOffset)
    }
}
