import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProQuery
import TableProSQLGrammar
import Testing

@MainActor
@Suite("QueryEditorViewModel")
struct QueryEditorViewModelTests {
    private func makeColumns() -> [ColumnInfo] {
        [ColumnInfo(name: "id", typeName: "INT", isPrimaryKey: true, isNullable: false, ordinalPosition: 0)]
    }

    @Test("run caps a large result and keeps the first rows")
    func runCapsAndKeepsHead() async {
        let driver = MockDatabaseDriver()
        let rows = (0..<10).map { ["\($0)"] }
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: rows, rowsAffected: 0, executionTime: 0))
        ]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(driver: driver, script: .statements("SELECT * FROM t"), maxRows: 3)

        #expect(vm.legacyRows.count == 3)
        #expect(vm.legacyRows.first?.first == "0")
        #expect(vm.legacyRows.last?.first == "2")
        #expect(vm.truncationReason != nil)
        #expect(vm.truncationMessage != nil)
        if case .truncated(let reason) = vm.phase, case .rowCap(let cap) = reason {
            #expect(cap == 3)
        } else {
            Issue.record("expected truncated(.rowCap) phase, got \(vm.phase)")
        }
    }

    @Test("stop marks the run cancelled rather than letting it settle as finished")
    func stopRecordsCancellation() async {
        let driver = MockDatabaseDriver()
        let gate = QueryGate()
        driver.beforeExecute = { await gate.wait() }
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        let run = Task { await vm.run(driver: driver, script: .statements("SELECT 1")) }
        await ObservedCondition.wait { vm.isRunning }
        vm.stop()
        await gate.open()
        await run.value

        #expect(vm.truncationReason != nil)
        if case .truncated(let reason) = vm.phase, case .cancelled = reason {
            #expect(vm.truncationMessage != nil)
        } else {
            Issue.record("expected truncated(.cancelled) phase, got \(vm.phase)")
        }
        #expect(QueryExecutionOutcome(phase: vm.phase) == .stopped)
    }

    @Test("memory pressure before the first row still marks the run interrupted")
    func pressureBeforeAnyRowIsNotASuccess() async {
        let driver = MockDatabaseDriver()
        let gate = QueryGate()
        driver.beforeExecute = { await gate.wait() }
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 1, executionTime: 0))
        ]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        let run = Task { await vm.run(driver: driver, script: .statements("UPDATE t SET a = 1")) }
        await ObservedCondition.wait { vm.isRunning }
        await vm.handlePressure(.critical)
        await gate.open()
        await run.value

        if case .truncated(let reason) = vm.phase, case .memoryPressure = reason {
            #expect(QueryExecutionOutcome(phase: vm.phase) == .interrupted)
        } else {
            Issue.record("expected truncated(.memoryPressure) phase, got \(vm.phase)")
        }
    }

    @Test("stop on an idle view model changes nothing")
    func stopWhenIdleIsInert() {
        let vm = QueryEditorViewModel(windowCapacity: 100)

        vm.stop()

        #expect(vm.truncationReason == nil)
        if case .idle = vm.phase {} else {
            Issue.record("expected idle phase, got \(vm.phase)")
        }
    }

    @Test("run completes without truncation for a small result")
    func runCompletes() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1"], ["2"]], rowsAffected: 0, executionTime: 0))
        ]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(driver: driver, script: .statements("SELECT id FROM t"), maxRows: 100)

        #expect(vm.legacyRows.count == 2)
        #expect(vm.truncationReason == nil)
        #expect(vm.truncationMessage == nil)
        if case .finished = vm.phase {} else {
            Issue.record("expected finished phase, got \(vm.phase)")
        }
    }

    @Test("memory pressure after a clean finish does not relabel the result")
    func pressureDoesNotRelabelFinishedResult() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1"], ["2"]], rowsAffected: 0, executionTime: 0))
        ]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(driver: driver, script: .statements("SELECT id FROM t"), maxRows: 100)
        #expect(vm.truncationReason == nil)

        await vm.handlePressure(.warning)

        #expect(vm.legacyRows.count == 2)
        #expect(vm.truncationReason == nil)
        #expect(vm.truncationMessage == nil)
        if case .finished = vm.phase {} else {
            Issue.record("a completed result must stay finished after a memory warning")
        }
    }

    @Test("reset clears rows and returns to idle")
    func resetClears() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(driver: driver, script: .statements("SELECT id FROM t"), maxRows: 100)
        #expect(vm.legacyRows.count == 1)

        vm.reset()

        #expect(vm.legacyRows.isEmpty)
        #expect(vm.columns.isEmpty)
        if case .idle = vm.phase {} else {
            Issue.record("expected idle phase after reset")
        }
    }

    // MARK: - Scripts

    private static let createStudent = "CREATE TABLE STUDENT (SID CHAR(5) NOT NULL PRIMARY KEY, NAME VARCHAR(20))"
    private static let insertStudents = "INSERT INTO STUDENT (SID, NAME) VALUES ('03493', 'Ada'), ('03496', 'Clem')"

    @Test("every statement of a script runs, in order, and the rows they changed are summed")
    func scriptRunsEveryStatementInOrder() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [], rowsAffected: 7, executionTime: 0)),
        ]
        let script = QueryScript.plan(
            "\(Self.createStudent);\n\n\(Self.insertStudents);",
            databaseType: .sqlite,
            sendsBatchesWhole: false
        )

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(driver: driver, script: script)

        #expect(driver.executedQueries == [Self.createStudent, Self.insertStudents])
        #expect(vm.requestCount == 2)
        #expect(vm.rowsAffectedTotal == 7)
        #expect(vm.interruption == nil)
        #expect(vm.scriptSummary != nil)
        #expect(vm.hasOutcome)
        if case .finished = vm.phase {} else {
            Issue.record("expected finished phase, got \(vm.phase)")
        }
    }

    @Test("a statement that changes no rows still ends the run with an outcome, not the idle placeholder")
    func commandWithoutRowsHasAnOutcome() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0))
        ]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        #expect(!vm.hasOutcome)
        await vm.run(driver: driver, script: .statements(Self.createStudent))

        #expect(vm.hasOutcome)
        #expect(vm.columns.isEmpty)
        #expect(vm.rowsAffectedTotal == 0)
        #expect(vm.scriptSummary == nil)
        #expect(QueryExecutionOutcome(phase: vm.phase) == .completed)
    }

    @Test("a failing statement ends the script there and names its position")
    func failureStopsTheScript() async {
        let driver = MockDatabaseDriver()
        driver.scriptedTransactionState = .idle
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0)),
            .failure(MockDatabaseDriver.MockError.scripted),
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0)),
        ]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(driver: driver, script: .statements("CREATE TABLE t (x INT)", "INSERT INTO t VALUES ('bad')", "DELETE FROM t"))

        #expect(driver.executedQueries == ["CREATE TABLE t (x INT)", "INSERT INTO t VALUES ('bad')"])
        #expect(vm.interruption == QueryEditorViewModel.ScriptInterruption(
            cause: .failed(sql: "INSERT INTO t VALUES ('bad')"),
            position: 2,
            total: 3,
            kind: .statement,
            standingWork: .applied(count: 1)
        ))
        #expect(vm.interruptionHeadline != nil)
        #expect(vm.standingWorkNote != nil)
        #expect(vm.failedSQL == "INSERT INTO t VALUES ('bad')")
        #expect(QueryExecutionOutcome(phase: vm.phase) == .failed)
    }

    @Test("statements before a failure inside the script's own transaction are reported as held, not applied")
    func failureInsideOpenTransaction() async {
        let driver = MockDatabaseDriver()
        driver.scriptedTransactionState = .explicitTransaction
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0)),
            .failure(MockDatabaseDriver.MockError.scripted),
        ]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(driver: driver, script: .statements("BEGIN", "INSERT INTO t VALUES (1)"))

        #expect(vm.interruption?.standingWork == .openTransaction)
    }

    @Test("a failing first statement leaves nothing standing behind it")
    func failureOfTheFirstStatement() async {
        let driver = MockDatabaseDriver()
        driver.scriptedTransactionState = .idle
        driver.scriptedExecuteResults = [.failure(MockDatabaseDriver.MockError.scripted)]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(driver: driver, script: .statements("INSERT INTO t VALUES (1)", "SELECT 1"))

        #expect(driver.executedQueries == ["INSERT INTO t VALUES (1)"])
        #expect(vm.interruption?.standingWork == .nothing)
        #expect(vm.interruption?.position == 1)
    }

    @Test("statements a script rolled back itself are not reported as applied")
    func scriptRollbackIsNotReportedAsApplied() async {
        let driver = MockDatabaseDriver()
        driver.scriptedTransactionStates = [.explicitTransaction, .explicitTransaction, .idle, .idle]
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0)),
            .failure(MockDatabaseDriver.MockError.scripted),
        ]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(
            driver: driver,
            script: .statements("BEGIN", "INSERT INTO t VALUES (1)", "ROLLBACK", "SELECT * FROM missing_table")
        )

        #expect(vm.interruption?.standingWork == .unknown)
        #expect(vm.standingWorkNote == nil)
        #expect(vm.interruptionHeadline != nil)
    }

    @Test("an engine that cannot report its transaction state gets no claim about earlier statements")
    func unknownSessionStateMakesNoClaim() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0)),
            .failure(MockDatabaseDriver.MockError.scripted),
        ]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(driver: driver, script: .statements("INSERT INTO t VALUES (1)", "INSERT INTO t VALUES ('bad')"))

        #expect(vm.interruption?.standingWork == .unknown)
        #expect(vm.standingWorkNote == nil)
    }

    @Test("a single failing statement keeps the plain error, with no script position")
    func singleStatementFailureHasNoPosition() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [.failure(MockDatabaseDriver.MockError.scripted)]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(driver: driver, script: .statements("INSERT INTO t VALUES (1)"))

        #expect(vm.interruption == nil)
        #expect(vm.interruptionHeadline == nil)
        #expect(QueryExecutionOutcome(phase: vm.phase) == .failed)
    }

    @Test("Stop during a statement starts no statement after it")
    func stopStartsNoFurtherStatement() async {
        let driver = MockDatabaseDriver()
        let gate = QueryGate()
        driver.beforeExecute = { await gate.wait() }
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0)),
        ]

        let vm = QueryEditorViewModel(windowCapacity: 100)
        let run = Task { await vm.run(driver: driver, script: .statements("UPDATE a SET x = 1", "UPDATE b SET x = 1")) }
        await ObservedCondition.wait { vm.isRunning }
        vm.stop()
        await run.value
        await gate.open()

        #expect(!driver.executedQueries.contains("UPDATE b SET x = 1"))
        #expect(vm.interruption?.cause == .stopped)
        #expect(vm.interruption?.position == 1)
        #expect(QueryExecutionOutcome(phase: vm.phase) == .stopped)
    }

    @Test("a statement that changes how the session reads literals has the rest of the script split again")
    func scriptIsSplitAgainAfterTheSessionChanges() async {
        let escapes = SQLSessionLexicalFacts(
            determined: .backslashEscapesInSingleQuotes,
            enabled: .backslashEscapesInSingleQuotes
        )
        let noEscapes = SQLSessionLexicalFacts(
            determined: [.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes],
            enabled: []
        )
        let driver = MockDatabaseDriver()
        driver.scriptedLexicalFacts = [noEscapes, noEscapes]
        let script = QueryScript.plan(
            "SET sql_mode = 'NO_BACKSLASH_ESCAPES'; SELECT 'a\\'; SELECT 2;",
            databaseType: .mysql,
            sendsBatchesWhole: false,
            session: escapes
        )

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(driver: driver, script: script)

        #expect(driver.executedQueries == ["SET sql_mode = 'NO_BACKSLASH_ESCAPES'", "SELECT 'a\\'", "SELECT 2"])
        #expect(vm.requestCount == 3)
        #expect(QueryExecutionOutcome(phase: vm.phase) == .completed)
    }

    @Test("a driver that sends batches whole runs each GO batch whole, repeated as GO n asks")
    func batchesRunWholeAndRepeat() async {
        let driver = MockDatabaseDriver()
        driver.sendsBatchesWhole = true
        let script = QueryScript.plan(
            "DECLARE @n int = 1; SELECT @n\nGO\nINSERT INTO t VALUES (1)\nGO 2",
            databaseType: .mssql,
            sendsBatchesWhole: driver.sendsBatchesWhole
        )

        let vm = QueryEditorViewModel(windowCapacity: 100)
        await vm.run(driver: driver, script: script)

        #expect(driver.executedQueries == [
            "DECLARE @n int = 1; SELECT @n",
            "INSERT INTO t VALUES (1)",
            "INSERT INTO t VALUES (1)",
        ])
        #expect(vm.requestCount == 3)
    }
}

private extension QueryScript {
    static func statements(_ sql: String...) -> QueryScript {
        QueryScript(units: sql.map { Unit(sql: $0) }, unitKind: .statement)
    }
}

private actor QueryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
