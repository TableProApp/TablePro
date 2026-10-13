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
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let window = ThemeTestFixture.host(SQLPreviewSheet(sql: "id = 1", databaseType: .mysql), size: NSSize(width: 480, height: 300))
            let textView = try #require(ThemeTestFixture.textViews(in: window).first)
            #expect(textView.string == "id = 1")
            #expect(!textView.isEditable)
            #expect(textView.isSelectable)
            #expect(ThemeTestFixture.hex(textView.backgroundColor) == ThemeTestFixture.hex(.textBackgroundColor))

            try ThemeTestFixture.withEverySlotOverridden {
                #expect(ThemeTestFixture.hex(textView.backgroundColor) == "#FF00FF")
            }
            withExtendedLifetime(window) {}
        }
    }

    @Test("An empty filter still says it has no conditions")
    func filterPreviewEmpty() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let window = ThemeTestFixture.host(SQLPreviewSheet(sql: "", databaseType: .mysql), size: NSSize(width: 480, height: 300))
            let textView = try #require(ThemeTestFixture.textViews(in: window).first)
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
            databaseType: .postgresql,
            preview: { _ in statements },
            onExecute: { _ in }
        )
    }

    @Test("The maintenance preview is a code view sized to its statement")
    func maintenancePreview() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let window = ThemeTestFixture.host(
                maintenanceSheet(statements: [#"VACUUM "orders""#]),
                size: NSSize(width: 420, height: 320)
            )
            let textView = try #require(ThemeTestFixture.textViews(in: window).first)
            #expect(textView.string == #"VACUUM "orders""#)
            let scrollView = try #require(textView.enclosingScrollView)
            let expected = HighlightedSQLTextView.fittedHeight(
                of: textView.string,
                font: ThemeEngine.shared.editorFonts.font,
                width: scrollView.frame.width,
                inset: textView.textContainerInset,
                lineFragmentPadding: textView.textContainer?.lineFragmentPadding ?? 0,
                maxLines: MaintenanceSheet.previewMaxLines
            )
            #expect(abs(scrollView.frame.height - expected) < 1)

            try ThemeTestFixture.withEverySlotOverridden {
                #expect(ThemeTestFixture.hex(textView.backgroundColor) == "#FF00FF")
            }
            withExtendedLifetime(window) {}
        }
    }

    @Test("The preview grows one line per wrapped line, up to a cap")
    func maintenancePreviewHeight() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let line = NSLayoutManager().defaultLineHeight(for: font)
        let inset: CGFloat = 24
        func height(_ sql: String, width: CGFloat = 1_000) -> CGFloat {
            HighlightedSQLTextView.fittedHeight(
                of: sql,
                font: font,
                width: width,
                inset: NSSize(width: 12, height: 12),
                lineFragmentPadding: 5,
                maxLines: MaintenanceSheet.previewMaxLines
            )
        }

        #expect(height("VACUUM") == line + inset)
        #expect(height("") == line + inset)
        #expect(height("ANALYZE a;\nANALYZE b;\nANALYZE c") == 3 * line + inset)

        let long = Array(repeating: "ANALYZE t", count: 30).joined(separator: ";\n")
        let cap = CGFloat(MaintenanceSheet.previewMaxLines)
        #expect(height(long) == cap * line + inset)

        let wide = Array(repeating: "ANALYZE", count: 20).joined(separator: " ")
        #expect(height(wide, width: 1_000) == 2 * line + inset)
        #expect(height(wide, width: 300) >= 4 * line + inset)
        #expect(height(wide, width: 300) <= cap * line + inset)
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
        try #require(ThemeTestFixture.textViews(in: window).first { $0.string == "SELECT 'a'" })
    }

    @Test("The favorite's query keeps the text field look and types straight quotes")
    func favoriteQueryDefaults() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let window = ThemeTestFixture.host(favoriteDialog(), size: NSSize(width: 560, height: 580))
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
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let window = ThemeTestFixture.host(favoriteDialog(), size: NSSize(width: 560, height: 580))
            let textView = try favoriteQueryView(in: window)

            try ThemeTestFixture.withEverySlotOverridden {
                #expect(ThemeTestFixture.hex(textView.backgroundColor) == "#FF00FF")
                #expect(ThemeTestFixture.hex(textView.textColor) == "#FF00FF")
            }

            #expect(textView.backgroundColor == NSColor.textBackgroundColor)
            #expect(textView.textColor == NSColor.textColor)
            withExtendedLifetime(window) {}
        }
    }

    // MARK: - Connection form fields

    private func startupEditor(_ style: TextValueEditor.Style) throws -> (NSWindow, NSTextView) {
        let window = ThemeTestFixture.host(
            StartupCommandsEditor(text: .constant("SET time_zone = 'UTC'"), style: style),
            size: NSSize(width: 360, height: 80)
        )
        return (window, try #require(ThemeTestFixture.textViews(in: window).first))
    }

    @Test("Startup Commands and Pre-Connect Script follow the editor theme")
    func startupCommandsFollowTheTheme() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let (window, textView) = try startupEditor(.code)
            #expect(textView.backgroundColor === NSColor.textBackgroundColor)
            #expect(textView.enclosingScrollView?.borderType == .bezelBorder)

            try ThemeTestFixture.withEverySlotOverridden {
                #expect(ThemeTestFixture.hex(textView.backgroundColor) == "#FF00FF")
                #expect(ThemeTestFixture.hex(textView.textColor) == "#FF00FF")
            }

            #expect(textView.backgroundColor == NSColor.textBackgroundColor)
            withExtendedLifetime(window) {}
        }
    }

    @Test("AI Rules is prose and keeps the system text colors under any theme")
    func aiRulesStaysPlain() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let (window, textView) = try startupEditor(.plain)
            try ThemeTestFixture.withEverySlotOverridden {
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
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let bitmap = try ThemeTestFixture.bitmap(
                of: rewindStatements().frame(width: Self.rewindSize.width, height: Self.rewindSize.height),
                colorScheme: .light
            )
            let corner = try #require(ThemeTestFixture.pixel(bitmap, x: bitmap.pixelsWide - 4, y: bitmap.pixelsHigh - 4))
            #expect(corner.alphaComponent < 0.01)

            let window = ThemeTestFixture.host(rewindStatements(), size: Self.rewindSize)
            let snapshot = try #require(ThemeTestFixture.snapshot(window))
            #expect(ThemeTestFixture.count(in: snapshot, where: ThemeTestFixture.isMagenta) == 0)
            withExtendedLifetime(window) {}
        }
    }

    @Test("Rewind statements sit on the editor background a theme sets")
    func rewindBackground() throws {
        try ThemeTestFixture.adopting(ThemeTestFixture.pair([.editorBackground: "#FF00FF"]), appearance: .light) {
            let bitmap = try ThemeTestFixture.bitmap(
                of: rewindStatements().frame(width: Self.rewindSize.width, height: Self.rewindSize.height),
                colorScheme: .light
            )
            let corner = try #require(ThemeTestFixture.pixel(bitmap, x: bitmap.pixelsWide - 4, y: bitmap.pixelsHigh - 4))
            #expect(ThemeTestFixture.isMagenta(corner), "drew \(corner)")
        }
    }

    @Test("Rewind statements take the editor text color a theme sets")
    func rewindText() throws {
        try ThemeTestFixture.adopting(ThemeTestFixture.pair([.editorText: "#FF00FF"]), appearance: .light) {
            let window = ThemeTestFixture.host(rewindStatements(), size: Self.rewindSize)
            let snapshot = try #require(ThemeTestFixture.snapshot(window))
            #expect(ThemeTestFixture.count(in: snapshot, where: ThemeTestFixture.isMagenta) > 20)
            withExtendedLifetime(window) {}
        }
    }
}
