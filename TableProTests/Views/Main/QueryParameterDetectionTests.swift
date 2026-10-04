//
//  QueryParameterDetectionTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
struct QueryParameterDetectionTests {
    @Test(
        "Only SQL reads :name as a bind parameter",
        arguments: [
            (DatabaseType.mysql, true), (.postgresql, true), (.sqlite, true),
            (.elasticsearch, false), (.typesense, false), (.weaviate, false), (.mongodb, false),
            (.redis, false), (.etcd, false), (.surrealdb, false), (.kafka, false)
        ]
    )
    func onlySQLBindsNamedParameters(type: DatabaseType, binds: Bool) {
        let harness = QueryTabHarness(type: type, query: "")
        defer { harness.tearDown() }
        #expect(harness.coordinator.bindsNamedParameters == binds)
    }

    @Test("A field query in an Elasticsearch URL runs instead of asking for a parameter")
    func elasticsearchFieldQueryRuns() throws {
        let query = "GET /products/_search?q=name:lamp"
        let harness = QueryTabHarness(type: .elasticsearch, query: query)
        defer { harness.tearDown() }

        #expect(harness.coordinator.runStatement(query, sourceOffset: 0))

        let tab = try #require(harness.tabManager.tabs.first)
        #expect(tab.content.queryParameters.isEmpty)
        #expect(!tab.content.isParameterPanelVisible)
    }

    @Test("A SQL :name still opens the parameter panel before anything runs")
    func sqlParameterOpensPanel() throws {
        let query = "SELECT * FROM products WHERE name = :name"
        let harness = QueryTabHarness(type: .mysql, query: query)
        defer { harness.tearDown() }

        #expect(!harness.coordinator.runStatement(query, sourceOffset: 0))

        let tab = try #require(harness.tabManager.tabs.first)
        #expect(tab.content.queryParameters.map(\.name) == ["name"])
        #expect(tab.content.isParameterPanelVisible)
    }
}

/// A coordinator with one query tab selected and no session behind it.
///
/// Query parameters are switched on for the length of the test and the user's own setting put back,
/// so the run paths answer to the shipped default rather than to the machine running them.
@MainActor
private struct QueryTabHarness {
    let coordinator: MainContentCoordinator
    let tabManager: QueryTabManager
    private let previousParametersSetting: Bool

    init(type: DatabaseType, query: String) {
        previousParametersSetting = AppSettingsManager.shared.editor.queryParametersEnabled
        AppSettingsManager.shared.editor.queryParametersEnabled = true
        tabManager = QueryTabManager()
        coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(type: type),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        let tab = QueryTab(title: "Query", query: query, tabType: .query)
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
    }

    func tearDown() {
        coordinator.cancelAllQueryTasks()
        coordinator.teardown()
        AppSettingsManager.shared.editor.queryParametersEnabled = previousParametersSetting
    }
}
