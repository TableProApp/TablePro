//
//  TextValueEditorDefaultsTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
@Suite("TextValueEditor defaults")
struct TextValueEditorDefaultsTests {
    @Test("every automatic substitution is off, so a typed value reaches the database unchanged")
    func substitutionsAreDisabled() {
        let textView = NSTextView(frame: .zero)
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.isRichText = true

        TextValueEditor.applyPlainTextDefaults(to: textView)

        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(!textView.isAutomaticTextReplacementEnabled)
        #expect(!textView.isAutomaticSpellingCorrectionEnabled)
        #expect(!textView.isAutomaticLinkDetectionEnabled)
        #expect(!textView.isAutomaticDataDetectionEnabled)
        #expect(!textView.isRichText)
    }

    /// `undoManager` itself comes from the window through the responder chain, so a detached text
    /// view has none. What this function owns, and what a field editor needs, is `allowsUndo`:
    /// without it Command Z walks past the field and reaches the app's row-edit undo instead.
    @Test("undo is local, so Command Z in a field does not reach the app's row-edit undo")
    func undoIsLocalToTheTextView() {
        let textView = NSTextView(frame: .zero)
        textView.allowsUndo = false
        TextValueEditor.applyPlainTextDefaults(to: textView)
        #expect(textView.allowsUndo)
    }
}
