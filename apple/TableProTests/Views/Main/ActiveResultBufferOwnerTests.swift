//
//  ActiveResultBufferOwnerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct ActiveResultBufferOwnerTests {
    private static func address(of rows: ContiguousArray<Row>) -> UnsafeRawPointer? {
        rows.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
    }

    private static func makeCoordinator() -> MainContentCoordinator {
        MainContentCoordinator(
            connection: TestFixtures.makeConnection(database: "db"),
            tabManager: QueryTabManager(),
            toolbarState: ConnectionToolbarState()
        )
    }

    private static func install(
        _ results: [ResultSet],
        active: ResultSet,
        in coordinator: MainContentCoordinator
    ) throws -> UUID {
        coordinator.tabManager.addTab(databaseName: "db")
        let tabId = try #require(coordinator.tabManager.selectedTab?.id)
        let index = try #require(coordinator.tabManager.selectedTabIndex)
        coordinator.tabManager.mutate(at: index) { tab in
            tab.display.resultSets = results
            tab.display.activeResultSetId = active.id
        }
        coordinator.setActiveTableRows(active.tableRows, for: tabId)
        return tabId
    }

    @Test("The first edit of a result writes into the buffer it already has")
    func firstEditKeepsTheBuffer() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        let result = ResultSet(label: "users", tableRows: TestFixtures.makeTableRows(rowCount: 50))
        let tabId = try Self.install([result], active: result, in: coordinator)
        let registry = coordinator.tabSessionRegistry
        let before = Self.address(of: registry.tableRows(for: tabId).rows)

        coordinator.mutateActiveTableRows(for: tabId) { $0.edit(row: 10, column: 1, value: .text("edited")) }

        #expect(Self.address(of: registry.tableRows(for: tabId).rows) == before)
        #expect(registry.tableRows(for: tabId).value(at: 10, column: 1) == .text("edited"))
        #expect(result.tableRows.rows.isEmpty)
        #expect(result.resultColumns == ["id", "name", "email"])
    }

    @Test("Switching away hands the edited rows back to the result they came from")
    func switchingAwayRestoresTheResultRows() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        let edited = ResultSet(label: "first", tableRows: TestFixtures.makeTableRows(rowCount: 4))
        let other = ResultSet(label: "second", tableRows: TestFixtures.makeTableRows(rowCount: 2))
        let tabId = try Self.install([edited, other], active: edited, in: coordinator)

        coordinator.mutateActiveTableRows(for: tabId) { $0.edit(row: 2, column: 1, value: .text("kept")) }
        coordinator.applyResultSetSwitch(to: other.id, in: tabId)

        #expect(edited.tableRows.rows.count == 4)
        #expect(edited.tableRows.value(at: 2, column: 1) == .text("kept"))

        coordinator.applyResultSetSwitch(to: edited.id, in: tabId)
        #expect(coordinator.tabSessionRegistry.tableRows(for: tabId).value(at: 2, column: 1) == .text("kept"))
    }

    @Test("A result whose rows the buffer no longer shares keeps them through an edit")
    func unsharedResultKeepsItsRows() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }
        let result = ResultSet(label: "users", tableRows: TestFixtures.makeTableRows(rowCount: 3))
        let tabId = try Self.install([result], active: result, in: coordinator)
        coordinator.setActiveTableRows(TestFixtures.makeTableRows(rowCount: 5), for: tabId, source: .sameSource)

        coordinator.mutateActiveTableRows(for: tabId) { $0.edit(row: 0, column: 1, value: .text("x")) }

        #expect(result.tableRows.rows.count == 3)
    }
}
