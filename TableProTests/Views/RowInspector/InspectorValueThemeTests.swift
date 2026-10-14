//
//  InspectorValueThemeTests.swift
//  TableProTests
//
//  The inspector's value wells and its JSON tab take the editor's background while the theme sets
//  it, and draw exactly what they always did under the default pair.
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct InspectorValueThemeTests {
    private static let wellSize = CGSize(width: 240, height: 60)
    private static let paneSize = CGSize(width: 240, height: 300)
    private static let editorBackground = "#FDF6E3"

    private func context(_ value: String, state: FieldValueState? = nil, isReadOnly: Bool = true) -> FieldEditorContext {
        FieldEditorContext(
            columnName: "note",
            columnType: .text(rawType: "TEXT"),
            isLongText: false,
            value: .constant(value),
            originalValue: value,
            valueState: state ?? .value(value),
            isReadOnly: isReadOnly
        )
    }

    private func field(_ value: String, kind: FieldEditorKind, state: FieldValueState? = nil) -> FieldEditorContent {
        FieldEditorContent(context: context(value, state: state), kind: kind, databaseType: .sqlite)
    }

    private func pixel(of view: some View, size: CGSize, x: Int, fromBottom: Int? = nil) throws -> NSColor {
        let rep = try ThemeTestFixture.bitmap(of: view.frame(width: size.width, height: size.height), colorScheme: .light)
        let y = fromBottom.map { rep.pixelsHigh - 1 - $0 } ?? rep.pixelsHigh / 2
        return try #require(ThemeTestFixture.pixel(rep, x: x, y: y))
    }

    /// Near the trailing edge of a well, clear of its text and inside its border.
    private func wellPixel(_ view: some View) throws -> NSColor {
        try pixel(of: view, size: Self.wellSize, x: Int(Self.wellSize.width) - 12)
    }

    // MARK: - Wells

    @Test("Under the default pair a read-only value and a pending NULL draw the text background they always did")
    func defaultWellsAreNative() throws {
        try ThemeTestFixture.adopting([:], appearance: .light) {
            let native = try ThemeTestFixture.filled(.textBackgroundColor, colorScheme: .light)
            let value = try wellPixel(field("a", kind: .singleLine))
            let pending = try wellPixel(field("", kind: .singleLine, state: .pendingNull))

            #expect(ThemeTestFixture.matches(value, native), "\(value) against \(native)")
            #expect(ThemeTestFixture.matches(pending, native), "\(pending) against \(native)")
        }
    }

    @Test("Under a theme a read-only value and a pending NULL sit on the editor background")
    func themedWellsTakeTheEditorBackground() throws {
        try ThemeTestFixture.adopting([.editorBackground: Self.editorBackground], appearance: .light) {
            let themed = try ThemeTestFixture.filled(hex: Self.editorBackground, colorScheme: .light)
            let value = try wellPixel(field("a", kind: .singleLine))
            let pending = try wellPixel(field("", kind: .singleLine, state: .pendingNull))

            #expect(ThemeTestFixture.matches(value, themed), "\(value) against \(themed)")
            #expect(ThemeTestFixture.matches(pending, themed), "\(pending) against \(themed)")
        }
    }

    // MARK: - Multi-line

    private func hostedTextView(_ view: some View) throws -> (NSWindow, NSTextView) {
        let window = ThemeTestFixture.host(view, size: NSSize(width: 240, height: 160))
        return (window, try #require(ThemeTestFixture.textViews(in: window).first))
    }

    @Test("A multi-line value keeps the system text colors under the default pair")
    func multiLineDefaultIsNative() throws {
        try ThemeTestFixture.adopting([:], appearance: .light) {
            let (window, textView) = try hostedTextView(field("line one\nline two", kind: .multiLine))
            #expect(textView.backgroundColor === NSColor.textBackgroundColor)
            #expect(textView.textColor === NSColor.textColor)
            withExtendedLifetime(window) {}
        }
    }

    @Test("A multi-line value takes the editor's background and text while the theme sets them")
    func multiLineFollowsTheTheme() throws {
        try ThemeTestFixture.adopting([.editorBackground: Self.editorBackground, .editorText: "#657B83"], appearance: .light) {
            let (window, textView) = try hostedTextView(field("line one\nline two", kind: .multiLine))
            #expect(ThemeTestFixture.hex(textView.backgroundColor) == Self.editorBackground)
            #expect(ThemeTestFixture.hex(textView.textColor) == "#657B83")
            withExtendedLifetime(window) {}
        }
    }

    // MARK: - JSON tab

    private func jsonTab() -> JSONRowInspectorView {
        JSONRowInspectorView(
            viewModel: JSONRowInspectorViewModel { _, _, _, _ in nil },
            snapshot: JSONRowSnapshot(
                rowIdentity: "tab\u{001F}existing(0)",
                columns: [],
                columnTypes: [],
                values: [],
                foreignKeys: [:],
                scope: DatabaseScope(connectionId: UUID(), database: "main", schema: nil),
                databaseType: .sqlite
            ),
            onOpenReferencedTable: { _, _ in }
        )
    }

    @Test("Under the default pair the JSON tab draws no background of its own, so the inspector shows through")
    func jsonTabDefaultIsClear() throws {
        try ThemeTestFixture.adopting([:], appearance: .light) {
            let corner = try pixel(of: jsonTab(), size: Self.paneSize, x: 4, fromBottom: 4)
            #expect(corner.alphaComponent < 0.02, "\(corner)")
        }
    }

    @Test("Under a theme the JSON tab's tree sits on the editor background")
    func jsonTabTakesTheEditorBackground() throws {
        try ThemeTestFixture.adopting([.editorBackground: Self.editorBackground], appearance: .light) {
            let themed = try ThemeTestFixture.filled(hex: Self.editorBackground, colorScheme: .light)
            let corner = try pixel(of: jsonTab(), size: Self.paneSize, x: 4, fromBottom: 4)
            #expect(ThemeTestFixture.matches(corner, themed), "\(corner) against \(themed)")
        }
    }
}
