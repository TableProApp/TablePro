//
//  MaintenancePreviewSyntaxTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Statement previews highlight in the language they are written in", .serialized)
@MainActor
struct MaintenancePreviewSyntaxTests {
    private static let updateTable = #"UpdateTable {"TableName":"orders","DeletionProtectionEnabled":true}"#
    private static let backups =
        #"UpdateContinuousBackups {"PointInTimeRecoverySpecification":{"PointInTimeRecoveryEnabled":false},"TableName":"orders"}"#

    @Test("An action name followed by a JSON request body is previewed as JSON")
    func apiRequestsAreJSON() {
        #expect(MaintenanceSheet.previewSyntax(of: [Self.updateTable]) == .json)
        #expect(MaintenanceSheet.previewSyntax(of: [Self.backups]) == .json)
        #expect(MaintenanceSheet.previewSyntax(of: [Self.updateTable, Self.backups]) == .json)
    }

    @Test("SQL, shell commands and anything not wholly a JSON request keep the engine's highlighting")
    func everythingElseIsTheEngines() {
        #expect(MaintenanceSheet.previewSyntax(of: [#"VACUUM (ANALYZE) "orders""#]) == .engine)
        #expect(MaintenanceSheet.previewSyntax(of: ["OPTIMIZE TABLE `orders`", "ANALYZE TABLE `orders`"]) == .engine)
        #expect(MaintenanceSheet.previewSyntax(of: ["db.orders.reIndex()"]) == .engine)
        #expect(MaintenanceSheet.previewSyntax(of: [#"db.runCommand({"compact": "orders"})"#]) == .engine)
        #expect(MaintenanceSheet.previewSyntax(of: ["UpdateTable {TableName: orders}"]) == .engine)
        #expect(MaintenanceSheet.previewSyntax(of: [#"UpdateTable ["orders"]"#]) == .engine)
        #expect(MaintenanceSheet.previewSyntax(of: [#"{"TableName":"orders"}"#]) == .engine)
        #expect(MaintenanceSheet.previewSyntax(of: [Self.updateTable, "VACUUM orders"]) == .engine)
        #expect(MaintenanceSheet.previewSyntax(of: []) == .engine)
    }

    private func textView(in window: NSWindow) throws -> NSTextView {
        try #require(ThemeTestFixture.textViews(in: window).first)
    }

    private func hex(of fragment: String, in textView: NSTextView) throws -> String? {
        let range = (textView.string as NSString).range(of: fragment)
        try #require(range.location != NSNotFound)
        let color = textView.textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        return ThemeTestFixture.hex(color)
    }

    @Test("A JSON request is previewed in the query preview, colored the way the JSON editor colors it")
    func jsonRequestIsColoredAsJSON() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let palette = ThemeEngine.shared.palette
            let text = ThemeTestFixture.hex(palette[.editorText])
            let string = ThemeTestFixture.hex(palette[.syntaxString])
            let literal = ThemeTestFixture.hex(palette[.syntaxNull])
            try #require(Set([text, string, literal]).count == 3)

            let sheet = MaintenanceSheet(
                operation: PluginMaintenanceOperation(name: "Point-in-Time Recovery", appliesTo: [.table], scope: .object),
                tableName: "orders",
                databaseName: nil,
                databaseType: .dynamodb,
                preview: { _ in [Self.backups] },
                onExecute: { _ in }
            )
            let window = ThemeTestFixture.host(sheet, size: NSSize(width: 420, height: 360))
            let preview = try textView(in: window)

            #expect(preview.string == Self.backups)
            #expect(preview.accessibilityLabel() == String(localized: "Query preview"))
            #expect(try hex(of: "UpdateContinuousBackups", in: preview) == text)
            #expect(try hex(of: #""TableName""#, in: preview) == string)
            #expect(try hex(of: #""orders""#, in: preview) == string)
            #expect(try hex(of: "false", in: preview) == literal)
            withExtendedLifetime(window) {}
        }
    }

    @Test("JSON highlighting keeps a digit or a literal inside a string string-colored")
    func jsonStringsWinOverWhatTheyContain() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let palette = ThemeEngine.shared.palette
            let request = #"Scan {"Partition":"2024","Note":"null","Limit":-5,"Ratio":1.5e3,"Next":null}"#
            let window = ThemeTestFixture.host(
                HighlightedSQLTextView(sql: request, highlighting: .json),
                size: NSSize(width: 900, height: 120)
            )
            let preview = try textView(in: window)

            #expect(try hex(of: "2024", in: preview) == ThemeTestFixture.hex(palette[.syntaxString]))
            #expect(try hex(of: #"null","#, in: preview) == ThemeTestFixture.hex(palette[.syntaxString]))
            #expect(try hex(of: "-5", in: preview) == ThemeTestFixture.hex(palette[.syntaxNumber]))
            #expect(try hex(of: "1.5e3", in: preview) == ThemeTestFixture.hex(palette[.syntaxNumber]))
            #expect(try hex(of: "null}", in: preview) == ThemeTestFixture.hex(palette[.syntaxNull]))
            withExtendedLifetime(window) {}
        }
    }

    @Test("Switching the highlighting on unchanged text colors it again")
    func highlightingChangeRecolors() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let palette = ThemeEngine.shared.palette
            let host = NSHostingView(rootView: HighlightedSQLTextView(sql: Self.updateTable, databaseType: .mysql))
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 120)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let preview = try textView(in: window)
            try #require(try hex(of: #""orders""#, in: preview) != ThemeTestFixture.hex(palette[.syntaxString]))

            host.rootView = HighlightedSQLTextView(sql: Self.updateTable, databaseType: .mysql, highlighting: .json)
            host.layoutSubtreeIfNeeded()

            #expect(try hex(of: #""orders""#, in: preview) == ThemeTestFixture.hex(palette[.syntaxString]))
            withExtendedLifetime(window) {}
        }
    }

    // MARK: - Filter preview

    @Test("The filter preview highlights with the connection's own patterns")
    func filterPreviewUsesTheConnectionsPatterns() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .light) {
            let palette = ThemeEngine.shared.palette
            let clause = #"name = "abc""#

            let document = ThemeTestFixture.host(
                SQLPreviewSheet(sql: clause, databaseType: .mongodb),
                size: NSSize(width: 480, height: 300)
            )
            let documentText = try textView(in: document)
            #expect(try hex(of: #""abc""#, in: documentText) == ThemeTestFixture.hex(palette[.syntaxString]))

            let relational = ThemeTestFixture.host(
                SQLPreviewSheet(sql: clause, databaseType: .mysql),
                size: NSSize(width: 480, height: 300)
            )
            let relationalText = try textView(in: relational)
            #expect(try hex(of: #""abc""#, in: relationalText) == ThemeTestFixture.hex(palette[.editorText]))
            withExtendedLifetime((document, relational)) {}
        }
    }
}
