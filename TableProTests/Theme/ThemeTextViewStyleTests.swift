//
//  ThemeTextViewStyleTests.swift
//  TableProTests
//
//  A value text view under a default theme has to stay exactly what AppKit configured, down to the
//  color objects: a copy of the selection color loses the inactive-selection gray, and a copy of
//  the text color stops following Increase Contrast.
//

import AppKit
@testable import TablePro
import Testing

/// Each test adopts a pair on the shared `ThemeEngine` and restores it in a `defer`. The bodies are
/// synchronous and `@MainActor`, so nothing else on the main actor runs between the two.
@Suite("Text views follow the editor theme", .serialized)
@MainActor
struct ThemeTextViewStyleTests {
    private func preservingEngine(_ body: () throws -> Void) rethrows {
        let engine = ThemeEngine.shared
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }
        try body()
    }

    private func adopt(_ overrides: [ThemeSlot: String]) throws {
        var theme = BuiltInThemes.light
        if !overrides.isEmpty {
            theme.id = "user.test.text-view-style"
            for (slot, hex) in overrides {
                theme.overrides[slot] = try ThemeColor(validating: hex)
            }
        }
        ThemeEngine.shared.adopt(ThemeSelection(
            pair: ThemePair(light: theme, dark: BuiltInThemes.dark),
            effectiveAppearance: .light
        ))
    }

    private func makeTextView() throws -> NSTextView {
        let textView = try #require(NSTextView.scrollableTextView().documentView as? NSTextView)
        textView.appearance = NSAppearance(named: .aqua)
        return textView
    }

    private func hex(_ color: NSColor?) throws -> String {
        let color = try #require(color)
        var hex = ""
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            hex = HexColor.string(from: color)
        }
        return hex
    }

    private func selectionBackground(of textView: NSTextView) -> NSColor? {
        textView.selectedTextAttributes[.backgroundColor] as? NSColor
    }

    private static let everyEditorSlot: [ThemeSlot: String] = [
        .editorBackground: "#FDF6E3",
        .editorText: "#586E75",
        .editorCursor: "#D33682",
        .editorSelection: "#EEE8D5",
    ]

    @Test("Under the default theme nothing is written and the system color objects stay")
    func defaultThemeWritesNothing() throws {
        try preservingEngine {
            try adopt([:])
            let textView = try makeTextView()
            let style = ThemeTextViewStyle(textView: textView)

            #expect(textView.backgroundColor === NSColor.textBackgroundColor)
            #expect(textView.textColor === NSColor.textColor)
            #expect(textView.insertionPointColor === ThemeSlot.editorCursor.nativeColor)
            #expect(selectionBackground(of: textView) === NSColor.selectedTextBackgroundColor)
            withExtendedLifetime(style) {}
        }
    }

    @Test("A theme that sets the editor slots colors the text view, and switching back restores each object")
    func themeColorsAndRestores() throws {
        try preservingEngine {
            try adopt([:])
            let textView = try makeTextView()
            let selectedForeground = textView.selectedTextAttributes[.foregroundColor] as? NSColor
            let style = ThemeTextViewStyle(textView: textView)

            try adopt(Self.everyEditorSlot)
            #expect(try hex(textView.backgroundColor) == "#FDF6E3")
            #expect(try hex(textView.textColor) == "#586E75")
            #expect(try hex(textView.insertionPointColor) == "#D33682")
            #expect(try hex(selectionBackground(of: textView)) == "#EEE8D5")
            #expect(textView.selectedTextAttributes[.foregroundColor] as? NSColor === selectedForeground)

            try adopt([:])
            #expect(textView.backgroundColor == NSColor.textBackgroundColor)
            #expect(textView.textColor == NSColor.textColor)
            #expect(textView.insertionPointColor == ThemeSlot.editorCursor.nativeColor)
            #expect(selectionBackground(of: textView) == NSColor.selectedTextBackgroundColor)
            withExtendedLifetime(style) {}
        }
    }

    @Test("A theme that sets only the background leaves the other properties native")
    func partialThemeKeepsTheRestNative() throws {
        try preservingEngine {
            try adopt([.editorBackground: "#FDF6E3"])
            let textView = try makeTextView()
            let style = ThemeTextViewStyle(textView: textView)

            #expect(try hex(textView.backgroundColor) == "#FDF6E3")
            #expect(textView.textColor === NSColor.textColor)
            #expect(selectionBackground(of: textView) === NSColor.selectedTextBackgroundColor)
            withExtendedLifetime(style) {}
        }
    }

    @Test("The natives a caller passes are what a property returns to")
    func givenNativesAreRestored() throws {
        try preservingEngine {
            try adopt([:])
            let textView = try makeTextView()
            textView.textColor = .labelColor
            let natives = ThemeTextViewStyle.Natives(
                background: .controlBackgroundColor,
                text: .labelColor,
                insertionPoint: .labelColor,
                selectedTextBackground: .selectedTextBackgroundColor
            )
            let style = ThemeTextViewStyle(textView: textView, natives: natives)
            #expect(textView.backgroundColor === NSColor.textBackgroundColor)

            try adopt(Self.everyEditorSlot)
            try adopt([:])
            #expect(textView.backgroundColor == NSColor.controlBackgroundColor)
            #expect(textView.textColor == NSColor.labelColor)
            #expect(textView.insertionPointColor == NSColor.labelColor)
            withExtendedLifetime(style) {}
        }
    }

    @Test("Text set after the theme keeps the theme's text color")
    func replacedTextKeepsTheColor() throws {
        try preservingEngine {
            try adopt(Self.everyEditorSlot)
            let textView = try makeTextView()
            let style = ThemeTextViewStyle(textView: textView)

            textView.string = "SELECT 1"
            #expect(try hex(textView.textColor) == "#586E75")
            let attributes = textView.textStorage?.attributes(at: 0, effectiveRange: nil)
            #expect(try hex(attributes?[.foregroundColor] as? NSColor) == "#586E75")
            withExtendedLifetime(style) {}
        }
    }

    @Test("Detaching hands every property back and stops following the theme")
    func detachRestores() throws {
        try preservingEngine {
            try adopt(Self.everyEditorSlot)
            let textView = try makeTextView()
            let style = ThemeTextViewStyle(textView: textView)
            #expect(try hex(textView.backgroundColor) == "#FDF6E3")

            style.detach()
            #expect(textView.backgroundColor == NSColor.textBackgroundColor)
            #expect(textView.textColor == NSColor.textColor)

            try adopt([.editorBackground: "#002B36"])
            #expect(textView.backgroundColor == NSColor.textBackgroundColor)
        }
    }
}
