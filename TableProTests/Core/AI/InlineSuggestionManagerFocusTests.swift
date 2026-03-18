//
//  InlineSuggestionManagerFocusTests.swift
//  TableProTests
//
//  Regression tests for InlineSuggestionManager focus lifecycle
//

@testable import TablePro
import Testing

@Suite("InlineSuggestionManager Focus Lifecycle")
@MainActor
struct InlineSuggestionManagerFocusTests {
    @Test("Initial state: isEditorFocused is false")
    func initialStateIsFalse() {
        let manager = InlineSuggestionManager()
        #expect(manager.isEditorFocused == false)
    }

    @Test("After editorDidFocus: isEditorFocused is true")
    func focusSetsTrue() {
        let manager = InlineSuggestionManager()
        manager.editorDidFocus()
        #expect(manager.isEditorFocused == true)
    }

    @Test("After editorDidBlur: isEditorFocused is false")
    func blurSetsFalse() {
        let manager = InlineSuggestionManager()
        manager.editorDidFocus()
        manager.editorDidBlur()
        #expect(manager.isEditorFocused == false)
    }

    @Test("Focus/blur cycle works correctly")
    func focusBlurCycle() {
        let manager = InlineSuggestionManager()
        manager.editorDidFocus()
        #expect(manager.isEditorFocused == true)
        manager.editorDidBlur()
        #expect(manager.isEditorFocused == false)
        manager.editorDidFocus()
        #expect(manager.isEditorFocused == true)
    }

    @Test("Multiple focus calls are idempotent")
    func multipleFocusCalls() {
        let manager = InlineSuggestionManager()
        manager.editorDidFocus()
        manager.editorDidFocus()
        manager.editorDidFocus()
        #expect(manager.isEditorFocused == true)
    }

    @Test("Multiple blur calls are idempotent")
    func multipleBlurCalls() {
        let manager = InlineSuggestionManager()
        manager.editorDidBlur()
        manager.editorDidBlur()
        manager.editorDidBlur()
        #expect(manager.isEditorFocused == false)
    }
}
