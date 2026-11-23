//
//  InspectorDetachedStagingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

// An inspector value window writes to the tab and records it opened on, never to whatever the inspector shows now.
@MainActor
struct InspectorDetachedStagingTests {
    private static let userColumns = ["id", "name", "created_at", "doc"]
    private static let userTypes: [ColumnType] = [
        .integer(rawType: "int4"), .text(rawType: "varchar"), .timestamp(rawType: "timestamptz"), .json(rawType: "jsonb")
    ]

    private let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(type: .postgresql))
    private let editState = MultiRowEditState()

    private static func userRows(_ names: [String]) -> TableRows {
        TableRows.from(
            queryRows: names.enumerated().map { index, name in
                [.text("\(index + 1)"), .text(name), .text("2024-01-01 00:00:00+00"), .text("{\"a\":1}")]
            },
            columns: userColumns,
            columnTypes: userTypes,
            columnNullable: ["created_at": false],
            hasAuthoritativeSchema: true
        )
    }

    private func addTableTab(_ table: String, rows: TableRows, columns: [String]) -> UUID {
        var tab = QueryTab(title: table, query: "SELECT * FROM \(table)", tabType: .table, tableName: table)
        tab.execution.lastExecutedAt = Date()
        fixture.addTab(tab, rows: rows)
        fixture.coordinator.changeManager(forTab: tab.id).configureForTable(
            tableName: table,
            columns: columns,
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: [],
            triggerReload: false
        )
        return tab.id
    }

    // Wired the way the inspector wires it: configured from the selected tab, staged through the coordinator.
    private func show(tab tabId: UUID, rowIDs: [RowID]) {
        let rows = fixture.coordinator.tabSessionRegistry.tableRows(for: tabId)
        let selected = rowIDs.compactMap { rows.row(withID: $0) }
        editState.detachedStager = fixture.coordinator.rowEditingCoordinator
        editState.configure(
            tabId: tabId,
            rowIDs: selected.map(\.id),
            allRows: selected.map { $0.values.map(\.asText) },
            columns: rows.columns,
            columnTypes: rows.columnTypes
        )
    }

    private func usersTab() -> UUID {
        addTableTab("users", rows: Self.userRows(["Alice", "Bob", "Carol"]), columns: Self.userColumns)
    }

    private func ordersTab() -> UUID {
        addTableTab(
            "orders",
            rows: TableRows.from(
                queryRows: [[.text("10"), .text("5.00")], [.text("11"), .text("7.50")]],
                columns: ["id", "total"],
                columnTypes: [.integer(rawType: "int4"), .text(rawType: "numeric")],
                hasAuthoritativeSchema: true
            ),
            columns: ["id", "total"]
        )
    }

    private func change(in tabId: UUID, rowID: RowID, column: Int) -> CellChange? {
        fixture.coordinator.changeManager(forTab: tabId).rowChanges
            .first { $0.rowID == rowID && $0.type == .update }?
            .cellChanges
            .first { $0.columnIndex == column }
    }

    private func value(in tabId: UUID, rowID: RowID, column: Int) -> PluginCellValue? {
        fixture.coordinator.tabSessionRegistry.tableRows(for: tabId).row(withID: rowID)?.values[column]
    }

    @Test("a window opened on one tab stages into that tab while another tab with the same row ids is shown")
    func stagesIntoItsOwnTabAfterATabSwitch() throws {
        let users = usersTab()
        show(tab: users, rowIDs: [.existing(1)])
        let target = try #require(editState.holdDetachedField(columnIndex: 1))

        let orders = ordersTab()
        show(tab: orders, rowIDs: [.existing(1)])
        #expect(editState.commitDetachedField("Zed", to: target))

        #expect(change(in: users, rowID: .existing(1), column: 1)?.newValue == .text("Zed"))
        #expect(value(in: users, rowID: .existing(1), column: 1) == .text("Zed"))
        #expect(!fixture.coordinator.changeManager(forTab: orders).hasChanges)
        #expect(value(in: orders, rowID: .existing(1), column: 1) == .text("7.50"))
    }

    @Test("a re-run that puts another record at the window's row id ends the window's edits")
    func refusesAReplacedRecord() throws {
        let users = usersTab()
        show(tab: users, rowIDs: [.existing(1)])
        let target = try #require(editState.holdDetachedField(columnIndex: 1))

        fixture.coordinator.setActiveTableRows(Self.userRows(["Carol", "Alice", "Bob"]), for: users)

        #expect(!editState.commitDetachedField("Zed", to: target))
        #expect(!fixture.coordinator.changeManager(forTab: users).hasChanges)
        #expect(value(in: users, rowID: .existing(1), column: 1) == .text("Alice"))
    }

    @Test("a row deleted after the window opened takes no edit")
    func refusesADeletedRow() throws {
        let users = usersTab()
        show(tab: users, rowIDs: [.existing(1)])
        let target = try #require(editState.holdDetachedField(columnIndex: 1))
        let original = try #require(fixture.coordinator.tabSessionRegistry.tableRows(for: users).row(withID: .existing(1)))

        fixture.coordinator.changeManager(forTab: users).recordRowDeletion(rowID: .existing(1), originalRow: Array(original.values))

        #expect(!editState.commitDetachedField("Zed", to: target))
        #expect(change(in: users, rowID: .existing(1), column: 1) == nil)
    }

    @Test("a closed tab ends the window's edits")
    func refusesAClosedTab() throws {
        let users = usersTab()
        show(tab: users, rowIDs: [.existing(1)])
        let target = try #require(editState.holdDetachedField(columnIndex: 1))
        let orders = ordersTab()
        show(tab: orders, rowIDs: [.existing(0)])

        fixture.tabManager.tabs.removeAll { $0.id == users }

        #expect(!editState.commitDetachedField("Zed", to: target))
    }

    @Test("typing goes on across the window's own writes, as one typed run")
    func ownWritesKeepTheHold() throws {
        let users = usersTab()
        show(tab: users, rowIDs: [.existing(1)])
        let target = try #require(editState.holdDetachedField(columnIndex: 1))
        show(tab: ordersTab(), rowIDs: [.existing(0)])

        #expect(editState.commitDetachedField("Z", to: target))
        #expect(editState.commitDetachedField("Ze", to: target))

        #expect(change(in: users, rowID: .existing(1), column: 1)?.newValue == .text("Ze"))
        #expect(change(in: users, rowID: .existing(1), column: 1)?.oldValue == .text("Bob"))
    }

    // Two windows on one record: the first one's write must not read as another record to the second.
    @Test("a SQL function typed in the window is staged as SQL by the window's own tab, plain text stays text")
    func typedFunctionIsPromotedByTheTargetTab() throws {
        let users = usersTab()
        show(tab: users, rowIDs: [.existing(1)])
        let timestamp = try #require(editState.holdDetachedField(columnIndex: 2))
        let name = try #require(editState.holdDetachedField(columnIndex: 1))
        show(tab: ordersTab(), rowIDs: [.existing(0)])

        #expect(editState.commitDetachedField("CURRENT_TIMESTAMP", to: timestamp))
        #expect(editState.commitDetachedField("now()", to: name))

        let changes = fixture.coordinator.changeManager(forTab: users)
        #expect(change(in: users, rowID: .existing(1), column: 2)?.newValue == .text("CURRENT_TIMESTAMP"))
        #expect(changes.isExpression(rowID: .existing(1), columnIndex: 2))
        #expect(change(in: users, rowID: .existing(1), column: 1)?.newValue == .text("now()"))
        #expect(!changes.isExpression(rowID: .existing(1), columnIndex: 1))
    }

    @Test("a cleared JSON value goes to the window's rows as NULL, a cleared NOT NULL value stages nothing")
    func clearedValuesFollowTheTargetColumn() throws {
        let users = usersTab()
        show(tab: users, rowIDs: [.existing(1)])
        let doc = try #require(editState.holdDetachedField(columnIndex: 3))
        let createdAt = try #require(editState.holdDetachedField(columnIndex: 2))
        show(tab: ordersTab(), rowIDs: [.existing(0)])

        #expect(editState.commitDetachedField("", to: createdAt))
        #expect(change(in: users, rowID: .existing(1), column: 2) == nil)

        #expect(editState.commitDetachedField("", to: doc))
        #expect(change(in: users, rowID: .existing(1), column: 3)?.newValue == .null)
    }
}
