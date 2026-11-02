//
//  DataWriteExecutorLookupTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class LookupDriver: PluginDriverStub, @unchecked Sendable {
    // Rows each lookup finds, in the order the lookups run.
    var found: [Int]
    // Rows each check finds after its write; a row means the write did not land.
    var leftBehind: [Int]
    let affected: Int
    private(set) var trace: [(query: String, parameters: [PluginCellValue])] = []

    init(found: [Int], leftBehind: [Int] = [], affected: Int = 0) {
        self.found = found
        self.leftBehind = leftBehind
        self.affected = affected
    }

    var writes: [(query: String, parameters: [PluginCellValue])] {
        trace.filter { !$0.query.hasPrefix("LOOKUP") && !$0.query.hasPrefix("CHECK") }
    }

    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func ping() async throws {}

    func execute(query: String) async throws -> PluginQueryResult {
        try await executeParameterized(query: query, parameters: [])
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        trace.append((query, parameters))
        var rows: [[PluginCellValue]] = []
        if query.hasPrefix("LOOKUP") {
            let count = found.isEmpty ? 0 : found.removeFirst()
            rows = (0 ..< count).map { [.text("part_\($0)")] }
        } else if query.hasPrefix("CHECK") {
            let count = leftBehind.isEmpty ? 0 : leftBehind.removeFirst()
            rows = Array(repeating: [.text("1")], count: count)
        }
        let isWrite = !query.hasPrefix("LOOKUP") && !query.hasPrefix("CHECK")
        return PluginQueryResult(
            columns: ["_part"], columnTypeNames: ["String"], rows: rows, rowsAffected: isWrite ? affected : 0, executionTime: 0
        )
    }
}

struct DataWriteExecutorLookupTests {
    private func step(
        _ sql: String,
        rowCount: Int = 1,
        check: Bool = true,
        rowKind: RowWriteKind = .delete,
        pinsRows: Bool = true
    ) -> DataWriteStep {
        DataWriteStep(
            kind: .rowWrite,
            statement: ParameterizedStatement(sql: sql, parameters: ["a"]),
            tableName: "events",
            rowKind: rowKind,
            lookup: RowLookup(
                query: ParameterizedStatement(sql: "LOOKUP \(sql)", parameters: ["a"]),
                rowCount: rowCount,
                pinsRows: pinsRows,
                check: check ? ParameterizedStatement(sql: "CHECK \(sql)", parameters: ["a"]) : nil
            )
        )
    }

    private func run(_ steps: [DataWriteStep], on lookup: LookupDriver) async throws {
        let plan = DataWritePlan(
            scope: DatabaseScope(connectionId: UUID(), database: "default", schema: nil),
            databaseType: .clickhouse,
            steps: steps
        )
        let driver = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .clickhouse), pluginDriver: lookup)
        _ = try await DataWriteExecutor.run(plan, on: driver)
    }

    @Test("A write runs on the rows its lookup found, their values bound after its own")
    func foundRowsAreBound() async throws {
        let driver = LookupDriver(found: [2, 2])

        try await run([step("DELETE pinned", rowCount: 2)], on: driver)

        #expect(driver.writes.map { $0.query } == ["DELETE pinned"])
        #expect(driver.writes.first?.parameters == ["a", "part_0", "part_1"])
        #expect(driver.trace.map { $0.query } == ["LOOKUP DELETE pinned", "LOOKUP DELETE pinned", "DELETE pinned", "CHECK DELETE pinned"])
    }

    @Test("A row its lookup cannot tell apart from another refuses the save before anything is written")
    func identicalRowsRefuseBeforeAnyWrite() async {
        let driver = LookupDriver(found: [1, 2])

        await #expect(throws: DataWriteError.changeRefused(
            table: "events",
            kind: .delete,
            reason: String(localized: "Other rows hold exactly the same values, so the change cannot reach this row alone.")
        )) {
            try await run([step("first"), step("second")], on: driver)
        }
        #expect(driver.writes.isEmpty)
    }

    @Test("A row that is no longer there refuses the save before anything is written")
    func missingRowRefusesBeforeAnyWrite() async {
        let driver = LookupDriver(found: [0])

        await #expect(throws: DataWriteError.self) {
            try await run([step("only")], on: driver)
        }
        #expect(driver.writes.isEmpty)
    }

    @Test("An insert whose key a row already holds refuses the save, saying the key is taken, before anything is written")
    func takenKeyRefusesInsertBeforeAnyWrite() async {
        let driver = LookupDriver(found: [1])

        await #expect(throws: DataWriteError.changeRefused(
            table: "events",
            kind: .insert,
            reason: String(localized: "A row with this key already exists, so the insert would not add one.")
        )) {
            try await run([step("INSERT keyed", rowCount: 0, check: false, rowKind: .insert, pinsRows: false)], on: driver)
        }
        #expect(driver.writes.isEmpty)
    }

    @Test("Each write reads its lookup again right before it runs, after the writes ahead of it")
    func lookupRunsAgainBeforeEachWrite() async {
        let driver = LookupDriver(found: [1, 1, 1, 2])

        await #expect(throws: DataWritePartialCommitError.self) {
            try await run([step("first"), step("second")], on: driver)
        }
        #expect(driver.writes.map { $0.query } == ["first"])
    }

    @Test("A write its check still finds counts as written, and the save says to refresh before saving again")
    func uncheckedWriteIsWrittenAndFails() async throws {
        let driver = LookupDriver(found: [1, 1], leftBehind: [1])

        let error = await #expect(throws: DataWritePartialCommitError.self) {
            try await run([step("only")], on: driver)
        }

        #expect(error?.committed.count == 1)
        #expect(error?.disposition == .written)
        #expect(error?.underlying as? DataWriteError == .changeRefused(
            table: "events",
            kind: .delete,
            reason: String(localized: "A row still holds the values the change was made on. Refresh the table before saving again.")
        ))
    }

    @Test("A pinned write is previewed after its lookup, with what it binds at save time named")
    func previewShowsTheLookup() {
        let plan = DataWritePlan(
            scope: DatabaseScope(connectionId: UUID(), database: "default", schema: nil),
            databaseType: .clickhouse,
            steps: [step("DELETE WHERE v = ? AND _part IN (?)")]
        )

        #expect(plan.displayStatements == [
            "LOOKUP DELETE WHERE v = 'a' AND _part IN (?)",
            "DELETE WHERE v = 'a' AND _part IN (/* found by the query above */)",
        ])
    }

    @Test("A write that reaches more rows than its lookup found fails the save")
    func writeReachingMoreRowsThanFoundFails() async {
        let driver = LookupDriver(found: [1, 1], affected: 2)

        await #expect(throws: DataWriteError.self) {
            try await run([step("only", check: false)], on: driver)
        }
    }
}
