//
//  ValueStandInThemeTests.swift
//  TableProTests
//
//  A value's tree or text sits on the editor background under a theme. The states that take its
//  place (a parse failure, an empty value, the wait while it parses, no rows) fell through to the
//  popover or pane material behind them, and the array editor's raw text was a system text view.
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProTheme
import Testing

@MainActor
struct ValueStandInThemeTests {
    private static let size = CGSize(width: 360, height: 280)
    private static let editorBackground = "#282A36"

    // Under the default pair the state draws nothing of its own, under a theme the editor background.
    private func assertStandsIn(_ view: some View, at point: CGPoint = CGPoint(x: 0.03, y: 0.8)) throws {
        let framed = view.frame(width: Self.size.width, height: Self.size.height)
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let native = try ThemeTestFixture.color(of: framed, at: point, colorScheme: .light)
            #expect(native.alphaComponent < 0.02, "the default pair drew \(native)")
        }
        try ThemeTestFixture.adopting([.editorBackground: Self.editorBackground], appearance: .light) {
            let themed = try ThemeTestFixture.color(of: framed, at: point, colorScheme: .light)
            let theme = try ThemeTestFixture.filled(hex: Self.editorBackground, colorScheme: .light)
            #expect(ThemeTestFixture.matches(themed, theme), "drew \(themed), theme \(theme)")
        }
    }

    @Test("Invalid JSON in the tree view sits on the editor background")
    func invalidJSONTree() throws {
        try assertStandsIn(JSONViewerView(text: .constant("{\"a\": "), isEditable: false, initialViewMode: .tree))
    }

    @Test("An empty JSON value in the tree view sits on the editor background")
    func emptyJSONTree() throws {
        try assertStandsIn(JSONViewerView(text: .constant(""), isEditable: false, initialViewMode: .tree))
    }

    @Test("A PHP value that fails to parse, and one still parsing, sit on the editor background")
    func phpStates() throws {
        try assertStandsIn(PhpViewerView(rawValue: "a:1:{", initialParseResult: .failed))
        try assertStandsIn(PhpViewerView(rawValue: "a:1:{", initialParseResult: .tooLarge))
        try assertStandsIn(PhpViewerView(rawValue: "a:1:{", initialParseResult: .parsing))
    }

    @Test("The result pane's JSON mode with no rows sits on the editor background")
    func resultJSONWithoutRows() throws {
        try assertStandsIn(ResultsJsonView(
            tableRows: TableRows(),
            selectedRowIDs: [],
            displayIDs: nil,
            deletedRowIDs: [],
            valueFilter: GridValueFilterState(),
            dataRevision: 0,
            displayRevision: 0,
            columnLayout: ColumnLayoutState()
        ))
    }

    // MARK: - Array raw text

    private func rawTextView(in window: NSWindow) throws -> NSTextView {
        try #require(ThemeTestFixture.textViews(in: window).first)
    }

    // A literal the list editor cannot read opens straight into raw text.
    private var rawArrayEditor: some View {
        ArrayValueEditorView(
            literal: "{{1,2},{3}}",
            allowedValues: [],
            isNullable: true,
            onCommit: { _ in },
            onDismiss: {}
        )
    }

    @Test("The array editor's raw text keeps the system text colors and types what it is given")
    func arrayRawTextDefault() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let window = ThemeTestFixture.host(rawArrayEditor, size: NSSize(width: 320, height: 260))
            let textView = try rawTextView(in: window)

            #expect(textView.string == "{{1,2},{3}}")
            #expect(textView.backgroundColor === NSColor.textBackgroundColor)
            #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
            #expect(!textView.isAutomaticDashSubstitutionEnabled)
            #expect(textView.isEditable)
            withExtendedLifetime(window) {}
        }
    }

    @Test("The array editor's raw text takes the editor's colors under a theme")
    func arrayRawTextThemed() throws {
        try ThemeTestFixture.adopting([.editorBackground: Self.editorBackground, .editorText: "#F8F8F2"], appearance: .light) {
            let window = ThemeTestFixture.host(rawArrayEditor, size: NSSize(width: 320, height: 260))
            let textView = try rawTextView(in: window)

            #expect(ThemeTestFixture.hex(textView.backgroundColor) == Self.editorBackground)
            #expect(ThemeTestFixture.hex(textView.textColor) == "#F8F8F2")
            withExtendedLifetime(window) {}
        }
    }
}
