//
//  TableLoadReloadCountTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct TableLoadReloadCountTests {
    private let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(database: "shop"))

    private func mountedTab() -> (tab: QueryTab, mount: DataTabGridMountStub) {
        let tab = fixture.addTab(QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users"))
        let mount = DataTabGridMountStub()
        fixture.coordinator.gridModel(forTab: tab.id).attach(mount)
        return (tab, mount)
    }

    private func load(_ tab: QueryTab) {
        fixture.coordinator.applyPhase1Result(
            tabId: tab.id,
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: "int"), .text(rawType: "text")],
            rows: [[.text("1"), .text("ann")], [.text("2"), .text("bob")]],
            executionTime: 0,
            rowsAffected: 0,
            statusMessage: nil,
            tableName: "users",
            isEditable: true,
            metadata: nil,
            hasSchema: false,
            read: TableFreshness.Read(startedAt: .now, includesDefinition: false),
            sql: "SELECT * FROM users",
            connection: fixture.connection
        )
    }

    @Test("A first load reaches the grid as one reload")
    func firstLoadIsOneReload() {
        let (tab, mount) = mountedTab()

        load(tab)

        #expect(mount.changes == [.reload])
    }

    // The repaint a staged edit asks for arrives on a later turn, after any the first load would have asked for.
    @Test("Only a load over staged edits repaints the rows afterwards")
    func onlyStagedEditsRepaintAfterALoad() async throws {
        let (tab, mount) = mountedTab()
        load(tab)

        fixture.coordinator.changeManager(forTab: tab.id).recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "ann", newValue: "amy", originalRow: ["1", "ann"]
        )
        load(tab)

        try await waitUntil { mount.changes.contains(.allRowsRepainted) }
        #expect(mount.changes.filter { $0 == .allRowsRepainted }.count == 1)
        #expect(!fixture.coordinator.changeManager(forTab: tab.id).hasChanges)
    }

    @Test("Metadata arriving after the rows keeps the grid's formatted text")
    func lateMetadataKeepsTheText() {
        let (tab, mount) = mountedTab()
        load(tab)
        let model = fixture.coordinator.gridModel(forTab: tab.id)
        model.display.cache.setBox(RowDisplayBox(["1", "ann"]), forID: .existing(0))

        fixture.coordinator.mutateActiveTableRows(for: tab.id) {
            $0.updateDisplayMetadata(columnComments: ["name": "Given name"])
        }

        #expect(mount.changes == [.reload, .columnMetadataChanged])
        #expect(model.display.cache.box(forID: .existing(0)) != nil)
    }
}
