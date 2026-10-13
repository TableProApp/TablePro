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
        let rep = try #require(OffscreenRender.bitmap(of: view.frame(width: size.width, height: size.height), colorScheme: .light))
        let y = fromBottom.map { rep.pixelsHigh - 1 - $0 } ?? rep.pixelsHigh / 2
        return try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    /// Near the trailing edge of a well, clear of its text and inside its border.
    private func wellPixel(_ view: some View) throws -> NSColor {
        try pixel(of: view, size: Self.wellSize, x: Int(Self.wellSize.width) - 12)
    }

    /// A plain fill rendered the same way, so the renderer's color management cancels out.
    private func filled(_ color: NSColor) throws -> NSColor {
        try wellPixel(Color(nsColor: color))
    }

    private func matches(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) <= 0.02
            && abs(lhs.greenComponent - rhs.greenComponent) <= 0.02
            && abs(lhs.blueComponent - rhs.blueComponent) <= 0.02
            && abs(lhs.alphaComponent - rhs.alphaComponent) <= 0.02
    }

    // MARK: - Wells

    @Test("Under the default pair a read-only value and a pending NULL draw the text background they always did")
    func defaultWellsAreNative() throws {
        try TreeThemeFixture.with([:]) {
            let native = try filled(.textBackgroundColor)
            let value = try wellPixel(field("a", kind: .singleLine))
            let pending = try wellPixel(field("", kind: .singleLine, state: .pendingNull))

            #expect(matches(value, native), "\(value) against \(native)")
            #expect(matches(pending, native), "\(pending) against \(native)")
        }
    }

    @Test("Under a theme a read-only value and a pending NULL sit on the editor background")
    func themedWellsTakeTheEditorBackground() throws {
        try TreeThemeFixture.with([.editorBackground: Self.editorBackground]) {
            let themed = try filled(HexColor.color(Self.editorBackground))
            let value = try wellPixel(field("a", kind: .singleLine))
            let pending = try wellPixel(field("", kind: .singleLine, state: .pendingNull))

            #expect(matches(value, themed), "\(value) against \(themed)")
            #expect(matches(pending, themed), "\(pending) against \(themed)")
        }
    }

    // MARK: - Multi-line

    /// Never ordered front and never closed: `close()` on a test window over-releases it.
    private func hostedTextView(_ view: some View) throws -> (NSWindow, NSTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: view.frame(width: 240, height: 160))
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

    @Test("A multi-line value keeps the system text colors under the default pair")
    func multiLineDefaultIsNative() throws {
        try TreeThemeFixture.with([:]) {
            let (window, textView) = try hostedTextView(field("line one\nline two", kind: .multiLine))
            #expect(textView.backgroundColor === NSColor.textBackgroundColor)
            #expect(textView.textColor === NSColor.textColor)
            withExtendedLifetime(window) {}
        }
    }

    @Test("A multi-line value takes the editor's background and text while the theme sets them")
    func multiLineFollowsTheTheme() throws {
        try TreeThemeFixture.with([.editorBackground: Self.editorBackground, .editorText: "#657B83"]) {
            let (window, textView) = try hostedTextView(field("line one\nline two", kind: .multiLine))
            #expect(TreeThemeFixture.hex(textView.backgroundColor) == Self.editorBackground)
            #expect(TreeThemeFixture.hex(textView.textColor) == "#657B83")
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
        try TreeThemeFixture.with([:]) {
            let corner = try pixel(of: jsonTab(), size: Self.paneSize, x: 4, fromBottom: 4)
            #expect(corner.alphaComponent < 0.02, "\(corner)")
        }
    }

    @Test("Under a theme the JSON tab's tree sits on the editor background")
    func jsonTabTakesTheEditorBackground() throws {
        try TreeThemeFixture.with([.editorBackground: Self.editorBackground]) {
            let themed = try filled(HexColor.color(Self.editorBackground))
            let corner = try pixel(of: jsonTab(), size: Self.paneSize, x: 4, fromBottom: 4)
            #expect(matches(corner, themed), "\(corner) against \(themed)")
        }
    }
}
