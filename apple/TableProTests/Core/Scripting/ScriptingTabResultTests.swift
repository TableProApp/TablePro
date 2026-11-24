//
//  ScriptingTabResultTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

extension GlobalStateSuites {
    @MainActor
    struct ScriptingTabResultTests {
        @Test("A script reading a background tab's result leaves out the rows that tab marked for deletion")
        func backgroundTabSkipsItsDeletedRows() throws {
            let connection = TestFixtures.makeConnection(database: "db_a")
            let saved = ConnectionStorage.shared.loadConnections()
            ConnectionStorage.shared.saveConnections(saved + [connection])
            defer { ConnectionStorage.shared.saveConnections(saved) }
            let coordinator = SessionStateFactory.create(connection: connection, payload: nil).coordinator
            defer { coordinator.teardown() }
            let background = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users")
            coordinator.tabManager.tabs.append(background)
            coordinator.setActiveTableRows(
                TableRows.from(
                    queryRows: [[.text("1")], [.text("2")], [.text("3")]],
                    columns: ["id"],
                    columnTypes: [.text(rawType: nil)]
                ),
                for: background.id
            )
            coordinator.changeManager(forTab: background.id).recordRowDeletion(rowID: .existing(1), originalRow: [.text("2")])
            let selected = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
            coordinator.tabManager.tabs.append(selected)
            coordinator.tabManager.selectedTabId = selected.id

            let record = ScriptingSnapshot.result(ofTab: background.id, connectionId: connection.id, selectedOnly: false)

            let rows = try #require(record[ScriptingKeys.QueryResult.rows] as? [[String: Any]])
            #expect(rows.compactMap { $0[ScriptingKeys.ResultRow.values] as? [String] } == [["1"], ["3"]])
        }
    }
}
