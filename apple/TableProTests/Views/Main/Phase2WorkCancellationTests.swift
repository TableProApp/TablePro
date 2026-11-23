//
//  Phase2WorkCancellationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct Phase2WorkCancellationTests {
    private let fixtures = CoordinatorFixtures()

    private static func heldSchemaRead() -> Task<FetchedTableSchema, Error> {
        Task {
            try await Task.sleep(for: .seconds(3_600))
            return FetchedTableSchema(columns: [], foreignKeys: nil)
        }
    }

    private func makeTab(in fixture: CoordinatorFixture, tableName: String = "users") -> UUID {
        let tab = QueryTab(title: tableName, query: "SELECT * FROM \(tableName)", tabType: .table, tableName: tableName)
        fixture.addTab(tab)
        fixture.tabManager.mutate(tabId: tab.id) { $0.pagination.isCountPending = true }
        return tab.id
    }

    private func launch(
        _ schemaTask: Task<FetchedTableSchema, Error>,
        on tabId: UUID,
        in fixture: CoordinatorFixture
    ) throws -> Task<Void, Never> {
        fixture.coordinator.launchPhase2Work(
            tableName: "users", tabId: tabId, connectionType: .mysql, schemaTask: schemaTask
        )
        return try #require(fixture.coordinator.phase2Works[tabId]?.first?.task)
    }

    @Test("A tab that leaves its table stops the definition read and counts nothing for it")
    func retargetCancelsPhase2() async throws {
        let fixture = fixtures.make()
        let tabId = makeTab(in: fixture)
        let schemaTask = Self.heldSchemaRead()
        let work = try launch(schemaTask, on: tabId, in: fixture)

        fixture.coordinator.discardRowsForRetarget(ofTab: tabId)

        #expect(schemaTask.isCancelled)
        #expect(fixture.coordinator.phase2Works[tabId] == nil)
        await work.value
        #expect(fixture.coordinator.rowCountTasks[tabId] == nil)
        #expect(fixture.tabManager.tabs.first?.pagination.isCountPending == false)
    }

    @Test("A cancelled read leaves the table's definition unread, so the next load reads it")
    func cancelledReadLeavesNoMetadata() async throws {
        let fixture = fixtures.make()
        let tabId = makeTab(in: fixture)
        let work = try launch(Self.heldSchemaRead(), on: tabId, in: fixture)

        fixture.coordinator.discardRowsForRetarget(ofTab: tabId)
        await work.value

        #expect(fixture.coordinator.tabSessionRegistry.tableRows(for: tabId).hasAuthoritativeSchema == false)
        #expect(!fixture.coordinator.queryExecutionCoordinator.isMetadataCached(tabId: tabId, tableName: "users"))
    }

    @Test("A page, sort or refresh of the same table keeps the read it already started")
    func sameTableKeepsPhase2() throws {
        let fixture = fixtures.make()
        let tabId = makeTab(in: fixture)
        let schemaTask = Self.heldSchemaRead()
        _ = try launch(schemaTask, on: tabId, in: fixture)

        fixture.coordinator.cancelPhase2Work(forTab: tabId, unlessReading: "users")

        #expect(!schemaTask.isCancelled)
        #expect(fixture.coordinator.phase2Works[tabId]?.count == 1)
        #expect(fixture.tabManager.tabs.first?.pagination.isCountPending == true)
    }

    @Test("A run on another table stops the read of the one the tab left")
    func otherTableCancelsPhase2() throws {
        let fixture = fixtures.make()
        let tabId = makeTab(in: fixture)
        let schemaTask = Self.heldSchemaRead()
        _ = try launch(schemaTask, on: tabId, in: fixture)

        fixture.coordinator.cancelPhase2Work(forTab: tabId, unlessReading: "orders")

        #expect(schemaTask.isCancelled)
        #expect(fixture.coordinator.phase2Works[tabId] == nil)
        #expect(fixture.tabManager.tabs.first?.pagination.isCountPending == false)
    }

    @Test("A pinned result keeps the read nothing else would make for it")
    func pinnedResultKeepsPhase2() throws {
        let fixture = fixtures.make()
        let tabId = makeTab(in: fixture)
        let pinned = ResultSet(label: "users")
        pinned.isPinned = true
        fixture.tabManager.mutate(tabId: tabId) { tab in
            tab.display.resultSets = [pinned]
            tab.display.activeResultSetId = pinned.id
        }
        let schemaTask = Self.heldSchemaRead()
        _ = try launch(schemaTask, on: tabId, in: fixture)

        fixture.coordinator.discardRowsForRetarget(ofTab: tabId)

        #expect(!schemaTask.isCancelled)
        #expect(fixture.coordinator.phase2Works[tabId]?.count == 1)
    }

    @Test("Closing a tab stops the read of a pinned result too, which goes with it")
    func closingTheTabCancelsAPinnedRead() throws {
        let fixture = fixtures.make()
        let tabId = makeTab(in: fixture)
        let pinned = ResultSet(label: "users")
        pinned.isPinned = true
        fixture.tabManager.mutate(tabId: tabId) { tab in
            tab.display.resultSets = [pinned]
            tab.display.activeResultSetId = pinned.id
        }
        let schemaTask = Self.heldSchemaRead()
        _ = try launch(schemaTask, on: tabId, in: fixture)

        let tab = try #require(fixture.tabManager.tabs.first { $0.id == tabId })
        fixture.coordinator.releaseExecution(of: tab)

        #expect(schemaTask.isCancelled)
        #expect(fixture.coordinator.phase2Works[tabId] == nil)
    }

    @Test("Closing the tab stops its read")
    func closingTheTabCancelsPhase2() throws {
        let fixture = fixtures.make()
        let tabId = makeTab(in: fixture)
        let schemaTask = Self.heldSchemaRead()
        _ = try launch(schemaTask, on: tabId, in: fixture)

        let tab = try #require(fixture.tabManager.tabs.first { $0.id == tabId })
        fixture.coordinator.releaseExecution(of: tab)

        #expect(schemaTask.isCancelled)
        #expect(fixture.coordinator.phase2Works[tabId] == nil)
    }

    @Test("A finished read leaves no handle behind")
    func finishedWorkIsForgotten() async throws {
        let fixture = fixtures.make()
        let tabId = makeTab(in: fixture)
        let done = Task<FetchedTableSchema, Error> {
            FetchedTableSchema(columns: [], foreignKeys: nil)
        }
        let work = try launch(done, on: tabId, in: fixture)

        await work.value

        #expect(fixture.coordinator.phase2Works[tabId] == nil)
    }
}
