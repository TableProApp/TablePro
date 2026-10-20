import Foundation
import SwiftUI
import TableProAutocomplete
@testable import TableProMobile
import Testing
import UIKit

@MainActor
struct SQLEditorTextViewKeyCommandTests {
    @Test("Tab and Escape stay with the text system while no suggestion shows")
    func noCommandsWithoutSuggestions() {
        let textView = SQLEditorTextView()
        #expect(command(in: textView, input: "\t") == nil)
        #expect(command(in: textView, input: UIKeyCommand.inputEscape) == nil)
    }

    @Test("While suggestions show, Tab and Escape are titled, unmodified and ahead of the text system")
    func commandsWhileSuggestionsShow() throws {
        let textView = SQLEditorTextView()
        textView.showsSuggestions = true
        for input in ["\t", UIKeyCommand.inputEscape] {
            let keyCommand = try #require(command(in: textView, input: input))
            #expect(keyCommand.modifierFlags.isEmpty)
            #expect(keyCommand.wantsPriorityOverSystemBehavior)
            #expect(!keyCommand.title.isEmpty)
        }
    }

    @Test("Tab accepts and Escape hides, and neither can run once the suggestions are gone")
    func commandsRunTheirHandlers() throws {
        let textView = SQLEditorTextView()
        var accepted = 0
        var hidden = 0
        textView.onAcceptSuggestion = { accepted += 1 }
        textView.onHideSuggestions = { hidden += 1 }
        textView.showsSuggestions = true

        let tab = try #require(command(in: textView, input: "\t"))
        let escape = try #require(command(in: textView, input: UIKeyCommand.inputEscape))
        let tabAction = try #require(tab.action)
        let escapeAction = try #require(escape.action)
        #expect(textView.canPerformAction(tabAction, withSender: tab))
        #expect(textView.canPerformAction(escapeAction, withSender: escape))

        _ = textView.perform(tabAction, with: tab)
        _ = textView.perform(escapeAction, with: escape)
        #expect(accepted == 1)
        #expect(hidden == 1)

        textView.showsSuggestions = false
        #expect(!textView.canPerformAction(tabAction, withSender: tab))
        #expect(!textView.canPerformAction(escapeAction, withSender: escape))
    }

    @Test("An accepted name replaces the typed token and the binding holds the result")
    func acceptedNameReachesTheBinding() {
        let result = applied(
            QueryCompletionEdit(range: NSRange(location: 14, length: 2), text: "orders", caret: 20),
            to: "SELECT * FROM or"
        )
        #expect(result.text == "SELECT * FROM orders")
        #expect(result.selection == NSRange(location: 20, length: 0))
        #expect(result.binding == "SELECT * FROM orders")
    }

    @Test("An accepted function leaves the caret inside its parentheses")
    func acceptedFunctionPlacesTheCaret() {
        let result = applied(
            QueryCompletionEdit(range: NSRange(location: 7, length: 3), text: "COUNT()", caret: 13),
            to: "SELECT cou FROM t"
        )
        #expect(result.text == "SELECT COUNT() FROM t")
        #expect(result.selection == NSRange(location: 13, length: 0))
        #expect(result.binding == "SELECT COUNT() FROM t")
    }

    @Test("Edit offsets count UTF-16 units, as the analyzer reports them")
    func editOffsetsAreUTF16() {
        let original = "-- 😀\nSELECT * FROM or"
        let tokenStart = (original as NSString).length - 2
        let result = applied(
            QueryCompletionEdit(range: NSRange(location: tokenStart, length: 2), text: "orders", caret: tokenStart + 6),
            to: original
        )
        #expect(result.text == "-- 😀\nSELECT * FROM orders")
        #expect(result.binding == "-- 😀\nSELECT * FROM orders")
        #expect(result.selection == NSRange(location: tokenStart + 6, length: 0))
    }

    @Test("New suggestions open the bar at the first one, while the keyboard is off screen and when it shows")
    func suggestionsOpenAtTheFirst() throws {
        let controller = QueryCompletionController()
        let coordinator = SQLHighlightTextView(text: .constant(""), completion: controller).makeCoordinator()
        let accessory = coordinator.makeAccessoryToolbar()
        let textView = SQLEditorTextView()
        coordinator.connectCompletion(to: textView)
        let scrollView = try #require(accessory.subviews.lazy.compactMap { $0 as? UIScrollView }.first)
        let columns = (0..<8).map { QuerySuggestion(id: $0, label: "BillingAddress\($0)", kind: .column) }

        controller.onSuggestionsChange?(columns)
        #expect(scrollView.contentOffset.x == -scrollView.adjustedContentInset.left)

        accessory.frame = CGRect(x: 0, y: 0, width: 402, height: 44)
        accessory.layoutIfNeeded()
        controller.onSuggestionsChange?([])
        scrollView.contentOffset.x = 300
        controller.onSuggestionsChange?(Array(columns.reversed()))
        #expect(scrollView.contentOffset.x == -scrollView.adjustedContentInset.left)
    }

    @Test("Each suggestion is as wide as its own name")
    func chipsFitTheirNames() {
        let bar = QuerySuggestionBar()
        bar.show(["Total", "InvoiceId", "BillingAddress"].enumerated().map { index, label in
            QuerySuggestion(id: index, label: label, kind: .column)
        })
        bar.frame = CGRect(origin: .zero, size: bar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize))
        bar.layoutIfNeeded()

        var chips: [UIButton] = []
        var pending: [UIView] = [bar]
        while let view = pending.popLast() {
            if let button = view as? UIButton { chips.append(button) }
            pending.append(contentsOf: view.subviews)
        }
        #expect(chips.count == 3)
        for chip in chips {
            #expect(abs(chip.frame.width - chip.intrinsicContentSize.width) < 0.5)
        }
    }

    private func command(in textView: SQLEditorTextView, input: String) -> UIKeyCommand? {
        textView.keyCommands?.first { $0.input == input && $0.modifierFlags.isEmpty }
    }

    private func applied(_ edit: QueryCompletionEdit, to original: String) -> (text: String, selection: NSRange, binding: String) {
        let box = TextBox(original)
        let editor = SQLHighlightTextView(text: Binding(get: { box.text }, set: { box.text = $0 }))
        let coordinator = editor.makeCoordinator()
        let textView = SQLEditorTextView()
        textView.text = original
        textView.delegate = coordinator
        coordinator.textView = textView

        coordinator.apply(edit, to: textView)
        return (textView.text ?? "", textView.selectedRange, box.text)
    }
}

@MainActor
private final class TextBox {
    var text: String

    init(_ text: String) {
        self.text = text
    }
}
