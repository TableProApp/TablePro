import Foundation
import Testing
import TableProDatabase
import TableProModels
@testable import TableProMobile

@Suite("RowInserter")
struct RowInserterTests {
    private let columns = [
        ColumnInfo(name: "id", typeName: "integer", isPrimaryKey: true, isNullable: false, ordinalPosition: 0),
        ColumnInfo(name: "name", typeName: "text", ordinalPosition: 1)
    ]

    private func makeDriver(results: [Result<QueryResult, Error>]) -> MockDatabaseDriver {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = columns
        driver.scriptedExecuteResults = results
        return driver
    }

    private func ok(_ rows: Int = 1) -> Result<QueryResult, Error> {
        .success(QueryResult(columns: [], rows: [], rowsAffected: rows, executionTime: 0))
    }

    @Test("wraps a multi-row insert in a transaction and commits")
    func multiRowCommits() async throws {
        let driver = makeDriver(results: [ok(), ok()])
        let rows = [
            PayloadRow(values: ["name": .text("Ada")]),
            PayloadRow(values: ["name": .text("Grace")])
        ]
        let affected = try await RowInserter.insert(
            driver: driver, table: "people", type: .postgresql, schema: nil, rows: rows
        )
        #expect(affected == 2)
        #expect(driver.didBeginTransaction)
        #expect(driver.didCommitTransaction)
        #expect(!driver.didRollbackTransaction)
    }

    @Test("rolls back when a row fails mid-batch")
    func midBatchRollsBack() async throws {
        let driver = makeDriver(results: [ok(), .failure(MockDatabaseDriver.MockError.scripted)])
        let rows = [
            PayloadRow(values: ["name": .text("Ada")]),
            PayloadRow(values: ["name": .text("Grace")])
        ]
        await #expect(throws: (any Error).self) {
            _ = try await RowInserter.insert(
                driver: driver, table: "people", type: .postgresql, schema: nil, rows: rows
            )
        }
        #expect(driver.didBeginTransaction)
        #expect(driver.didRollbackTransaction)
        #expect(!driver.didCommitTransaction)
    }

    @Test("does not open a transaction for a single row")
    func singleRowNoTransaction() async throws {
        let driver = makeDriver(results: [ok()])
        let rows = [PayloadRow(values: ["name": .text("Ada")])]
        let affected = try await RowInserter.insert(
            driver: driver, table: "people", type: .postgresql, schema: nil, rows: rows
        )
        #expect(affected == 1)
        #expect(!driver.didBeginTransaction)
    }

    @Test("throws when no row produces a value to insert")
    func noInsertableValuesThrows() async throws {
        let driver = makeDriver(results: [])
        let rows = [PayloadRow(values: ["id": .text("")])]
        await #expect(throws: IntentDataError.self) {
            _ = try await RowInserter.insert(
                driver: driver, table: "people", type: .postgresql, schema: nil, rows: rows
            )
        }
        #expect(driver.executedQueries.isEmpty)
    }
}
