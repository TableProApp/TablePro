//
//  UnloadedValueFirstLoadTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

extension GlobalStateSuites {
    @MainActor
    struct UnloadedValueFirstLoadTests {
        private func makeCoordinator(
            type: DatabaseType,
            primaryKeys: [String] = ["id"]
        ) -> (coordinator: MainContentCoordinator, tabManager: QueryTabManager, tabId: UUID) {
            let tabManager = QueryTabManager()
            let coordinator = MainContentCoordinator(
                connection: TestFixtures.makeConnection(type: type),
                tabManager: tabManager,
                changeManager: DataChangeManager(),
                toolbarState: ConnectionToolbarState()
            )
            var tab = QueryTab(title: "files", query: "SELECT * FROM `files` LIMIT 200", tabType: .table)
            tab.tableContext.tableName = "files"
            tabManager.tabs.append(tab)
            tabManager.selectedTabId = tab.id
            coordinator.schemaColumns.store(
                SchemaColumnStore.Entry(
                    columns: ["id", "name", "data"],
                    primaryKeys: primaryKeys,
                    columnTypes: [
                        "id": .integer(rawType: "INT"),
                        "name": .text(rawType: "VARCHAR(20)"),
                        "data": .blob(rawType: "LONGBLOB")
                    ]
                ),
                for: coordinator.schemaColumnsKey("files", scope: coordinator.selectedTabScope)
            )
            return (coordinator, tabManager, tab.id)
        }

        private func firstLoadQuery(
            _ coordinator: MainContentCoordinator,
            _ tabManager: QueryTabManager,
            tabId: UUID
        ) async -> String? {
            guard await coordinator.prepareTableTabFirstLoad(tabId: tabId) else { return nil }
            return tabManager.tabs.first { $0.id == tabId }?.content.query
        }

        @Test("A MySQL page leaves a large binary value on the server and reads its size", .unloadedNoDefaultSort)
        func mysqlFirstPageDefersBinaryValues() async throws {
            let (coordinator, tabManager, tabId) = makeCoordinator(type: .mysql)
            defer { coordinator.teardown() }

            let query = try #require(await firstLoadQuery(coordinator, tabManager, tabId: tabId))

            #expect(query.hasPrefix("SELECT `id`, `name`, CASE WHEN OCTET_LENGTH(`data`) <= 65536 THEN `data` END AS `data`"))
            #expect(query.contains("OCTET_LENGTH(`data`) AS `__tablepro_byte_length_2`"))
        }

        @Test("A table without a primary key reads every value inline", .unloadedNoDefaultSort)
        func noPrimaryKeyReadsInline() async throws {
            let (coordinator, tabManager, tabId) = makeCoordinator(type: .mysql, primaryKeys: [])
            defer { coordinator.teardown() }

            let query = try #require(await firstLoadQuery(coordinator, tabManager, tabId: tabId))

            #expect(!query.contains("OCTET_LENGTH"))
        }

        @Test("An engine with no byte length function reads every value inline", .unloadedNoDefaultSort)
        func otherEngineReadsInline() async throws {
            let (coordinator, tabManager, tabId) = makeCoordinator(type: .postgresql)
            defer { coordinator.teardown() }

            let query = try #require(await firstLoadQuery(coordinator, tabManager, tabId: tabId))

            #expect(!query.contains("CASE WHEN"))
        }
    }
}

private extension Trait where Self == AppSettingsTrait {
    static var unloadedNoDefaultSort: Self { .appSettings { $0.dataGrid.defaultSortBehavior = .none } }
}
