//
//  RowEditingCoordinatorUUIDKeyTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct RowEditingCoordinatorUUIDKeyTests {
    private static let columns = ["id", "name"]

    private let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(type: .postgresql))

    private func makeCoordinator(
        keyType: ColumnType = .text(rawType: "uuid"),
        columnDefaults: [String: String?] = [:]
    ) -> MainContentCoordinator {
        var tab = QueryTab(title: "events", query: "SELECT * FROM events", tabType: .table, tableName: "events")
        tab.execution.lastExecutedAt = Date()
        tab.display.resultsViewMode = .data
        fixture.addTab(
            tab,
            rows: TableRows.from(
                queryRows: [[.text("0b1e7c9a-58f4-4b8e-9c55-1f1c86f0a001"), .text("a")]],
                columns: Self.columns,
                columnTypes: [keyType, .text(rawType: "text")],
                columnDefaults: columnDefaults,
                hasAuthoritativeSchema: true
            )
        )
        fixture.coordinator.changeManager.configureForTable(
            tableName: "events",
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: []
        )
        return fixture.coordinator
    }

    private func lastRow(of coordinator: MainContentCoordinator) -> Row? {
        guard let tabId = coordinator.tabManager.selectedTab?.id else { return nil }
        return coordinator.tabSessionRegistry.tableRows(for: tabId).rows.last
    }

    private func isFreshUUID(_ value: PluginCellValue?) -> Bool {
        guard let text = value?.asText, UUID(uuidString: text) != nil else { return false }
        return text == text.lowercased() && text != "0b1e7c9a-58f4-4b8e-9c55-1f1c86f0a001"
    }

    // The reporter's table: `id uuid PRIMARY KEY` with no default, which a new row sent as NULL.
    @Test("Add Row on a uuid key with no default stages a fresh UUID in it")
    func addRowPrefillsTheUUIDKey() throws {
        let coordinator = makeCoordinator()

        coordinator.addNewRow()

        let row = try #require(lastRow(of: coordinator))
        #expect(row.id.isInserted)
        #expect(isFreshUUID(row.values[0]))
        #expect(row.values[1] == .null)
    }

    @Test("Add Row on a uuid key the server fills keeps DEFAULT")
    func addRowKeepsTheServerDefault() throws {
        let coordinator = makeCoordinator(columnDefaults: ["id": "gen_random_uuid()"])

        coordinator.addNewRow()

        #expect(try #require(lastRow(of: coordinator)).values[0] == .text("__DEFAULT__"))
    }

    @Test("Add Row on an integer key leaves it as before")
    func addRowOnAnIntegerKey() throws {
        let coordinator = makeCoordinator(keyType: .integer(rawType: "int4"))

        coordinator.addNewRow()

        #expect(try #require(lastRow(of: coordinator)).values[0] == .null)
    }

    @Test("Duplicate gives the copy a fresh UUID key")
    func duplicatePrefillsTheUUIDKey() throws {
        let coordinator = makeCoordinator()

        coordinator.duplicateRow(.existing(0))

        let row = try #require(lastRow(of: coordinator))
        #expect(isFreshUUID(row.values[0]))
        #expect(row.values[1] == .text("a"))
    }

    // MARK: - Which keys

    private func forms(
        types: [ColumnType] = [.text(rawType: "uuid"), .text(rawType: "text")],
        rows: [[PluginCellValue]] = [],
        foreignKeys: [String: ForeignKeyInfo] = [:],
        declaredTypes: [String: String] = [:],
        displayFormats: [ValueDisplayFormat?] = [],
        writer: CellWriterSupport = .host,
        isWritable: Bool = true
    ) -> [Int: UUIDCellForm] {
        RowEditingCoordinator.uuidKeyForms(
            in: TableRows.from(
                queryRows: rows,
                columns: Self.columns,
                columnTypes: types,
                columnForeignKeys: foreignKeys,
                columnDeclaredTypes: declaredTypes
            ),
            primaryKeyColumns: ["id"],
            displayFormats: displayFormats,
            databaseType: .mysql,
            writer: writer,
            isColumnWritable: { _ in isWritable }
        )
    }

    @Test("A uuid key gets the hyphenated form")
    func uuidKey() {
        #expect(forms() == [0: .hyphenated])
    }

    @Test("A foreign key, a read-only key, or a writer without UUID text gets no UUID")
    func keysThatGetNoUUID() {
        let foreignKey = ForeignKeyInfo(name: "fk", column: "id", referencedTable: "parent", referencedColumn: "id")
        #expect(forms(foreignKeys: ["id": foreignKey]).isEmpty)
        #expect(forms(isWritable: false).isEmpty)
        #expect(forms(writer: .none).isEmpty)
        #expect(forms(types: [.integer(rawType: "INT"), .text(rawType: "text")]).isEmpty)
    }

    @Test("A CHAR key shown as UUID takes the compact form when its values are 32 hex digits")
    func compactCharKey() {
        let types: [ColumnType] = [.text(rawType: "CHAR"), .text(rawType: "VARCHAR")]
        #expect(forms(types: types).isEmpty)
        #expect(forms(types: types, displayFormats: [.uuid, nil]) == [0: .hyphenated])
        #expect(
            forms(
                types: types,
                rows: [[.text("0b1e7c9a58f44b8e9c551f1c86f0a001"), .text("a")]],
                displayFormats: [.uuid, nil]
            ) == [0: .compact]
        )
    }

    @Test("An empty table's CHAR key shown as UUID takes the compact form when its schema says CHAR(32)")
    func compactCharKeyFromSchema() {
        let types: [ColumnType] = [.text(rawType: "CHAR"), .text(rawType: "VARCHAR")]
        #expect(
            forms(types: types, declaredTypes: ["id": "CHAR(32)"], displayFormats: [.uuid, nil]) == [0: .compact]
        )
        #expect(
            forms(types: types, declaredTypes: ["id": "CHAR(36)"], displayFormats: [.uuid, nil]) == [0: .hyphenated]
        )
    }

    @Test("A BINARY(16) key shown as UUID takes 16 bytes")
    func binaryKey() {
        let types: [ColumnType] = [.blob(rawType: "BINARY(16)"), .text(rawType: "VARCHAR")]
        #expect(forms(types: types, displayFormats: [.uuid, nil]) == [0: .bytes])
    }
}
