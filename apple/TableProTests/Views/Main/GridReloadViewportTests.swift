//
//  GridReloadViewportTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct GridReloadViewportTests {
    @MainActor
    private struct Fixture {
        let coordinator: MainContentCoordinator
        let tabId: UUID
        let model: DataGridModel
        let mount: DataTabGridMountStub

        func takePlacement() -> GridViewportPlacement? {
            coordinator.tabSessionRegistry.takeViewportPlacement(for: tabId)
        }
    }

    private static func rows(ids: [Int]) -> TableRows {
        TableRows.from(
            queryRows: ids.map { [.text("\($0)"), .text("name-\($0)")] },
            columns: ["id", "name"],
            columnTypes: [.text(rawType: "INTEGER"), .text(rawType: "TEXT")],
            hasAuthoritativeSchema: true
        )
    }

    private func makeFixture(tabType: TabType = .table, mode: ResultsViewMode = .data) -> Fixture {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: tabType, tableName: "users")
        tab.tableContext.primaryKeyColumns = ["id"]
        tab.display.resultsViewMode = mode
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        let model = coordinator.gridModel(forTab: tab.id)
        let mount = DataTabGridMountStub()
        model.attach(mount)

        coordinator.setActiveTableRows(Self.rows(ids: Array(1 ... 10)), for: tab.id)
        _ = coordinator.tabSessionRegistry.takeViewportPlacement(for: tab.id)
        return Fixture(coordinator: coordinator, tabId: tab.id, model: model, mount: mount)
    }

    @Test("A table tab's grid on screen is handed its placement once")
    func mountedGridTakesItsPlacementOnce() {
        let fixture = makeFixture()
        defer { fixture.coordinator.teardown() }

        fixture.coordinator.setActiveTableRows(Self.rows(ids: Array(1 ... 10)), for: fixture.tabId)

        #expect(fixture.takePlacement() == .firstRow)
        #expect(fixture.takePlacement() == nil)
        withExtendedLifetime(fixture) {}
    }

    @Test("A table tab whose model has no grid mounted is handed no placement")
    func unmountedModelStagesNothing() {
        let fixture = makeFixture()
        defer { fixture.coordinator.teardown() }
        fixture.model.detach(fixture.mount)

        fixture.coordinator.setActiveTableRows(Self.rows(ids: Array(1 ... 10)), for: fixture.tabId)

        #expect(fixture.takePlacement() == nil)
    }

    @Test("A grid outside Data mode is handed no placement")
    func unmountedGridStagesNothing() {
        let fixture = makeFixture(mode: .json)
        defer { fixture.coordinator.teardown() }

        fixture.coordinator.setActiveTableRows(Self.rows(ids: Array(0 ... 10)), for: fixture.tabId, viewport: .keepPlace)

        #expect(fixture.takePlacement() == nil)
        withExtendedLifetime(fixture) {}
    }

    @Test("A query tab's result keeps the grid where AppKit leaves it")
    func queryTabStagesNothing() {
        let fixture = makeFixture(tabType: .query)
        defer { fixture.coordinator.teardown() }

        fixture.coordinator.setActiveTableRows(Self.rows(ids: Array(0 ... 10)), for: fixture.tabId, viewport: .firstRow)

        #expect(fixture.takePlacement() == nil)
        withExtendedLifetime(fixture) {}
    }

    @Test("A placement staged for rows that were replaced since is never applied")
    func placementForReplacedRowsIsDropped() {
        let fixture = makeFixture()
        defer { fixture.coordinator.teardown() }
        fixture.coordinator.setActiveTableRows(Self.rows(ids: Array(1 ... 10)), for: fixture.tabId)

        fixture.coordinator.tabSessionRegistry.setTableRows(Self.rows(ids: [42]), for: fixture.tabId)

        #expect(fixture.takePlacement() == nil)
        withExtendedLifetime(fixture) {}
    }

    @Test("Switching results in a query tab stages no placement")
    func resultSwitchStagesNothing() {
        let fixture = makeFixture(tabType: .query)
        defer { fixture.coordinator.teardown() }
        let first = ResultSet(label: "first", tableRows: Self.rows(ids: Array(1 ... 5)))
        let second = ResultSet(label: "second", tableRows: Self.rows(ids: Array(6 ... 9)))
        fixture.coordinator.tabManager.mutate(tabId: fixture.tabId) { tab in
            tab.display.resultSets = [first, second]
            tab.display.activeResultSetId = first.id
        }

        fixture.coordinator.applyResultSetSwitch(to: second.id, in: fixture.tabId)

        #expect(fixture.takePlacement() == nil)
        withExtendedLifetime(fixture) {}
    }

    @Test("Reading the same table again keeps the selected rows, matched by primary key")
    func sameSourceRestoresTheSelectionByKey() {
        let fixture = makeFixture()
        defer { fixture.coordinator.teardown() }
        fixture.model.selectRows([.existing(2), .existing(5)])

        fixture.coordinator.setActiveTableRows(
            Self.rows(ids: Array((1 ... 10).reversed())),
            for: fixture.tabId,
            viewport: .keepPlace,
            source: .sameSource
        )

        let placement = fixture.takePlacement()
        #expect(Set(placement?.selectedRows ?? []) == [.existing(7), .existing(4)])
        withExtendedLifetime(fixture) {}
    }

    @Test("A new result does not carry the selection over")
    func newSourceRestoresNoSelection() {
        let fixture = makeFixture()
        defer { fixture.coordinator.teardown() }
        fixture.model.selectRows([.existing(2)])

        fixture.coordinator.setActiveTableRows(Self.rows(ids: Array(1 ... 10)), for: fixture.tabId, viewport: .keepPlace)

        #expect(fixture.takePlacement()?.selectedRows.isEmpty == true)
        withExtendedLifetime(fixture) {}
    }

    @Test("A query tab's grid takes a placement when its own result is read again")
    func queryTabRereadStagesTheSelection() {
        let fixture = makeFixture(tabType: .query)
        defer { fixture.coordinator.teardown() }
        fixture.model.selectRows([.existing(1)])

        fixture.coordinator.setActiveTableRows(
            Self.rows(ids: Array(1 ... 10)),
            for: fixture.tabId,
            viewport: .keepPlace,
            source: .sameSource
        )

        #expect(fixture.takePlacement()?.selectedRows == [.existing(1)])
        withExtendedLifetime(fixture) {}
    }
}
