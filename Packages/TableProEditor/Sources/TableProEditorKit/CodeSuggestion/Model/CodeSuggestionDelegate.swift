//
//  CodeSuggestionDelegate.swift
//  TableProEditorKit
//
//  Created by Abe Malla on 12/26/24.
//

@MainActor
public protocol CodeSuggestionDelegate: AnyObject {
    func completionTriggerCharacters() -> Set<String>

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool
    ) async -> CodeSuggestionResponse?

    // This can't be async, we need it to be snappy. At most, it should just be filtering completion items
    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]?

    // Optional
    func completionWindowDidClose()

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    )
    // Optional
    func completionWindowDidSelect(item: CodeSuggestionEntry)
}

public extension CodeSuggestionDelegate {
    func completionTriggerCharacters() -> Set<String> { [] }
    func completionWindowDidClose() { }
    func completionWindowDidSelect(item: CodeSuggestionEntry) { }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool
    ) async -> CodeSuggestionResponse? {
        await completionSuggestionsRequested(textView: textView, cursorPosition: cursorPosition)
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> CodeSuggestionResponse? {
        nil
    }
}
