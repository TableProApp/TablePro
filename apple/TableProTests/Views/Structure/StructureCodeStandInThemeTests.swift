//
//  StructureCodeStandInThemeTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

/// A state that replaces a DDL or statement text view keeps the editor's background under a theme,
/// and draws nothing of its own otherwise, so the pane behind it shows as it did.
@MainActor
struct StructureCodeStandInThemeTests {
    private static let size = CGSize(width: 320, height: 240)
    private static let corner = CGPoint(x: 0.03, y: 0.05)

    private func expectEditorStandIn(_ view: some View) throws {
        let framed = view.frame(width: Self.size.width, height: Self.size.height)
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let unthemed = try ThemeTestFixture.color(of: framed, at: Self.corner, colorScheme: .dark)
            #expect(unthemed.alphaComponent < 0.05, "the default pair drew \(unthemed)")

            try ThemeTestFixture.adopt([.editorBackground: ThemeTestFixture.editorHex], appearance: .dark)
            let editor = try ThemeTestFixture.filled(hex: ThemeTestFixture.editorHex, colorScheme: .dark)
            let themed = try ThemeTestFixture.color(of: framed, at: Self.corner, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(themed, editor), "drew \(themed), editor \(editor)")

            try ThemeTestFixture.adopt([
                .windowBackdrop: ThemeTestFixture.windowHex,
                .gridBackground: ThemeTestFixture.gridHex,
            ], appearance: .dark)
            let unrelated = try ThemeTestFixture.color(of: framed, at: Self.corner, colorScheme: .dark)
            #expect(unrelated.alphaComponent < 0.05, "another slot drew \(unrelated)")
        }
    }

    @Test("No DDL available stands in for the DDL view on the editor background")
    func missingDDL() throws {
        try expectEditorStandIn(StructureDDLStandIn())
    }

    @Test("The Create Table SQL Preview placeholder sits on the editor background")
    func createTablePlaceholder() throws {
        try expectEditorStandIn(CreateTableSQLPreviewStandIn(content: .message(nil)))
        try expectEditorStandIn(CreateTableSQLPreviewStandIn(content: .message("Add a column first")))
    }

    @Test("The Create Table SQL Preview progress sits on the editor background")
    func createTableComposing() throws {
        try expectEditorStandIn(CreateTableSQLPreviewStandIn(content: .composing))
    }

    @Test("The form's preview message sits on the editor background")
    func formPreviewMessage() throws {
        try expectEditorStandIn(CreateTableFormPreview(preview: .message("No columns yet"), databaseType: .mysql))
    }
}
