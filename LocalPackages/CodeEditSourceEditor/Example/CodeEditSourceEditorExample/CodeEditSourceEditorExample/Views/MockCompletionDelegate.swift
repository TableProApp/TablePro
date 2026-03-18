//
//  MockCompletionDelegate.swift
//  CodeEditSourceEditorExample
//
//  Created by Khan Winter on 7/22/25.
//

import SwiftUI
import CodeEditSourceEditor
import CodeEditTextView

private let text = [
    "Lorem",
    "ipsum",
    "dolor",
    "sit",
    "amet,",
    "consectetur",
    "adipiscing",
    "elit.",
    "Ut",
    "condimentum",
    "dictum",
    "malesuada.",
    "Praesent",
    "ut",
    "imperdiet",
    "nulla.",
    "Vivamus",
    "feugiat,",
    "ante",
    "non",
    "sagittis",
    "pellentesque,",
    "dui",
    "massa",
    "consequat",
    "odio,",
    "ac",
    "vestibulum",
    "augue",
    "erat",
    "et",
    "nunc."
]

class MockCompletionDelegate: CodeSuggestionDelegate, ObservableObject {
    var lastPosition: CursorPosition?

    class Suggestion: CodeSuggestionEntry {
        var label: String
        var detail: String?
        var documentation: String?
        var pathComponents: [String]?
        var targetPosition: CursorPosition? = CursorPosition(line: 10, column: 20)
        var sourcePreview: String?
        var image: Image = Image(systemName: "dot.square.fill")
        var imageColor: Color = .gray
        var deprecated: Bool = false

        init(text: String, detail: String?, sourcePreview: String?, pathComponents: [String]?) {
            self.label = text
            self.detail = detail
            self.sourcePreview = sourcePreview
            self.pathComponents = pathComponents
        }
    }

    private func randomSuggestions(_ count: Int? = nil) -> [Suggestion] {
        let count = count ?? Int.random(in: 0..<20)
        var suggestions: [Suggestion] = []
        for _ in 0..<count {
            let randomString = (0..<Int.random(in: 1..<text.count)).map {
                text[$0]
            }.shuffled().joined(separator: " ")
            suggestions.append(
                Suggestion(
                    text: randomString,
                    detail: text.randomElement()!,
                    sourcePreview: randomString,
                    pathComponents: (0..<Int.random(in: 0..<10)).map { text[$0] }
                )
            )
        }
        return suggestions
    }

    var moveCount = 0

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        try? await Task.sleep(for: .seconds(0.2))
        lastPosition = cursorPosition
        return (cursorPosition, randomSuggestions())
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        // Check if we're typing all in a row.
        guard (lastPosition?.range.location ?? 0) + 1 == cursorPosition.range.location else {
            lastPosition = nil
            moveCount = 0
            return nil
        }

        lastPosition = cursorPosition
        moveCount += 1
        switch moveCount {
        case 1:
            return randomSuggestions(2)
        case 2:
            return randomSuggestions(20)
        case 3:
            return randomSuggestions(4)
        case 4:
            return randomSuggestions(1)
        default:
            moveCount = 0
            return nil
        }
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        guard let suggestion = item as? Suggestion, let cursorPosition else {
            return
        }
        textView.textView.undoManager?.beginUndoGrouping()
        textView.textView.selectionManager.setSelectedRange(cursorPosition.range)

        textView.textView.insertText(suggestion.label)
        textView.textView.undoManager?.endUndoGrouping()
    }
}
