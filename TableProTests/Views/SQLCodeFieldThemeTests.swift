//
//  SQLCodeFieldThemeTests.swift
//  TableProTests
//
//  SQL and scripts inside a system sheet or form are code views: they wear the editor's colors while
//  the active theme sets them. The sheet or form around them stays on system colors.
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQL fields in sheets and forms follow the editor theme", .serialized)
@MainActor
struct SQLCodeFieldThemeTests {
    // MARK: - Filter SQL preview

    @Test("The filter's SQL preview is a code view on the editor background")
    func filterPreview() throws {
        try CodeSurfaceFixture.withBuiltInThemes {
            let window = CodeSurfaceFixture.host(SQLPreviewSheet(sql: "id = 1"), size: NSSize(width: 480, height: 300))
            let textView = try #require(CodeSurfaceFixture.textViews(in: window).first)
            #expect(textView.string == "id = 1")
            #expect(!textView.isEditable)
            #expect(textView.isSelectable)
            #expect(CodeSurfaceFixture.hex(textView.backgroundColor) == CodeSurfaceFixture.hex(.textBackgroundColor))

            try PaneThemeFixture.withEverySlotOverridden {
                #expect(CodeSurfaceFixture.hex(textView.backgroundColor) == "#FF00FF")
            }
            withExtendedLifetime(window) {}
        }
    }

    @Test("An empty filter still says it has no conditions")
    func filterPreviewEmpty() throws {
        try CodeSurfaceFixture.withBuiltInThemes {
            let window = CodeSurfaceFixture.host(SQLPreviewSheet(sql: ""), size: NSSize(width: 480, height: 300))
            let textView = try #require(CodeSurfaceFixture.textViews(in: window).first)
            #expect(textView.string == "(no conditions)")
            withExtendedLifetime(window) {}
        }
    }

    // MARK: - Maintenance preview

    private func maintenanceSheet(statements: [String]) -> MaintenanceSheet {
        MaintenanceSheet(
            operation: PluginMaintenanceOperation(name: "VACUUM", appliesTo: [.table], scope: .object),
            tableName: "orders",
            databaseName: "app",
            preview: { _ in statements },
            onExecute: { _ in }
        )
    }

    @Test("The maintenance preview is a code view sized to its statement")
    func maintenancePreview() throws {
        try CodeSurfaceFixture.withBuiltInThemes {
            let window = CodeSurfaceFixture.host(
                maintenanceSheet(statements: [#"VACUUM "orders""#]),
                size: NSSize(width: 420, height: 320)
            )
            let textView = try #require(CodeSurfaceFixture.textViews(in: window).first)
            #expect(textView.string == #"VACUUM "orders""#)
            let expected = MaintenanceSheet.previewHeight(for: textView.string, font: ThemeEngine.shared.editorFonts.font)
            let height = try #require(textView.enclosingScrollView?.frame.height)
            #expect(abs(height - expected) < 1)

            try PaneThemeFixture.withEverySlotOverridden {
                #expect(CodeSurfaceFixture.hex(textView.backgroundColor) == "#FF00FF")
            }
            withExtendedLifetime(window) {}
        }
    }

    @Test("The preview grows one line per statement line, up to a cap")
    func maintenancePreviewHeight() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let line = NSLayoutManager().defaultLineHeight(for: font)
        let inset: CGFloat = 24

        #expect(MaintenanceSheet.previewHeight(for: "VACUUM", font: font) == line + inset)
        #expect(MaintenanceSheet.previewHeight(for: "", font: font) == line + inset)
        #expect(MaintenanceSheet.previewHeight(for: "ANALYZE a;\nANALYZE b;\nANALYZE c", font: font) == 3 * line + inset)

        let long = Array(repeating: "ANALYZE t", count: 30).joined(separator: ";\n")
        let cap = CGFloat(MaintenanceSheet.previewMaxLines)
        #expect(MaintenanceSheet.previewHeight(for: long, font: font) == cap * line + inset)
    }

    // MARK: - Favorite query

    /// A folder list is passed so the dialog never reads the favorites store.
    private func favoriteDialog() -> FavoriteEditDialog {
        FavoriteEditDialog(
            connectionId: UUID(),
            initialQuery: "SELECT 'a'",
            folders: [SQLFavoriteFolder(name: "Reports")]
        )
    }

    private func favoriteQueryView(in window: NSWindow) throws -> NSTextView {
        try #require(CodeSurfaceFixture.textViews(in: window).first { $0.string == "SELECT 'a'" })
    }

    @Test("The favorite's query keeps the text field look and types straight quotes")
    func favoriteQueryDefaults() throws {
        try CodeSurfaceFixture.withBuiltInThemes {
            let window = CodeSurfaceFixture.host(favoriteDialog(), size: NSSize(width: 560, height: 580))
            let textView = try favoriteQueryView(in: window)
            #expect(textView.isEditable)
            #expect(textView.backgroundColor === NSColor.textBackgroundColor)
            #expect(textView.textColor == NSColor.textColor)
            #expect(textView.font == NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
            #expect(textView.textContainerInset == .zero)
            #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
            #expect(textView.usesFindBar)
            withExtendedLifetime(window) {}
        }
    }

    @Test("The favorite's query takes the editor colors from a theme and hands them back after")
    func favoriteQueryFollowsTheTheme() throws {
        try CodeSurfaceFixture.withBuiltInThemes {
            let window = CodeSurfaceFixture.host(favoriteDialog(), size: NSSize(width: 560, height: 580))
            let textView = try favoriteQueryView(in: window)

            try PaneThemeFixture.withEverySlotOverridden {
                #expect(CodeSurfaceFixture.hex(textView.backgroundColor) == "#FF00FF")
                #expect(CodeSurfaceFixture.hex(textView.textColor) == "#FF00FF")
            }

            #expect(textView.backgroundColor == NSColor.textBackgroundColor)
            #expect(textView.textColor == NSColor.textColor)
            withExtendedLifetime(window) {}
        }
    }

    // MARK: - Connection form fields

    private func startupEditor(_ style: TextValueEditor.Style) throws -> (NSWindow, NSTextView) {
        let window = CodeSurfaceFixture.host(
            StartupCommandsEditor(text: .constant("SET time_zone = 'UTC'"), style: style),
            size: NSSize(width: 360, height: 80)
        )
        return (window, try #require(CodeSurfaceFixture.textViews(in: window).first))
    }

    @Test("Startup Commands and Pre-Connect Script follow the editor theme")
    func startupCommandsFollowTheTheme() throws {
        try CodeSurfaceFixture.withBuiltInThemes {
            let (window, textView) = try startupEditor(.code)
            #expect(textView.backgroundColor === NSColor.textBackgroundColor)
            #expect(textView.enclosingScrollView?.borderType == .bezelBorder)

            try PaneThemeFixture.withEverySlotOverridden {
                #expect(CodeSurfaceFixture.hex(textView.backgroundColor) == "#FF00FF")
                #expect(CodeSurfaceFixture.hex(textView.textColor) == "#FF00FF")
            }

            #expect(textView.backgroundColor == NSColor.textBackgroundColor)
            withExtendedLifetime(window) {}
        }
    }

    @Test("AI Rules is prose and keeps the system text colors under any theme")
    func aiRulesStaysPlain() throws {
        try CodeSurfaceFixture.withBuiltInThemes {
            let (window, textView) = try startupEditor(.plain)
            try PaneThemeFixture.withEverySlotOverridden {
                #expect(textView.backgroundColor === NSColor.textBackgroundColor)
                #expect(textView.textColor === NSColor.textColor)
            }
            withExtendedLifetime(window) {}
        }
    }

    // MARK: - Rewind statements

    private static let rewindSize = NSSize(width: 320, height: 140)

    private func rewindStatements() -> RewindStatementList {
        RewindStatementList(statements: [
            "UPDATE orders SET status = 'paid' WHERE id = 1;",
            "DELETE FROM orders WHERE id = 2;",
        ])
    }

    @Test("Rewind statements draw no background of their own and system text under a default theme")
    func rewindDefault() throws {
        try CodeSurfaceFixture.withBuiltInThemes {
            let bitmap = try #require(CodeSurfaceFixture.render(rewindStatements(), size: Self.rewindSize))
            let corner = try #require(CodeSurfaceFixture.color(in: bitmap, x: bitmap.pixelsWide - 4, y: bitmap.pixelsHigh - 4))
            #expect(corner.alphaComponent < 0.01)

            let window = CodeSurfaceFixture.host(rewindStatements(), size: Self.rewindSize)
            let snapshot = try #require(CodeSurfaceFixture.snapshot(window))
            #expect(CodeSurfaceFixture.magentaPixels(in: snapshot, rows: 0 ..< snapshot.pixelsHigh) == 0)
            withExtendedLifetime(window) {}
        }
    }

    @Test("Rewind statements sit on the editor background a theme sets")
    func rewindBackground() throws {
        try CodeSurfaceFixture.withOverrides([.editorBackground: "#FF00FF"]) {
            let bitmap = try #require(CodeSurfaceFixture.render(rewindStatements(), size: Self.rewindSize))
            let corner = try #require(CodeSurfaceFixture.color(in: bitmap, x: bitmap.pixelsWide - 4, y: bitmap.pixelsHigh - 4))
            #expect(CodeSurfaceFixture.isMagenta(corner), "drew \(corner)")
        }
    }

    @Test("Rewind statements take the editor text color a theme sets")
    func rewindText() throws {
        try CodeSurfaceFixture.withOverrides([.editorText: "#FF00FF"]) {
            let window = CodeSurfaceFixture.host(rewindStatements(), size: Self.rewindSize)
            let snapshot = try #require(CodeSurfaceFixture.snapshot(window))
            #expect(CodeSurfaceFixture.magentaPixels(in: snapshot, rows: 0 ..< snapshot.pixelsHigh) > 20)
            withExtendedLifetime(window) {}
        }
    }
}
