//
//  FirstLoadColumnReadTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct FirstLoadColumnReadTests {
    private static let columns = [TestFixtures.makeColumnInfo()]

    private func makeFixture(driver: MockDatabaseDriver) -> (CoordinatorFixture, DatabaseScope) {
        let connection = TestFixtures.makeConnection(database: "db")
        let fixture = CoordinatorFixture(connection: connection, driver: driver)
        return (fixture, DatabaseScope(connectionId: connection.id, database: "db", schema: nil, isSessionBound: true))
    }

    @Test("The definition read reuses the columns the open already read")
    func definitionReadReusesColumns() async throws {
        let driver = MockDatabaseDriver()
        driver.columnsToReturn = ["users": Self.columns]
        let (fixture, scope) = makeFixture(driver: driver)

        let read = try #require(await fixture.coordinator.loadSchemaColumns(for: "users", scope: scope))
        #expect(driver.fetchColumnsCallCount == 1)

        let schema = try await QueryExecutor.fetchTableSchema(
            scope: scope, tableName: "users", isView: false, knownColumns: read.columns
        )

        #expect(driver.fetchColumnsCallCount == 1)
        #expect(schema.columns.map(\.name) == ["id"])
    }

    @Test("A definition read with no earlier read fetches the columns itself")
    func definitionReadFetchesWithoutAKnownRead() async throws {
        let driver = MockDatabaseDriver()
        driver.columnsToReturn = ["users": Self.columns]
        let (fixture, scope) = makeFixture(driver: driver)

        _ = try await QueryExecutor.fetchTableSchema(scope: scope, tableName: "users", isView: false)

        #expect(driver.fetchColumnsCallCount == 1)
        withExtendedLifetime(fixture) {}
    }

    @Test("Columns the cache answered are no read of this open")
    func cachedColumnsAreNotARead() async {
        let driver = MockDatabaseDriver()
        driver.columnsToReturn = ["users": Self.columns]
        let (fixture, scope) = makeFixture(driver: driver)

        _ = await fixture.coordinator.loadSchemaColumns(for: "users", scope: scope)
        let second = await fixture.coordinator.loadSchemaColumns(for: "users", scope: scope)

        #expect(second == nil)
    }

    @Test("A read is taken once, for the table it was made for")
    func readIsTakenOnce() {
        let driver = MockDatabaseDriver()
        let (fixture, scope) = makeFixture(driver: driver)
        let coordinator = fixture.coordinator
        let tabId = UUID()
        let key = coordinator.schemaColumnsKey("users", scope: scope)

        coordinator.firstLoadColumnReads[tabId] = FirstLoadColumnRead(key: key, columns: Self.columns, startedAt: .now)
        #expect(coordinator.takeFirstLoadColumns(tabId: tabId, tableName: "orders", scope: scope) == nil)

        coordinator.firstLoadColumnReads[tabId] = FirstLoadColumnRead(key: key, columns: Self.columns, startedAt: .now)
        #expect(coordinator.takeFirstLoadColumns(tabId: tabId, tableName: "users", scope: scope)?.count == 1)
        #expect(coordinator.takeFirstLoadColumns(tabId: tabId, tableName: "users", scope: scope) == nil)
    }

    @Test("A definition change after the read began makes the columns the old table's")
    func definitionChangeRefusesTheRead() {
        let driver = MockDatabaseDriver()
        let (fixture, scope) = makeFixture(driver: driver)
        let coordinator = fixture.coordinator
        let tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users")
        fixture.addTab(tab)
        let startedAt = ContinuousClock.now

        coordinator.firstLoadColumnReads[tab.id] = FirstLoadColumnRead(
            key: coordinator.schemaColumnsKey("users", scope: scope), columns: Self.columns, startedAt: startedAt
        )
        coordinator.tabSessionRegistry.recordChange(
            TableFreshness.Change(extent: .definition, at: startedAt.advanced(by: .milliseconds(1))),
            for: tab.id
        )

        #expect(coordinator.takeFirstLoadColumns(tabId: tab.id, tableName: "users", scope: scope) == nil)
    }
}
