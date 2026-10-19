//
//  CompositionTypingTests.swift
//  TableProEditorKitTests
//

import AppKit
@testable import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
struct CompositionTypingTests {
    private static let notFound = NSRange(location: NSNotFound, length: 0)

    private func makeController(_ text: String, caret: Int) -> TextViewController {
        let controller = Mock.loadedTextViewController(string: text)
        controller.textView.selectionManager.setSelectedRange(NSRange(location: caret, length: 0))
        return controller
    }

    private func type(_ text: String, in textView: TextView) {
        textView.insertText(text, replacementRange: Self.notFound)
    }

    private func compose(_ marked: String, committing commit: String, in textView: TextView) {
        textView.setMarkedText(
            marked,
            selectedRange: NSRange(location: (marked as NSString).length, length: 0),
            replacementRange: Self.notFound
        )
        type(commit, in: textView)
    }

    private func carets(of controller: TextViewController) -> [NSRange] {
        controller.textView.selectionManager.textSelections.map(\.range)
    }

    @Test(arguments: ["'", "\""])
    func deadKeyThenSpaceTypesOneQuote(quote: String) {
        let controller = makeController("SELECT ", caret: 7)

        compose(quote, committing: quote, in: controller.textView)

        #expect(controller.textView.string == "SELECT " + quote)
        #expect(carets(of: controller) == [NSRange(location: 8, length: 0)])
    }

    @Test(arguments: [("'", "'", "a"), ("\"", "\"", "a"), ("'", "é", "x"), ("(", "(", "a")])
    func committedCompositionTypesLikeTheKey(marked: String, commit: String, next: String) {
        let typed = makeController("SELECT ", caret: 7)
        type(commit, in: typed.textView)
        type(next, in: typed.textView)

        let composed = makeController("SELECT ", caret: 7)
        compose(marked, committing: commit, in: composed.textView)
        type(next, in: composed.textView)

        #expect(composed.textView.string == typed.textView.string)
        #expect(carets(of: composed) == carets(of: typed))
    }

    @Test
    func cancelledDeadKeyKeepsTheClosingQuoteAfterIt() {
        let controller = makeController("''", caret: 1)

        controller.textView.setMarkedText(
            "'",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: Self.notFound
        )
        controller.textView.setMarkedText(
            "",
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: Self.notFound
        )

        #expect(controller.textView.string == "''")
        #expect(carets(of: controller) == [NSRange(location: 1, length: 0)])
    }

    @Test
    func compositionAcceptedByUnmarkingKeepsTheClosingQuoteAfterIt() {
        let controller = makeController("''", caret: 1)

        controller.textView.setMarkedText(
            "'",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: Self.notFound
        )
        controller.textView.unmarkText()

        #expect(controller.textView.string == "'''")
        #expect(controller.textView.hasMarkedText() == false)
    }
}
