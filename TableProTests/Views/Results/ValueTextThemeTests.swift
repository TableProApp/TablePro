//
//  ValueTextThemeTests.swift
//  TableProTests
//
//  The text views that show a stored value or server text wear the editor's colors while the active
//  theme sets them, and under a default theme draw exactly the system colors they always drew.
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@Suite("Value text views follow the editor theme", .serialized)
@MainActor
struct ValueTextThemeTests {
    private static let size = NSSize(width: 480, height: 320)

    @Test("Server output draws label text on the text background until a theme sets the editor colors")
    func serverOutput() throws {
        try CodeSurfaceFixture.withBuiltInThemes {
            let window = CodeSurfaceFixture.host(ServerOutputTextView(text: "NOTICE: done"), size: Self.size)
            let textView = try #require(CodeSurfaceFixture.textViews(in: window).first)
            #expect(textView.backgroundColor === NSColor.textBackgroundColor)
            #expect(textView.textColor == NSColor.labelColor)

            try PaneThemeFixture.withEverySlotOverridden {
                #expect(CodeSurfaceFixture.hex(textView.backgroundColor) == "#FF00FF")
                #expect(CodeSurfaceFixture.hex(textView.textColor) == "#FF00FF")
                #expect(CodeSurfaceFixture.hex(textView.insertionPointColor) == "#FF00FF")
            }

            #expect(textView.backgroundColor == NSColor.textBackgroundColor)
            #expect(textView.textColor == NSColor.labelColor)
            #expect(textView.string == "NOTICE: done")
            withExtendedLifetime(window) {}
        }
    }

    @Test("The hex dump keeps its secondary text and the hex field its label text under a default theme")
    func hexDefaults() throws {
        try CodeSurfaceFixture.withBuiltInThemes {
            let window = CodeSurfaceFixture.host(
                HexEditorBody(initialValue: "Hello", isEditable: true, onDismiss: {}),
                size: Self.size
            )
            let (dump, input) = try hexTextViews(in: window)
            #expect(dump.backgroundColor === NSColor.textBackgroundColor)
            #expect(dump.textColor == NSColor.secondaryLabelColor)
            #expect(input.backgroundColor === NSColor.textBackgroundColor)
            #expect(input.textColor == NSColor.labelColor)
            withExtendedLifetime(window) {}
        }
    }

    @Test("Both hex text views take the editor colors from a theme and hand them back after")
    func hexFollowsTheTheme() throws {
        try CodeSurfaceFixture.withBuiltInThemes {
            let window = CodeSurfaceFixture.host(
                HexEditorBody(initialValue: "Hello", isEditable: true, onDismiss: {}),
                size: Self.size
            )
            let (dump, input) = try hexTextViews(in: window)

            try PaneThemeFixture.withEverySlotOverridden {
                for textView in [dump, input] {
                    #expect(CodeSurfaceFixture.hex(textView.backgroundColor) == "#FF00FF")
                    #expect(CodeSurfaceFixture.hex(textView.textColor) == "#FF00FF")
                }
            }

            #expect(dump.backgroundColor == NSColor.textBackgroundColor)
            #expect(dump.textColor == NSColor.secondaryLabelColor)
            #expect(input.textColor == NSColor.labelColor)
            withExtendedLifetime(window) {}
        }
    }

    @Test("The text viewer and image source editor follow the editor theme")
    func valueSourceEditorFollowsTheTheme() throws {
        try CodeSurfaceFixture.withBuiltInThemes {
            let window = CodeSurfaceFixture.host(
                ValueSourceEditor(text: .constant("<svg/>"), isEditable: false),
                size: Self.size
            )
            let textView = try #require(CodeSurfaceFixture.textViews(in: window).first)
            #expect(textView.backgroundColor === NSColor.textBackgroundColor)
            #expect(textView.font == ThemeEngine.shared.valueFont)

            try PaneThemeFixture.withEverySlotOverridden {
                #expect(CodeSurfaceFixture.hex(textView.backgroundColor) == "#FF00FF")
                #expect(CodeSurfaceFixture.hex(textView.textColor) == "#FF00FF")
            }

            #expect(textView.backgroundColor == NSColor.textBackgroundColor)
            #expect(textView.textColor == NSColor.textColor)
            withExtendedLifetime(window) {}
        }
    }

    // MARK: - PHP raw text

    /// Long enough to wrap well below the mode picker.
    private func phpRaw() -> some View {
        let entries = (0 ..< 24).map { #"i:\#($0);s:5:"hello";"# }.joined()
        return PhpViewerView(rawValue: "a:24:{\(entries)}", initialViewMode: .raw)
    }

    /// Below the mode picker, so a count covers the raw text area only.
    private static let pickerFraction = 0.2

    @Test("PHP raw text draws no background of its own and system text under a default theme")
    func phpRawDefault() throws {
        try CodeSurfaceFixture.withBuiltInThemes {
            let bitmap = try #require(CodeSurfaceFixture.render(phpRaw(), size: Self.size))
            let corner = try #require(CodeSurfaceFixture.color(in: bitmap, x: bitmap.pixelsWide - 4, y: bitmap.pixelsHigh - 4))
            #expect(corner.alphaComponent < 0.01)

            let window = CodeSurfaceFixture.host(phpRaw(), size: Self.size)
            let snapshot = try #require(CodeSurfaceFixture.snapshot(window))
            let rows = CodeSurfaceFixture.rows(of: snapshot, below: Self.pickerFraction)
            #expect(CodeSurfaceFixture.magentaPixels(in: snapshot, rows: rows) == 0)
            withExtendedLifetime(window) {}
        }
    }

    @Test("PHP raw text sits on the editor background a theme sets")
    func phpRawBackground() throws {
        try CodeSurfaceFixture.withOverrides([.editorBackground: "#FF00FF"]) {
            let bitmap = try #require(CodeSurfaceFixture.render(phpRaw(), size: Self.size))
            let corner = try #require(CodeSurfaceFixture.color(in: bitmap, x: bitmap.pixelsWide - 4, y: bitmap.pixelsHigh - 4))
            #expect(CodeSurfaceFixture.isMagenta(corner), "drew \(corner)")
        }
    }

    @Test("PHP raw text takes the editor text color a theme sets")
    func phpRawText() throws {
        try CodeSurfaceFixture.withOverrides([.editorText: "#FF00FF"]) {
            let window = CodeSurfaceFixture.host(phpRaw(), size: Self.size)
            let snapshot = try #require(CodeSurfaceFixture.snapshot(window))
            let rows = CodeSurfaceFixture.rows(of: snapshot, below: Self.pickerFraction)
            #expect(CodeSurfaceFixture.magentaPixels(in: snapshot, rows: rows) > 20)
            withExtendedLifetime(window) {}
        }
    }

    // MARK: - Helpers

    private func hexTextViews(in window: NSWindow) throws -> (dump: NSTextView, input: NSTextView) {
        let textViews = CodeSurfaceFixture.textViews(in: window)
        #expect(textViews.count == 2)
        let dump = try #require(textViews.first { !$0.isEditable })
        let input = try #require(textViews.first { $0.isEditable })
        return (dump, input)
    }
}
