//
//  SQLPreviewThemeTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProEditorKit
import TableProTheme
import Testing

@MainActor
struct SQLPreviewThemeTests {
    private static let statement = "-- note SELECT 1\nSELECT COUNT(id) FROM orders o WHERE x IS NULL AND y = 'a' AND z > 2"

    /// Every slot the statement draws in, each a color no other slot shares.
    private static let syntaxTheme: [ThemeSlot: String] = [
        .editorText: "#101010",
        .syntaxKeyword: "#C00000",
        .syntaxComment: "#00A000",
        .syntaxFunction: "#0000C0",
        .syntaxNull: "#C000C0",
        .syntaxString: "#00C0C0",
        .syntaxNumber: "#C0C000",
        .syntaxOperator: "#800040",
        .syntaxType: "#408000",
    ]

    private static let size = NSSize(width: 900, height: 160)

    private func host(_ sql: String = statement) -> NSWindow {
        ThemeTestFixture.host(HighlightedSQLTextView(sql: sql, databaseType: .mysql), size: Self.size)
    }

    private func textView(in window: NSWindow) throws -> NSTextView {
        try #require(ThemeTestFixture.textViews(in: window).first)
    }

    /// The `occurrence`th match of `fragment`, counted from 1.
    private func range(of fragment: String, occurrence: Int = 1, in textView: NSTextView) throws -> NSRange {
        let text = textView.string as NSString
        var searchFrom = 0
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0 ..< occurrence {
            found = text.range(of: fragment, range: NSRange(location: searchFrom, length: text.length - searchFrom))
            try #require(found.location != NSNotFound, "no \(fragment)")
            searchFrom = NSMaxRange(found)
        }
        return found
    }

    private func hex(of fragment: String, occurrence: Int = 1, in textView: NSTextView) throws -> String? {
        let range = try range(of: fragment, occurrence: occurrence, in: textView)
        let color = textView.textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        return ThemeTestFixture.hex(color)
    }

    /// The table alias, a name the user wrote.
    private func aliasHex(in textView: NSTextView) throws -> String? {
        let location = try range(of: " o ", in: textView).location + 1
        let color = textView.textStorage?.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
        return ThemeTestFixture.hex(color)
    }

    private func selectionHex(of textView: NSTextView) -> String? {
        ThemeTestFixture.hex(textView.selectedTextAttributes[.backgroundColor] as? NSColor)
    }

    // MARK: - Text view colors

    @Test("Under the default pair the preview keeps the text view's own system colors")
    func defaultPairKeepsSystemColors() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let window = host()
            let textView = try textView(in: window)
            let scrollView = try #require(textView.enclosingScrollView)

            #expect(textView.backgroundColor === NSColor.textBackgroundColor)
            #expect(scrollView.backgroundColor === NSColor.textBackgroundColor)
            #expect(selectionHex(of: textView) == ThemeTestFixture.hex(.selectedTextBackgroundColor))
            withExtendedLifetime(window) {}
        }
    }

    @Test("A theme's editor selection reaches the preview, and the system's comes back after")
    func selectionFollowsTheTheme() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let window = host()
            let textView = try textView(in: window)

            try ThemeTestFixture.adopt([.editorSelection: "#FF00FF"], appearance: .light)
            #expect(selectionHex(of: textView) == "#FF00FF")

            ThemeTestFixture.adopt(.builtIn, appearance: .light)
            #expect(selectionHex(of: textView) == ThemeTestFixture.hex(.selectedTextBackgroundColor))
            withExtendedLifetime(window) {}
        }
    }

    @Test("The scroll view behind a short query takes the editor background with the text view")
    func scrollViewFollowsTheEditorBackground() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let window = host("SELECT 1")
            let textView = try textView(in: window)
            let scrollView = try #require(textView.enclosingScrollView)

            try ThemeTestFixture.adopt([.editorBackground: ThemeTestFixture.editorHex], appearance: .light)
            window.contentView?.layoutSubtreeIfNeeded()

            #expect(ThemeTestFixture.hex(textView.backgroundColor) == ThemeTestFixture.editorHex)
            #expect(ThemeTestFixture.hex(scrollView.backgroundColor) == ThemeTestFixture.editorHex)
            withExtendedLifetime(window) {}
        }
    }

    // MARK: - Syntax

    @Test("Each token draws in the slot the SQL editor gives it")
    func tokensTakeTheEditorsSlots() throws {
        try ThemeTestFixture.adopting(Self.syntaxTheme, appearance: .light) {
            let window = host()
            let textView = try textView(in: window)
            let theme = Self.syntaxTheme

            #expect(try hex(of: "-- note", in: textView) == theme[.syntaxComment])
            #expect(try hex(of: "SELECT", occurrence: 1, in: textView) == theme[.syntaxComment])
            #expect(try hex(of: "SELECT", occurrence: 2, in: textView) == theme[.syntaxKeyword])
            #expect(try hex(of: "COUNT", in: textView) == theme[.syntaxFunction])
            #expect(try hex(of: "NULL", in: textView) == theme[.syntaxNull])
            #expect(try hex(of: "'a'", in: textView) == theme[.syntaxString])
            #expect(try hex(of: "2", occurrence: 1, in: textView) == theme[.syntaxNumber])
            #expect(try hex(of: "=", in: textView) == theme[.syntaxOperator])
            #expect(try aliasHex(in: textView) == theme[.editorText])
            withExtendedLifetime(window) {}
        }
    }

    @Test("Keywords are bold, as the editor draws them")
    func keywordsAreBold() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let window = host()
            let textView = try textView(in: window)
            let keyword = try range(of: "SELECT", occurrence: 2, in: textView)
            let alias = try range(of: " o ", in: textView)

            let keywordFont = try #require(textView.textStorage?.attribute(.font, at: keyword.location, effectiveRange: nil) as? NSFont)
            let aliasFont = try #require(textView.textStorage?.attribute(.font, at: alias.location + 1, effectiveRange: nil) as? NSFont)
            #expect(keywordFont.fontDescriptor.symbolicTraits.contains(.bold))
            #expect(!aliasFont.fontDescriptor.symbolicTraits.contains(.bold))
            withExtendedLifetime(window) {}
        }
    }

    /// The text view's text color covers every character, so a theme that sets it would leave the
    /// statement one color unless the syntax is applied again after it.
    @Test("A theme change keeps the syntax colors, in both directions")
    func themeChangeKeepsTheSyntax() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let window = host()
            let textView = try textView(in: window)
            let defaultKeyword = try hex(of: "SELECT", occurrence: 2, in: textView)

            try ThemeTestFixture.adopt(Self.syntaxTheme, appearance: .light)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(try hex(of: "SELECT", occurrence: 2, in: textView) == Self.syntaxTheme[.syntaxKeyword])
            #expect(try aliasHex(in: textView) == Self.syntaxTheme[.editorText])

            ThemeTestFixture.adopt(.builtIn, appearance: .light)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(try hex(of: "SELECT", occurrence: 2, in: textView) == defaultKeyword)
            withExtendedLifetime(window) {}
        }
    }

    // MARK: - Statement preview font

    @Test("The rich statement preview uses the editor font setting")
    func richPreviewUsesTheEditorFont() {
        let previous = AppSettingsManager.shared.typography
        ThemeEngine.shared.apply(typography: TypographySettings(editorFontFamily: "Menlo", editorFontSize: 17))
        defer { ThemeEngine.shared.apply(typography: previous) }

        let font = SQLStatementPreview.makeConfiguration().appearance.font
        #expect(font == ThemeEngine.shared.editorFonts.font)
        #expect(font != NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    }
}
