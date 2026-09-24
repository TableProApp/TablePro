//
//  QueryBatchPlannerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

@Suite("Query batch planning")
@MainActor
struct QueryBatchPlannerTests {
    private static let reporterScript = """
        DECLARE @sn NVARCHAR(50) = '2404GQV000066A00105';

        SELECT *
        FROM serialnew
        WHERE [S/N] = @sn;

        SELECT *
        FROM [v_wms_joined]
        WHERE [S/N] = @sn;

        SELECT *
        FROM drm_report_n
        WHERE [Serial number] = @sn;

        SELECT *
        FROM serial_existed
        WHERE sn_code = @sn;
        """

    private static func batches(_ text: String, on type: DatabaseType, sourceOffset: Int = 0) -> [ExecutableBatch] {
        let grammar = type.lexicalGrammar
        return QueryBatchPlanner.batches(
            in: text,
            statements: SQLStatementScanner.executableStatements(in: text, grammar: grammar),
            separators: SQLStatementScanner.batchSeparators(in: text, grammar: grammar),
            sourceOffset: sourceOffset
        )
    }

    private static func isPlainQuery(_ type: DatabaseType) -> (String) -> Bool {
        { QueryExecutor.qualifiesForRowCap(sql: $0, tabType: .query, databaseType: type) }
    }

    // MARK: - Planning

    @Test("The reporter's script is one SQL Server batch holding all five statements")
    func reporterScriptIsOneBatch() throws {
        let batches = Self.batches(Self.reporterScript, on: .mssql)
        #expect(batches.count == 1)
        let batch = try #require(batches.first)
        #expect(batch.statements.count == 5)
        #expect(batch.repeatCount == 1)
        #expect(batch.sql.hasPrefix("DECLARE @sn"))
        #expect(batch.sql.hasSuffix("WHERE sn_code = @sn"))
        #expect(batch.sql.contains("WHERE [S/N] = @sn;"))
    }

    /// MySQL has no `GO`, so the line is text like any other and the run is the statement by statement one it was.
    @Test("An engine without batch separators runs a line holding GO as part of a statement")
    func otherEnginesIgnoreGoLines() {
        let text = "SELECT 1;\nGO\nSELECT 2;"
        #expect(SQLStatementScanner.batchSeparators(in: text, grammar: DatabaseType.mysql.lexicalGrammar).isEmpty)
        let route = QueryExecutionRoute.resolve(
            Self.batches(text, on: .mysql),
            sendsBatchesWhole: false,
            isPlainQuery: Self.isPlainQuery(.mysql)
        )
        guard case .statements(let statements) = route else {
            Issue.record("expected statements, got \(String(describing: route))")
            return
        }
        #expect(statements.map(\.sql) == ["SELECT 1", "GO\nSELECT 2"])
    }

    @Test("A GO line cuts the script into batches and carries its repeat count")
    func goLinesCutBatches() throws {
        let text = "CREATE TABLE #t (a INT);\nGO\nINSERT INTO #t VALUES (1);\nGO 3\nSELECT * FROM #t"
        let batches = Self.batches(text, on: .mssql)
        #expect(batches.map(\.sql) == ["CREATE TABLE #t (a INT)", "INSERT INTO #t VALUES (1)", "SELECT * FROM #t"])
        #expect(batches.map(\.repeatCount) == [1, 3, 1])
        #expect(batches.allSatisfy { !$0.sql.localizedCaseInsensitiveContains("\nGO") })
    }

    @Test("Consecutive GO lines leave no empty batch")
    func consecutiveGoLinesLeaveNoEmptyBatch() {
        let batches = Self.batches("SELECT 1\nGO\nGO\nSELECT 2\nGO", on: .mssql)
        #expect(batches.map(\.sql) == ["SELECT 1", "SELECT 2"])
    }

    @Test("A selection's batches are moved onto the tab's whole query")
    func selectionBatchesAreShifted() throws {
        let batches = Self.batches("SELECT 1;\nSELECT 2", on: .mssql, sourceOffset: 40)
        let batch = try #require(batches.first)
        #expect(batch.range.location == 40)
        #expect(batch.statements.map(\.range.location) == [40, 50])
    }

    // MARK: - Route

    @Test("A driver that sends batches whole runs a multi-statement script as batches")
    func scriptRunsAsBatches() {
        let route = QueryExecutionRoute.resolve(
            Self.batches(Self.reporterScript, on: .mssql),
            sendsBatchesWhole: true,
            isPlainQuery: Self.isPlainQuery(.mssql)
        )
        guard case .batches(let batches) = route else {
            Issue.record("expected batches, got \(String(describing: route))")
            return
        }
        #expect(batches.count == 1)
    }

    @Test("A lone plain query keeps the single path, for its paging and editing")
    func lonePlainQueryStaysSingle() {
        let route = QueryExecutionRoute.resolve(
            Self.batches("SELECT * FROM orders", on: .mssql),
            sendsBatchesWhole: true,
            isPlainQuery: Self.isPlainQuery(.mssql)
        )
        guard case .single(let statement) = route else {
            Issue.record("expected single, got \(String(describing: route))")
            return
        }
        #expect(statement.sql == "SELECT * FROM orders")
    }

    @Test(
        "A lone statement that can return any number of result sets runs as a batch",
        arguments: ["EXEC sp_help 'dbo.orders'", "IF 1 = 1 SELECT 1 ELSE SELECT 2", "UPDATE orders SET qty = 1"]
    )
    func loneNonQueryRunsAsBatch(sql: String) {
        let route = QueryExecutionRoute.resolve(
            Self.batches(sql, on: .mssql),
            sendsBatchesWhole: true,
            isPlainQuery: Self.isPlainQuery(.mssql)
        )
        guard case .batches = route else {
            Issue.record("expected batches, got \(String(describing: route))")
            return
        }
    }

    /// An installed plugin built before batches existed keeps exactly the run it had.
    @Test("A driver that cannot send batches keeps statement by statement")
    func driverWithoutBatchesKeepsStatements() {
        let route = QueryExecutionRoute.resolve(
            Self.batches(Self.reporterScript, on: .mssql),
            sendsBatchesWhole: false,
            isPlainQuery: Self.isPlainQuery(.mssql)
        )
        guard case .statements(let statements) = route else {
            Issue.record("expected statements, got \(String(describing: route))")
            return
        }
        #expect(statements.count == 5)
    }

    /// `GO 5` repeats a batch only where the batch is what the server receives. Running it once would report a
    /// success for work the script asked for five times, and expanding the count into statements would put up to
    /// `Int32.max` copies in memory before anything ran.
    @Test("A driver that cannot send batches refuses a repeated batch instead of running it once")
    func driverWithoutBatchesRefusesRepeatedBatch() {
        let route = QueryExecutionRoute.resolve(
            Self.batches("INSERT INTO t VALUES (1)\nGO 3\nINSERT INTO t VALUES (2)", on: .mssql),
            sendsBatchesWhole: false,
            isPlainQuery: Self.isPlainQuery(.mssql)
        )
        guard case .needsBatchDriver = route else {
            Issue.record("expected needsBatchDriver, got \(String(describing: route))")
            return
        }
    }

    @Test("The largest GO count resolves without copying the batch")
    func largestRepeatCountResolvesAsOneBatch() {
        let route = QueryExecutionRoute.resolve(
            Self.batches("SELECT 1\nGO 2147483647", on: .mssql),
            sendsBatchesWhole: true,
            isPlainQuery: Self.isPlainQuery(.mssql)
        )
        guard case .batches(let batches) = route else {
            Issue.record("expected batches, got \(String(describing: route))")
            return
        }
        #expect(batches.map(\.repeatCount) == [2_147_483_647])
    }

    @Test("A repeated plain query runs as a batch, so every repetition's result is kept")
    func repeatedPlainQueryRunsAsBatch() {
        let route = QueryExecutionRoute.resolve(
            Self.batches("SELECT 1\nGO 2", on: .mssql),
            sendsBatchesWhole: true,
            isPlainQuery: Self.isPlainQuery(.mssql)
        )
        guard case .batches = route else {
            Issue.record("expected batches, got \(String(describing: route))")
            return
        }
    }

    @Test("A batch points back at its first statement, which the editor can find again")
    func batchAnchorsOnItsFirstStatement() throws {
        let batch = try #require(Self.batches(Self.reporterScript, on: .mssql).first)
        let first = try #require(batch.statements.first)
        #expect(batch.anchor == StatementAnchor(first))
    }

    @Test("An empty text has no route")
    func emptyTextHasNoRoute() {
        let route = QueryExecutionRoute.resolve(
            Self.batches("  -- nothing\n", on: .mssql),
            sendsBatchesWhole: true,
            isPlainQuery: Self.isPlainQuery(.mssql)
        )
        guard case .none = route else {
            Issue.record("expected no route, got \(String(describing: route))")
            return
        }
    }

    // MARK: - Mapping results to statements

    @Test("Plain queries and declarations map one result set to each query")
    func declarationsAndQueriesMap() throws {
        let batch = try #require(Self.batches(Self.reporterScript, on: .mssql).first)
        #expect(BatchResultMapping.mapsToStatements(
            batch, resultSetCount: 4, hasErrors: false, isPlainQuery: Self.isPlainQuery(.mssql)
        ))
        #expect(!BatchResultMapping.mapsToStatements(
            batch, resultSetCount: 3, hasErrors: false, isPlainQuery: Self.isPlainQuery(.mssql)
        ))
        #expect(!BatchResultMapping.mapsToStatements(
            batch, resultSetCount: 4, hasErrors: true, isPlainQuery: Self.isPlainQuery(.mssql)
        ))
    }

    @Test("A procedure call or a loop leaves the result sets unmapped")
    func controlFlowDoesNotMap() throws {
        let exec = try #require(Self.batches("SELECT 1;\nEXEC sp_who;", on: .mssql).first)
        #expect(!BatchResultMapping.mapsToStatements(
            exec, resultSetCount: 2, hasErrors: false, isPlainQuery: Self.isPlainQuery(.mssql)
        ))
        let loop = try #require(Self.batches("WHILE 1 = 0 SELECT 1;\nSELECT 2;", on: .mssql).first)
        #expect(!BatchResultMapping.mapsToStatements(
            loop, resultSetCount: 2, hasErrors: false, isPlainQuery: Self.isPlainQuery(.mssql)
        ))
    }

    @Test("A repeated batch is never mapped")
    func repeatedBatchDoesNotMap() throws {
        let batch = try #require(Self.batches("SELECT 1\nGO 2", on: .mssql).first)
        #expect(!BatchResultMapping.mapsToStatements(
            batch, resultSetCount: 1, hasErrors: false, isPlainQuery: Self.isPlainQuery(.mssql)
        ))
    }

    @Test("A statement that reads a local or table variable cannot be sent again on its own")
    func localVariableReferences() {
        let cases: [(sql: String, expected: Bool)] = [
            ("SELECT * FROM t WHERE sn = @sn", true),
            ("SELECT * FROM @rows", true),
            ("SELECT @@ROWCOUNT", false),
            ("SELECT '@sn' AS literal", false),
            ("SELECT [@sn] FROM t", false),
            ("SELECT * FROM t -- @sn", false),
            ("SELECT * FROM t", false),
        ]
        let grammar = DatabaseType.mssql.lexicalGrammar
        for entry in cases {
            #expect(
                BatchResultMapping.referencesLocalVariable(entry.sql, grammar: grammar) == entry.expected,
                "\(entry.sql)"
            )
        }
    }

    // MARK: - Error text

    @Test("A batch's error line is moved onto the editor's line")
    func errorLineMapsToEditor() {
        let error = PluginBatchError(
            message: "Invalid object name 'x'.", code: 208, line: 3, procedure: nil, precedingResultSetCount: 1
        )
        #expect(BatchErrorText.describe(error, batchStartLine: 10) == "Line 12: Invalid object name 'x'.")
    }

    @Test("An error raised inside a procedure keeps the procedure's own line")
    func procedureErrorKeepsItsLine() {
        let error = PluginBatchError(
            message: "boom", code: 50_000, line: 4, procedure: "dbo.p_err", precedingResultSetCount: 0
        )
        #expect(BatchErrorText.describe(error, batchStartLine: 10) == "dbo.p_err, line 4: boom")
    }

    @Test("An error with no line is its message")
    func errorWithoutLineIsItsMessage() {
        let error = PluginBatchError(message: "boom", code: nil, line: nil, procedure: nil, precedingResultSetCount: 0)
        #expect(BatchErrorText.describe(error, batchStartLine: 5) == "boom")
        #expect(BatchErrorText.describe([], batchStartLine: 5) == nil)
    }

    @Test("Every batch's line comes out of one pass over the text")
    func linesOfSeveralLocations() {
        let text = "SELECT 1\nGO\nSELECT 2\r\nGO\nSELECT 3"
        #expect(BatchErrorText.lines(of: [0, 12, 25], in: text) == [1, 3, 5])
        #expect(BatchErrorText.lines(of: [], in: text).isEmpty)
    }

    @Test("Lines are counted the way the server counts them, CRLF once")
    func lineCounting() {
        #expect(BatchErrorText.line(of: 0, in: "SELECT 1") == 1)
        #expect(BatchErrorText.line(of: 9, in: "SELECT 1\nSELECT 2") == 2)
        #expect(BatchErrorText.line(of: 10, in: "SELECT 1\r\nSELECT 2") == 2)
        #expect(BatchErrorText.line(of: 5, in: "a\rb\rc") == 3)
    }
}
