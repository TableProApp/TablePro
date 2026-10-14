//
//  ObjectCopyRowCopierTests.swift
//  TableProTests
//
//  The streaming write. Two things decide whether a copy is correct rather than
//  merely finished: the batch never exceeds the engine's bind-parameter
//  ceiling, and the parameters arrive in the order the placeholders expect.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class CopyDriver: PluginDriverStub, @unchecked Sendable {
    var streamed: [[PluginCellValue]] = []
    var batchSize = 2
    var executedQueries: [String] = []
    var executedParameters: [[PluginCellValue]] = []
    var quote: (String) -> String = { "`\($0)`" }
    var declaredParameterStyle: ParameterStyle = .questionMark
    var transactionEvents: [String] = []

    var parameterStyle: ParameterStyle { declaredParameterStyle }

    func execute(query: String) async throws -> PluginQueryResult {
        executedQueries.append(query)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        executedQueries.append(query)
        executedParameters.append(parameters)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let rows = streamed
        let size = batchSize
        return AsyncThrowingStream { continuation in
            continuation.yield(.header(PluginStreamHeader(columns: ["id", "name"], columnTypeNames: [])))
            var index = 0
            while index < rows.count {
                let end = min(index + size, rows.count)
                continuation.yield(.rows(Array(rows[index..<end])))
                index = end
            }
            continuation.finish()
        }
    }

    func quoteIdentifier(_ name: String) -> String { quote(name) }

    func beginTransaction() async throws { transactionEvents.append("begin") }
    func commitTransaction() async throws { transactionEvents.append("commit") }
    func rollbackTransaction() async throws { transactionEvents.append("rollback") }
}

struct ObjectCopyRowCopierTests {
    private func step(
        columns: [String] = ["id", "name"],
        schema: String? = "public",
        coercer: CrossEngineValueCoercer? = nil,
        serverSideInsert: SyncStatement? = nil,
        estimatedRows: Int? = nil
    ) -> ObjectCopyTableStep {
        ObjectCopyTableStep(
            selection: ObjectCopySelection(kind: .table, name: "orders", schema: schema),
            dropStatements: [],
            sequenceStatements: [],
            createStatements: [],
            truncateStatements: [],
            columns: columns,
            primaryKeyColumns: ["id"],
            sourceQuery: "SELECT `id`, `name` FROM `public`.`orders`",
            targetTable: "orders",
            targetSchema: schema,
            estimatedRows: estimatedRows,
            copiesData: true,
            copiesIdentityColumn: false,
            coercer: coercer,
            serverSideInsert: serverSideInsert,
            note: nil
        )
    }

    private func rows(_ count: Int) -> [[PluginCellValue]] {
        (0..<count).map { [.text(String($0)), .text("row\($0)")] }
    }

    @Test
    func everyRowReachesTheTarget() async throws {
        let source = CopyDriver()
        source.streamed = rows(5)
        let target = CopyDriver()

        let outcome = try await ObjectCopyRowCopier(step: step(), targetDatabaseType: .mysql)
            .copy(from: source, to: target) { _ in }

        #expect(outcome.inserted == 5)
        #expect(!outcome.cancelled)
        #expect(target.executedParameters.flatMap { $0 }.count == 10)
    }

    /// One multi-row INSERT per batch, not one per row: that is the whole reason the copy is
    /// faster than exporting to a file and importing it back.
    @Test
    func rowsAreWrittenInBatchesRatherThanOneAtATime() async throws {
        let source = CopyDriver()
        source.streamed = rows(2_500)
        let target = CopyDriver()

        _ = try await ObjectCopyRowCopier(step: step(), targetDatabaseType: .mysql)
            .copy(from: source, to: target) { _ in }

        #expect(target.executedQueries.count == 3, "1,000 rows per statement at the row cap")
        #expect(target.executedQueries.allSatisfy { $0.hasPrefix("INSERT INTO `public`.`orders`") })
    }

    /// The generator flattens its rows in row-major order, and the copier hands the same
    /// sequence to the driver. If those two ever disagree, values land in the wrong columns.
    @Test
    func parametersArriveInPlaceholderOrder() async throws {
        let source = CopyDriver()
        source.streamed = [[.text("1"), .text("a")], [.text("2"), .text("b")]]
        source.batchSize = 2
        let target = CopyDriver()

        _ = try await ObjectCopyRowCopier(step: step(), targetDatabaseType: .mysql)
            .copy(from: source, to: target) { _ in }

        #expect(target.executedParameters.first?.map(\.sortKey) == ["1", "a", "2", "b"])
    }

    @Test
    func theTargetSchemaIsWrittenIntoTheInsert() async throws {
        let source = CopyDriver()
        source.streamed = rows(1)
        let target = CopyDriver()

        _ = try await ObjectCopyRowCopier(step: step(), targetDatabaseType: .mysql)
            .copy(from: source, to: target) { _ in }

        #expect(target.executedQueries.first == "INSERT INTO `public`.`orders` (`id`, `name`) VALUES (?, ?), (?, ?)".replacingOccurrences(
                of: ", (?, ?)", with: ""
            ))
    }

    @Test
    func anUnqualifiedTargetKeepsThePlainName() async throws {
        let source = CopyDriver()
        source.streamed = rows(1)
        let target = CopyDriver()

        _ = try await ObjectCopyRowCopier(step: step(schema: nil), targetDatabaseType: .mysql)
            .copy(from: source, to: target) { _ in }

        #expect(target.executedQueries.first == "INSERT INTO `orders` (`id`, `name`) VALUES (?, ?)")
    }

    @Test
    func anEmptyTableWritesNothing() async throws {
        let source = CopyDriver()
        let target = CopyDriver()

        let outcome = try await ObjectCopyRowCopier(step: step(), targetDatabaseType: .mysql)
            .copy(from: source, to: target) { _ in }

        #expect(outcome.inserted == 0)
        #expect(target.executedQueries.isEmpty)
    }

    /// A row of the wrong width means the source answered a different question from the one the
    /// plan asked, and writing it would put values in the wrong columns.
    @Test
    func aMisalignedRowStopsTheTable() async {
        let source = CopyDriver()
        source.streamed = [[.text("1")]]
        let target = CopyDriver()

        do {
            _ = try await ObjectCopyRowCopier(step: step(), targetDatabaseType: .mysql)
                .copy(from: source, to: target) { _ in }
            Issue.record("A row of the wrong width must not be written")
        } catch {
            #expect(target.executedQueries.isEmpty)
        }
    }

    @Test
    func progressReportsTheRunningTotal() async throws {
        let source = CopyDriver()
        source.streamed = rows(2_500)
        let target = CopyDriver()
        let reported = Reported()

        _ = try await ObjectCopyRowCopier(step: step(), targetDatabaseType: .mysql)
            .copy(from: source, to: target) { reported.append($0) }

        #expect(reported.values == [1_000, 2_000, 2_500])
    }

    // MARK: - Batch bounds

    /// A bind-parameter count is not a size: six rows of 400,000 characters sit well inside the row
    /// cap and used to go out as one statement no server would take. The sizing arithmetic itself
    /// moved to SQLWriteBatchBudgetTests, onto the type that now owns it.
    @Test
    func aByteHeavyCopyIsSplitAcrossStatements() async throws {
        let source = CopyDriver()
        let wide = String(repeating: "a", count: 400_000)
        source.streamed = (0 ..< 6).map { [.text(String($0)), .text(wide)] }
        source.batchSize = 6
        let target = CopyDriver()

        _ = try await ObjectCopyRowCopier(step: step(), targetDatabaseType: .mysql)
            .copy(from: source, to: target) { _ in }

        #expect(target.executedQueries.count > 1, "one mebibyte holds two of these rows")
        #expect(target.executedParameters.flatMap { $0 }.count == 12)
        for batch in target.executedParameters {
            #expect(SQLWriteBatchBudget(maxRows: 1_000)
                    .byteCount(of: batch.map { PluginCellValue.text($0.asText ?? "") }) <= SQLWriteBatchBudget.maximumBytes + 400_012,
                "no batch may exceed the budget by more than the one row that cannot be split")
        }
    }

    /// A row over the budget on its own cannot be split, so it goes out alone rather than being
    /// dropped or looping forever.
    @Test
    func aRowOverTheBudgetIsStillWritten() async throws {
        let source = CopyDriver()
        source.streamed = [[.text("1"), .text(String(repeating: "a", count: 2_000_000))]]
        source.batchSize = 1
        let target = CopyDriver()

        let outcome = try await ObjectCopyRowCopier(step: step(), targetDatabaseType: .mysql)
            .copy(from: source, to: target) { _ in }

        #expect(outcome.inserted == 1)
        #expect(target.executedQueries.count == 1)
    }

    // MARK: - Crossing engines

    /// A `t` from PostgreSQL bound into a MySQL `TINYINT(1)` is 0 outside strict mode, so every
    /// `true` in the table would arrive as `false` with nothing reported.
    @Test
    func valuesAreReshapedForTheTarget() async throws {
        let source = CopyDriver()
        source.streamed = [[.text("1"), .text("t")]]
        let target = CopyDriver()
        let coercer = CrossEngineValueCoercer(
            pairs: [
                .init(source: .integer(bytes: 4), target: .integer(bytes: 4)),
                .init(source: .boolean, target: .boolean)
            ],
            from: .postgres
        )

        _ = try await ObjectCopyRowCopier(
            step: step(columns: ["id", "live"], coercer: coercer), targetDatabaseType: .mysql
        ).copy(from: source, to: target) { _ in }

        #expect(target.executedParameters.first?.map(\.sortKey) == ["1", "1"])
    }

    // MARK: - The server-side path

    /// One statement instead of a stream, and the source driver is never read from at all.
    @Test
    func aServerSideCopyRunsOneStatementAndReadsNothing() async throws {
        let source = CopyDriver()
        source.streamed = rows(5)
        let target = CopyDriver()
        let statement = SyncStatement(
            sql: "INSERT INTO `orders` (`id`) SELECT `id` FROM `shop`.`orders`;",
            objectName: "orders",
            summary: "server side"
        )

        let outcome = try await ObjectCopyRowCopier(
            step: step(serverSideInsert: statement, estimatedRows: 5), targetDatabaseType: .mysql
        ).copy(from: source, to: target) { _ in }

        #expect(target.executedQueries == [statement.sql])
        #expect(target.executedParameters.isEmpty)
        #expect(!outcome.cancelled)
    }

    /// The server's own count and never the plan's estimate. `rowsAffected` cannot tell "the driver
    /// reported nothing" from "the statement matched nothing", so standing the estimate in for zero
    /// told the user a copy of an empty table had written however many rows a stale table statistic
    /// had guessed at.
    @Test
    func theServerCountIsReportedRatherThanTheEstimate() async throws {
        let outcome = try await ObjectCopyRowCopier(
            step: step(
                serverSideInsert: SyncStatement(sql: "INSERT INTO x SELECT 1;", objectName: "x", summary: ""),
                estimatedRows: 42
            ),
            targetDatabaseType: .mysql
        ).copy(from: CopyDriver(), to: CopyDriver()) { _ in }

        #expect(outcome.inserted == 0)
    }
}

private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    func append(_ value: Int) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
