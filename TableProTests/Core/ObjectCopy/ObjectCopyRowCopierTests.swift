//
//  ObjectCopyRowCopierTests.swift
//  TableProTests
//
//  The streaming write. Two things decide whether a copy is correct rather than
//  merely finished: the batch never exceeds the engine's bind-parameter
//  ceiling, and the parameters arrive in the order the placeholders expect.
//

@testable import TablePro
import TableProPluginKit
import XCTest

private final class CopyDriver: PluginDatabaseDriver, @unchecked Sendable {
    var streamed: [[PluginCellValue]] = []
    var batchSize = 2
    var executedQueries: [String] = []
    var executedParameters: [[PluginCellValue]] = []
    var quote: (String) -> String = { "`\($0)`" }
    var declaredParameterStyle: ParameterStyle = .questionMark
    var transactionEvents: [String] = []

    var parameterStyle: ParameterStyle { declaredParameterStyle }

    func connect() async throws {}
    func disconnect() {}

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

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

final class ObjectCopyRowCopierTests: XCTestCase {
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

    func testEveryRowReachesTheTarget() async throws {
        let source = CopyDriver()
        source.streamed = rows(5)
        let target = CopyDriver()

        let outcome = try await ObjectCopyRowCopier(step: step(), targetDatabaseType: .mysql)
            .copy(from: source, to: target) { _ in }

        XCTAssertEqual(outcome.inserted, 5)
        XCTAssertFalse(outcome.cancelled)
        XCTAssertEqual(target.executedParameters.flatMap { $0 }.count, 10)
    }

    /// One multi-row INSERT per batch, not one per row: that is the whole reason the copy is
    /// faster than exporting to a file and importing it back.
    func testRowsAreWrittenInBatchesRatherThanOneAtATime() async throws {
        let source = CopyDriver()
        source.streamed = rows(2_500)
        let target = CopyDriver()

        _ = try await ObjectCopyRowCopier(step: step(), targetDatabaseType: .mysql)
            .copy(from: source, to: target) { _ in }

        XCTAssertEqual(target.executedQueries.count, 3, "1,000 rows per statement at the row cap")
        XCTAssertTrue(target.executedQueries.allSatisfy { $0.hasPrefix("INSERT INTO `public`.`orders`") })
    }

    /// The generator flattens its rows in row-major order, and the copier hands the same
    /// sequence to the driver. If those two ever disagree, values land in the wrong columns.
    func testParametersArriveInPlaceholderOrder() async throws {
        let source = CopyDriver()
        source.streamed = [[.text("1"), .text("a")], [.text("2"), .text("b")]]
        source.batchSize = 2
        let target = CopyDriver()

        _ = try await ObjectCopyRowCopier(step: step(), targetDatabaseType: .mysql)
            .copy(from: source, to: target) { _ in }

        XCTAssertEqual(
            target.executedParameters.first?.map(\.sortKey),
            ["1", "a", "2", "b"]
        )
    }

    func testTheTargetSchemaIsWrittenIntoTheInsert() async throws {
        let source = CopyDriver()
        source.streamed = rows(1)
        let target = CopyDriver()

        _ = try await ObjectCopyRowCopier(step: step(), targetDatabaseType: .mysql)
            .copy(from: source, to: target) { _ in }

        XCTAssertEqual(
            target.executedQueries.first,
            "INSERT INTO `public`.`orders` (`id`, `name`) VALUES (?, ?), (?, ?)".replacingOccurrences(
                of: ", (?, ?)", with: ""
            )
        )
    }

    func testAnUnqualifiedTargetKeepsThePlainName() async throws {
        let source = CopyDriver()
        source.streamed = rows(1)
        let target = CopyDriver()

        _ = try await ObjectCopyRowCopier(step: step(schema: nil), targetDatabaseType: .mysql)
            .copy(from: source, to: target) { _ in }

        XCTAssertEqual(target.executedQueries.first, "INSERT INTO `orders` (`id`, `name`) VALUES (?, ?)")
    }

    func testAnEmptyTableWritesNothing() async throws {
        let source = CopyDriver()
        let target = CopyDriver()

        let outcome = try await ObjectCopyRowCopier(step: step(), targetDatabaseType: .mysql)
            .copy(from: source, to: target) { _ in }

        XCTAssertEqual(outcome.inserted, 0)
        XCTAssertTrue(target.executedQueries.isEmpty)
    }

    /// A row of the wrong width means the source answered a different question from the one the
    /// plan asked, and writing it would put values in the wrong columns.
    func testAMisalignedRowStopsTheTable() async {
        let source = CopyDriver()
        source.streamed = [[.text("1")]]
        let target = CopyDriver()

        do {
            _ = try await ObjectCopyRowCopier(step: step(), targetDatabaseType: .mysql)
                .copy(from: source, to: target) { _ in }
            XCTFail("A row of the wrong width must not be written")
        } catch {
            XCTAssertTrue(target.executedQueries.isEmpty)
        }
    }

    func testProgressReportsTheRunningTotal() async throws {
        let source = CopyDriver()
        source.streamed = rows(2_500)
        let target = CopyDriver()
        let reported = Reported()

        _ = try await ObjectCopyRowCopier(step: step(), targetDatabaseType: .mysql)
            .copy(from: source, to: target) { reported.append($0) }

        XCTAssertEqual(reported.values, [1_000, 2_000, 2_500])
    }

    // MARK: - Batch sizing

    func testTheBatchNeverExceedsTheEnginesBindParameterCeiling() throws {
        let mssql = try SQLStatementGenerator(
            tableName: "t", columns: [], primaryKeyColumns: [], databaseType: .mssql
        )
        let sqlite = try SQLStatementGenerator(
            tableName: "t", columns: [], primaryKeyColumns: [], databaseType: .sqlite
        )

        XCTAssertEqual(ObjectCopyRowCopier.batchSize(columnCount: 100, generator: mssql), 21)
        XCTAssertEqual(ObjectCopyRowCopier.batchSize(columnCount: 100, generator: sqlite), 327)
    }

    /// A one-column table would otherwise put 65,535 rows in one statement, which parses slowly
    /// everywhere and cannot be cancelled part-way.
    func testTheBatchIsCappedByRowsAsWellAsByParameters() throws {
        let mysql = try SQLStatementGenerator(
            tableName: "t", columns: [], primaryKeyColumns: [], databaseType: .mysql
        )

        XCTAssertEqual(ObjectCopyRowCopier.batchSize(columnCount: 1, generator: mysql), 1_000)
    }

    /// Oracle before 23c rejects `INSERT … VALUES (…), (…)`, which is the only form the generic
    /// generator emits, so its batches carry one row each however narrow the table is.
    func testOracleWritesOneRowPerStatement() throws {
        let oracle = try SQLStatementGenerator(
            tableName: "t", columns: [], primaryKeyColumns: [], databaseType: .oracle
        )

        XCTAssertEqual(ObjectCopyRowCopier.batchSize(columnCount: 2, generator: oracle), 1)
    }

    /// A table wider than the ceiling still writes one row at a time rather than none.
    func testAVeryWideTableStillWritesOneRowPerStatement() throws {
        let mssql = try SQLStatementGenerator(
            tableName: "t", columns: [], primaryKeyColumns: [], databaseType: .mssql
        )

        XCTAssertEqual(ObjectCopyRowCopier.batchSize(columnCount: 5_000, generator: mssql), 1)
    }

    // MARK: - Crossing engines

    /// A `t` from PostgreSQL bound into a MySQL `TINYINT(1)` is 0 outside strict mode, so every
    /// `true` in the table would arrive as `false` with nothing reported.
    func testValuesAreReshapedForTheTarget() async throws {
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

        XCTAssertEqual(target.executedParameters.first?.map(\.sortKey), ["1", "1"])
    }

    // MARK: - The server-side path

    /// One statement instead of a stream, and the source driver is never read from at all.
    func testAServerSideCopyRunsOneStatementAndReadsNothing() async throws {
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

        XCTAssertEqual(target.executedQueries, [statement.sql])
        XCTAssertTrue(target.executedParameters.isEmpty)
        XCTAssertFalse(outcome.cancelled)
    }

    /// The server's own count and never the plan's estimate. `rowsAffected` cannot tell "the driver
    /// reported nothing" from "the statement matched nothing", so standing the estimate in for zero
    /// told the user a copy of an empty table had written however many rows a stale table statistic
    /// had guessed at.
    func testTheServerCountIsReportedRatherThanTheEstimate() async throws {
        let outcome = try await ObjectCopyRowCopier(
            step: step(
                serverSideInsert: SyncStatement(sql: "INSERT INTO x SELECT 1;", objectName: "x", summary: ""),
                estimatedRows: 42
            ),
            targetDatabaseType: .mysql
        ).copy(from: CopyDriver(), to: CopyDriver()) { _ in }

        XCTAssertEqual(outcome.inserted, 0)
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
