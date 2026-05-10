//
//  PasteboardActionRouterTests.swift
//  TableProTests
//

import AppKit
import CodeEditTextView
import TableProPluginKit
import Testing
@testable import TablePro

@MainActor
@Suite("PasteboardActionRouter")
struct PasteboardActionRouterTests {

    // MARK: - Copy Action Tests

    @Test("NSTextView first responder returns textCopy")
    func copyWithNsTextView() {
        let textView = NSTextView()
        let action = PasteboardActionRouter.resolveCopyAction(
            firstResponder: textView,
            hasRowSelection: true,
            hasTableSelection: true
        )
        #expect(action == .textCopy)
    }

    @Test("CodeEditTextView.TextView first responder returns textCopy")
    func copyWithCodeEditTextView() {
        let textView = TextView(string: "")
        let action = PasteboardActionRouter.resolveCopyAction(
            firstResponder: textView,
            hasRowSelection: true,
            hasTableSelection: true
        )
        #expect(action == .textCopy)
    }

    @Test("No text responder with row selection returns copyRows")
    func copyWithRowSelection() {
        let action = PasteboardActionRouter.resolveCopyAction(
            firstResponder: nil,
            hasRowSelection: true,
            hasTableSelection: false
        )
        #expect(action == .copyRows)
    }

    @Test("No text responder with table selection returns copyTableNames")
    func copyWithTableSelection() {
        let action = PasteboardActionRouter.resolveCopyAction(
            firstResponder: nil,
            hasRowSelection: false,
            hasTableSelection: true
        )
        #expect(action == .copyTableNames)
    }

    @Test("No text responder and no selection returns textCopy fallback")
    func copyFallback() {
        let action = PasteboardActionRouter.resolveCopyAction(
            firstResponder: nil,
            hasRowSelection: false,
            hasTableSelection: false
        )
        #expect(action == .textCopy)
    }

    // MARK: - Paste Action Tests

    @Test("NSTextView first responder returns textPaste")
    func pasteWithNsTextView() {
        let textView = NSTextView()
        let action = PasteboardActionRouter.resolvePasteAction(
            firstResponder: textView,
            isCurrentTabEditable: true
        )
        #expect(action == .textPaste)
    }

    @Test("CodeEditTextView.TextView first responder returns textPaste")
    func pasteWithCodeEditTextView() {
        let textView = TextView(string: "")
        let action = PasteboardActionRouter.resolvePasteAction(
            firstResponder: textView,
            isCurrentTabEditable: true
        )
        #expect(action == .textPaste)
    }

    @Test("No text responder with editable tab returns pasteRows")
    func pasteWithEditableTab() {
        let action = PasteboardActionRouter.resolvePasteAction(
            firstResponder: nil,
            isCurrentTabEditable: true
        )
        #expect(action == .pasteRows)
    }

    @Test("No text responder with non-editable tab returns textPaste fallback")
    func pasteFallback() {
        let action = PasteboardActionRouter.resolvePasteAction(
            firstResponder: nil,
            isCurrentTabEditable: false
        )
        #expect(action == .textPaste)
    }

    // MARK: - Edge Case Tests

    @Test("Non-text responder with row selection returns copyRows")
    func copyWithNonTextResponder() {
        let button = NSButton()
        let action = PasteboardActionRouter.resolveCopyAction(
            firstResponder: button,
            hasRowSelection: true,
            hasTableSelection: false
        )
        #expect(action == .copyRows)
    }

    @Test("Non-text responder with editable tab returns pasteRows")
    func pasteWithNonTextResponder() {
        let button = NSButton()
        let action = PasteboardActionRouter.resolvePasteAction(
            firstResponder: button,
            isCurrentTabEditable: true
        )
        #expect(action == .pasteRows)
    }
}
