//
//  TextValueEditorDefaultsTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
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

    // MARK: - Style

    /// Never ordered front and never closed: `close()` on a test window over-releases it.
    private func hostedTextView(_ editor: TextValueEditor) throws -> (NSWindow, NSTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: editor.frame(width: 240, height: 120))
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, try #require(firstTextView(in: window.contentView)))
    }

    private func firstTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let textView = firstTextView(in: subview) { return textView }
        }
        return nil
    }

    private func editor(_ style: TextValueEditor.Style? = nil) -> TextValueEditor {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        guard let style else { return TextValueEditor(text: .constant("value"), font: font) }
        return TextValueEditor(text: .constant("value"), font: font, style: style)
    }

    @Test("the default style is plain, so every existing caller keeps the system text colors")
    func defaultStyleIsPlain() {
        #expect(editor().style == .plain)
    }

    @Test("a plain editor keeps the system colors under a theme that sets every slot")
    func plainIgnoresTheTheme() throws {
        try PaneThemeFixture.withEverySlotOverridden {
            let (window, textView) = try hostedTextView(editor())
            #expect(textView.backgroundColor === NSColor.textBackgroundColor)
            #expect(textView.textColor === NSColor.textColor)
            withExtendedLifetime(window) {}
        }
    }

    @Test("a code editor takes the editor's colors while the theme sets them, and the system's after")
    func codeFollowsTheTheme() throws {
        var hosted: (NSWindow, NSTextView)?
        try PaneThemeFixture.withEverySlotOverridden {
            let pair = try hostedTextView(editor(.code))
            hosted = pair
            #expect(HexColor.string(from: pair.1.backgroundColor) == "#FF00FF")
            #expect(pair.1.textColor.map(HexColor.string(from:)) == "#FF00FF")
        }
        let textView = try #require(hosted?.1)
        #expect(textView.backgroundColor == NSColor.textBackgroundColor)
        #expect(textView.textColor == NSColor.textColor)
        withExtendedLifetime(hosted) {}
    }
}
