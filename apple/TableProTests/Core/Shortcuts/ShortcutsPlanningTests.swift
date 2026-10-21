//
//  ShortcutsPlanningTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ShortcutsPlanningTests {
    @Test("Database or Schema names a schema, a database or nothing, by what the engine has")
    func placementFollowsTheNamespaceKind() {
        #expect(ShortcutsCatalog.placement(of: "sales", kind: .schema) == .init(database: nil, schema: "sales"))
        #expect(ShortcutsCatalog.placement(of: "shop", kind: .database) == .init(database: "shop", schema: nil))
        #expect(ShortcutsCatalog.placement(of: "main", kind: .neither) == .init(database: nil, schema: nil))
        #expect(ShortcutsCatalog.placement(of: nil, kind: .database) == .init(database: nil, schema: nil))
        #expect(ShortcutsCatalog.placement(of: "", kind: .schema) == .init(database: nil, schema: nil))
    }

    @Test("Engines that group by schema list schemas, and one that switches databases lists databases")
    @MainActor
    func namespaceKindFollowsTheEngine() {
        #expect(ShortcutsCatalog.namespaceKind(of: .postgresql) == .schema)
        #expect(ShortcutsCatalog.namespaceKind(of: .mysql) == .database)
    }

    @Test("The table picker lists what can take a row, once each")
    func tablePickerSkipsWhatTakesNoRows() {
        let tables = [
            TableInfo(name: "orders", type: .table, rowCount: nil),
            TableInfo(name: "active_orders", type: .view, rowCount: nil),
            TableInfo(name: "order_totals", type: .materializedView, rowCount: nil),
            TableInfo(name: "order_seq", type: .sequence, rowCount: nil),
            TableInfo(name: "sqlite_master", type: .systemTable, rowCount: nil),
            TableInfo(name: "orders", type: .table, rowCount: nil)
        ]

        #expect(ShortcutsCatalog.insertableTableNames(tables) == ["active_orders", "orders"])
    }

    @Test("A Shortcuts channel calls itself Shortcuts, files its history under Shortcuts and says why a connection is refused")
    func shortcutsChannel() {
        let channel = ScriptQueryRunner.Channel.shortcuts

        #expect(channel.caller == .shortcuts)
        #expect(channel.historySource == .shortcuts)
        #expect(channel.refusal(for: .blocked).errorDescription == "External access is disabled for this connection")
        #expect(channel.refusal(for: nil).errorDescription == "That connection no longer exists in TablePro.")
    }

    @Test("An AppleScript channel keeps its source and still cannot tell a Blocked connection from a missing one")
    func appleScriptChannel() {
        let channel = ScriptQueryRunner.Channel.appleScript(client: "Script Editor")

        #expect(channel.caller == .appleScript(client: "Script Editor"))
        #expect(channel.historySource == .script)
        #expect(channel.refusal(for: .blocked).errorDescription == "No saved connection has that id.")
        #expect(channel.refusal(for: nil).errorDescription == "No saved connection has that id.")
    }

    private static let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: nil)

    @MainActor
    private static func writePlan(
        _ rows: [PayloadRow],
        columns: [ColumnInfo],
        type: DatabaseType = .postgresql
    ) throws -> (plan: DataWritePlan, rowCount: Int) {
        try ShortcutsRowWriter.writePlan(
            for: rows, table: "orders", scope: scope, columns: columns, databaseType: type, pluginDriver: nil
        )
    }

    @Test("Rows become the grid's parameterized INSERTs, leaving out generated, always-identity and empty key columns")
    @MainActor
    func insertStatementsSkipServerOwnedColumns() throws {
        let columns = [
            ColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true, identityKind: .byDefault),
            ColumnInfo(name: "serial", dataType: "integer", isNullable: false, isPrimaryKey: false, identityKind: .always),
            ColumnInfo(name: "total", dataType: "numeric", isNullable: true, isPrimaryKey: false, isGenerated: true),
            ColumnInfo(name: "note", dataType: "text", isNullable: true, isPrimaryKey: false)
        ]
        let rows = [
            PayloadRow(values: ["id": .text(""), "serial": .text("9"), "total": .text("1"), "note": .text("Ada")]),
            PayloadRow(values: ["id": .text("7"), "note": .null])
        ]

        let (plan, rowCount) = try Self.writePlan(rows, columns: columns)

        #expect(rowCount == 2)
        #expect(plan.steps.map(\.statement.sql) == [
            #"INSERT INTO "orders" ("note") VALUES ($1)"#,
            #"INSERT INTO "orders" ("id", "note") VALUES ($1, $2)"#
        ])
        #expect(plan.steps.map(\.expectedRowCount) == [1, 1])
        #expect(plan.steps[0].statement.parameters.map { $0 as? String } == ["Ada"])
        #expect(plan.steps[1].statement.parameters.count == 2)
        #expect(plan.steps[1].statement.parameters[0] as? String == "7")
        #expect(plan.steps[1].statement.parameters[1] == nil)
    }

    @Test("A key that names no column refuses the whole payload")
    @MainActor
    func unknownColumnRefuses() {
        let columns = [ColumnInfo(name: "note", dataType: "text", isNullable: true, isPrimaryKey: false)]

        #expect(throws: IntentDataError.unknownColumns(["nope"], "orders")) {
            try Self.writePlan([PayloadRow(values: ["nope": .text("x")])], columns: columns)
        }
    }

    @Test("A table whose columns cannot be read refuses the payload")
    @MainActor
    func noColumnsRefuses() {
        #expect(throws: IntentDataError.noColumns("orders")) {
            try Self.writePlan([PayloadRow(values: ["note": .text("x")])], columns: [])
        }
    }

    @Test("A payload with nothing to write refuses instead of inserting an empty row")
    @MainActor
    func emptyPayloadRefuses() {
        let columns = [ColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true)]

        #expect(throws: IntentDataError.noInsertableValues("orders")) {
            try Self.writePlan([PayloadRow(values: ["id": .text("")])], columns: columns)
        }
    }

    @Test("Every full source set the app shipped widens to the current one")
    func earlierFullHistorySetsWiden() {
        let beforeShortcuts: Set<QueryHistorySource> = [
            .editor, .explain, .tableBrowse, .rowEdit, .structureDDL, .dataImport, .mcp, .script
        ]

        #expect(QueryHistorySource.migratingStoredSelection(beforeShortcuts) == Set(QueryHistorySource.allCases))
        #expect(QueryHistorySource.allCases.contains(.shortcuts))
        #expect(QueryHistorySource.shortcuts.rawValue == "shortcuts")
    }
}

struct ConnectionEntityQueryTests {
    @Test("A listed connection resolves whole, a Blocked one by name only, and a deleted one not at all")
    func resolvesByIdentifier() {
        guard #available(macOS 14.0, *) else { return }
        var listed = DatabaseConnection(name: "Prod", host: "db.example.com", database: "shop", type: .postgresql)
        listed.externalAccess = .readOnly
        var blocked = DatabaseConnection(name: "Payroll", host: "hr.example.com", database: "hr", type: .postgresql)
        blocked.externalAccess = .blocked
        let listings = ExternalConnectionDirectory.listings(
            connections: [listed, blocked], groups: [], tags: [], live: [:], defaultPolicy: .askEachTime
        )

        let entities = ConnectionEntityQuery.entities(
            for: [listed.id, blocked.id, UUID()],
            listings: listings,
            stored: [listed, blocked]
        )

        #expect(entities.map(\.id) == [listed.id, blocked.id])
        #expect(entities.first?.host == "db.example.com")
        #expect(entities.last?.name == "Payroll")
        #expect(entities.last?.host.isEmpty == true)
        #expect(entities.last?.databaseType.isEmpty == true)
        #expect(listings.map(\.id) == [listed.id])
    }
}
