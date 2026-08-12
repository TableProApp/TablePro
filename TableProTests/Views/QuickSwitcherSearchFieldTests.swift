import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct QuickSwitcherSearchFieldTests {
    @Test("Every Return command submits")
    func returnCommandsSubmit() {
        var text = "invoice"
        var submitCount = 0
        let field = QuickSwitcherSearchField(
            text: Binding(get: { text }, set: { text = $0 }),
            placeholder: "",
            onMoveUp: {},
            onMoveDown: {},
            onSubmit: { submitCount += 1 }
        )
        let coordinator = field.makeCoordinator()
        let control = NSTextField()
        let editor = NSTextView()
        let selectors = [
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
            #selector(NSResponder.insertLineBreak(_:))
        ]

        for selector in selectors {
            #expect(coordinator.control(control, textView: editor, doCommandBy: selector))
        }

        #expect(submitCount == selectors.count)
    }

    @Test("Escape passes through to the panel")
    func escapePassesThrough() {
        var text = "invoice"
        let field = QuickSwitcherSearchField(
            text: Binding(get: { text }, set: { text = $0 }),
            placeholder: "",
            onMoveUp: {},
            onMoveDown: {},
            onSubmit: {}
        )
        let coordinator = field.makeCoordinator()

        let handled = coordinator.control(
            NSTextField(),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )

        #expect(!handled)
        #expect(text == "invoice")
    }
}
