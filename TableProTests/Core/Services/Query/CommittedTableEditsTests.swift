//
//  CommittedTableEditsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct CommittedTableEditsTests {
    private static let connectionId = UUID()

    private static func edits(
        _ statements: [String],
        on type: DatabaseType = .postgresql,
        database: String = "shop",
        schema: String? = "public",
        commit: StatementCommitEvidence = .runStartedIn(.idle, endedIn: .idle, appTransaction: .none)
    ) -> [TableCatalogEdit] {
        var hazards = TableNameHazards()
        return edits(statements, on: type, database: database, schema: schema, commit: commit, hazards: &hazards)
    }

    private static func edits(
        _ statements: [String],
        on type: DatabaseType = .postgresql,
        database: String = "shop",
        schema: String? = "public",
        commit: StatementCommitEvidence = .runStartedIn(.idle, endedIn: .idle, appTransaction: .none),
        hazards: inout TableNameHazards
    ) -> [TableCatalogEdit] {
        let succeeded = SucceededStatements(
            scope: DatabaseScope(connectionId: connectionId, database: database, schema: schema),
            databaseType: type,
            statements: statements,
            commit: commit
        )
        return CommittedTableEdits.edits(in: succeeded, grammar: type.lexicalGrammar, hazards: &hazards)
    }

    private static func dropped(_ name: String, database: String = "shop", schema: String? = "public") -> TableCatalogEdit {
        .dropped(TablePlacement(database: database, schema: schema, name: name), kind: .table)
    }

    private static func renamed(
        _ name: String, to newName: String, database: String = "shop", schema: String? = "public"
    ) -> TableCatalogEdit {
        .renamed(TablePlacement(database: database, schema: schema, name: name), to: newName, kind: .table)
    }

    private static func sqlServerEdits(
        _ statements: [String],
        commit: StatementCommitEvidence = .runStartedIn(.idle, endedIn: .idle, appTransaction: .none)
    ) -> [TableCatalogEdit] {
        edits(statements, on: .mssql, database: "sales", schema: "dbo", commit: commit)
    }

    // MARK: - The reported case

    @Test("A table dropped and created again under the same name is a drop of the old one")
    func dropAndRecreate() {
        #expect(Self.edits(["DROP TABLE public.people", "CREATE TABLE public.people (id int)"]) == [Self.dropped("people")])
        #expect(
            Self.edits(["DROP TABLE people", "CREATE TABLE people (id int)"], on: .mysql, schema: nil)
                == [Self.dropped("people", schema: nil)]
        )
        #expect(
            Self.edits(["DROP TABLE people", "CREATE TABLE people (id int)"], on: .sqlite, database: "/tmp/app.db", schema: nil)
                == [Self.dropped("people", database: "/tmp/app.db", schema: nil)]
        )
    }

    @Test("Every name of a multi-table drop is placed where it lives")
    func multiTableDrop() {
        #expect(
            Self.edits(["DROP TABLE IF EXISTS public.a, sales.b CASCADE"])
                == [Self.dropped("a"), Self.dropped("b", schema: "sales")]
        )
    }

    /// PostgreSQL resolves a bare name through a search path and a temporary namespace that a
    /// function or `SELECT ... INTO TEMP` can change without the text showing it.
    @Test("A bare name is not placed on PostgreSQL, DuckDB or SQL Server")
    func bareNamesOnSessionResolvedEngines() {
        #expect(Self.edits(["DROP TABLE people"]).isEmpty)
        #expect(Self.edits(["DROP TABLE people"], on: .duckdb, database: "analytics", schema: "main").isEmpty)
        #expect(Self.edits(["DROP TABLE people"], on: .mssql, database: "sales", schema: "dbo").isEmpty)
    }

    @Test("A name inside a session's temporary container is never placed")
    func temporaryContainers() {
        #expect(Self.edits(["DROP TABLE pg_temp.people", "DROP TABLE pg_temp_3.people"]).isEmpty)
        #expect(Self.edits(["DROP TABLE pg_temporary.people"]) == [Self.dropped("people", schema: "pg_temporary")])
        #expect(Self.edits(["DROP TABLE temp.main.people"], on: .duckdb, database: "analytics", schema: "main").isEmpty)
    }

    @Test("A rename keeps the table in its schema whatever the statement's own scope is")
    func renameStaysInItsSchema() {
        #expect(Self.edits(["ALTER TABLE sales.orders RENAME TO Orders_2019"]) == [
            Self.renamed("orders", to: "orders_2019", schema: "sales")
        ])
    }

    // MARK: - Commit evidence

    @Test("A single statement counts only when the session holds no transaction after it")
    func singleStatementNeedsAnIdleSession() {
        #expect(Self.edits(["DROP TABLE public.people"], commit: .statementLeftSession(.idle)) == [Self.dropped("people")])
        #expect(Self.edits(["DROP TABLE public.people"], commit: .statementLeftSession(.inTransaction)).isEmpty)
        #expect(Self.edits(["DROP TABLE public.people"], commit: .statementLeftSession(.abortedTransaction)).isEmpty)
        #expect(Self.edits(["DROP TABLE public.people"], commit: .statementLeftSession(.unknown)).isEmpty)
    }

    @Test("An engine that commits DDL as it runs needs no word from the session")
    func implicitCommitEngines() {
        #expect(
            Self.edits(["DROP TABLE people"], on: .mysql, schema: nil, commit: .statementLeftSession(.unknown))
                == [Self.dropped("people", schema: nil)]
        )
        #expect(
            Self.edits(["BEGIN", "DROP TABLE people", "ROLLBACK"], on: .mysql, schema: nil)
                == [Self.dropped("people", schema: nil)]
        )
        #expect(
            Self.edits(["DROP TABLE emp"], on: .oracle, database: "ORCL", schema: "HR", commit: .statementLeftSession(.inTransaction))
                == [Self.dropped("EMP", database: "ORCL", schema: "HR")]
        )
    }

    @Test("A drop the script rolls back is not a drop")
    func rolledBackDrop() {
        #expect(Self.edits(["BEGIN", "DROP TABLE public.people", "ROLLBACK"]).isEmpty)
        #expect(Self.edits(["BEGIN", "DROP TABLE public.people", "ROLLBACK TO SAVEPOINT s", "COMMIT"]).isEmpty)
    }

    @Test("A drop the script commits is a drop, and a run that ends with a transaction open adopts nothing")
    func committedAndOpenDrops() {
        #expect(Self.edits(["BEGIN", "DROP TABLE public.people", "COMMIT"]) == [Self.dropped("people")])
        #expect(Self.edits(["BEGIN", "DROP TABLE public.people", "END"]) == [Self.dropped("people")])
        #expect(
            Self.edits(
                ["DROP TABLE public.a", "BEGIN", "DROP TABLE public.b"],
                commit: .runStartedIn(.idle, endedIn: .inTransaction, appTransaction: .none)
            ).isEmpty
        )
    }

    @Test("A COMMIT inside a nested transaction does not commit the outer one")
    func nestedTransactions() {
        #expect(
            Self.edits(
                ["BEGIN TRAN", "BEGIN TRAN", "DROP TABLE dbo.t", "COMMIT TRAN"], on: .mssql, database: "sales", schema: "dbo"
            ).isEmpty
        )
        #expect(
            Self.edits(
                ["BEGIN TRAN", "BEGIN TRAN", "DROP TABLE dbo.t", "COMMIT TRAN", "COMMIT TRAN"],
                on: .mssql, database: "sales", schema: "dbo"
            ) == [Self.dropped("t", database: "sales", schema: "dbo")]
        )
        #expect(
            Self.edits(["SAVEPOINT s", "DROP TABLE t", "RELEASE s"], on: .sqlite, database: "/tmp/app.db", schema: nil)
                == [Self.dropped("t", database: "/tmp/app.db", schema: nil)]
        )
    }

    @Test("A run that started or ended inside a transaction, or on a session that could not say, is not read")
    func runStartedInTransaction() {
        #expect(
            Self.edits(
                ["DROP TABLE public.people"], commit: .runStartedIn(.inTransaction, endedIn: .idle, appTransaction: .none)
            ).isEmpty
        )
        #expect(
            Self.edits(
                ["DROP TABLE public.people", "COMMIT"], commit: .runStartedIn(.unknown, endedIn: .idle, appTransaction: .none)
            ).isEmpty
        )
        #expect(
            Self.edits(
                ["DROP TABLE public.people"], commit: .runStartedIn(.idle, endedIn: .unknown, appTransaction: .none)
            ).isEmpty
        )
        #expect(
            Self.edits(
                ["DROP TABLE public.people"], commit: .runStartedIn(.idle, endedIn: .abortedTransaction, appTransaction: .none)
            ).isEmpty
        )
    }

    /// `SET IMPLICIT_TRANSACTIONS ON` in an earlier run leaves `@@TRANCOUNT` at 0 until the next
    /// `DROP`, which then opens a transaction no statement in the script shows.
    @Test("A SQL Server script run under implicit transactions from an earlier run adopts nothing")
    func implicitTransactionsFromAnEarlierRun() {
        let endsOpen = StatementCommitEvidence.runStartedIn(.idle, endedIn: .inTransaction, appTransaction: .none)
        #expect(Self.sqlServerEdits(["DROP TABLE dbo.people", "SELECT 1"], commit: endsOpen).isEmpty)
        #expect(Self.sqlServerEdits(["DROP TABLE dbo.people", "ROLLBACK"]).isEmpty)
        #expect(Self.sqlServerEdits(["DROP TABLE dbo.people", "COMMIT"]).isEmpty)
        #expect(
            Self.sqlServerEdits(["DROP TABLE dbo.a", "BEGIN TRAN", "DROP TABLE dbo.b", "COMMIT TRAN"], commit: endsOpen)
                .isEmpty
        )
        #expect(
            Self.sqlServerEdits(
                ["DROP TABLE dbo.people"],
                commit: .run(startedIn: .idle, endedIn: .inTransaction, plan: .appTransaction, completed: true)
            ).isEmpty
        )
    }

    /// Under `XACT_ABORT` a failed statement rolls back everything, the `DROP` an implicit
    /// transaction held included, and the run reports only the statements before it.
    @Test("A transaction the text left open that the session says is closed was ended unseen")
    func transactionClosedUnseen() {
        #expect(Self.sqlServerEdits(["DROP TABLE dbo.a", "BEGIN TRAN"]).isEmpty)
        #expect(Self.edits(["DROP TABLE public.a", "BEGIN", "DROP TABLE public.b"]).isEmpty)
    }

    @Test("A run on a SQL Server session that commits as it goes adopts what it dropped")
    func sqlServerAutocommitRun() {
        #expect(
            Self.sqlServerEdits(["DROP TABLE dbo.people", "SELECT 1"])
                == [Self.dropped("people", database: "sales", schema: "dbo")]
        )
    }

    @Test("A stray COMMIT or ROLLBACK changes nothing on an engine that commits DDL as it runs")
    func strayTransactionControlOnImplicitCommitEngines() {
        #expect(Self.edits(["DROP TABLE people", "ROLLBACK"], on: .mysql, schema: nil) == [Self.dropped("people", schema: nil)])
        #expect(
            Self.edits(
                ["DROP TABLE people", "BEGIN"], on: .mysql, schema: nil,
                commit: .runStartedIn(.idle, endedIn: .inTransaction, appTransaction: .none)
            ) == [Self.dropped("people", schema: nil)]
        )
    }


    @Test("A run the app wrapped counts once the app committed it, and not once it rolled it back")
    func appTransaction() {
        #expect(
            Self.edits(
                ["DROP TABLE public.people", "INSERT INTO log VALUES (1)"],
                commit: .run(startedIn: .idle, endedIn: .idle, plan: .appTransaction, completed: true)
            ) == [Self.dropped("people")]
        )
        #expect(
            Self.edits(
                ["DROP TABLE public.people"],
                commit: .run(startedIn: .idle, endedIn: .idle, plan: .appTransaction, completed: false)
            ).isEmpty
        )
        #expect(
            Self.edits(
                ["DROP TABLE public.people"],
                commit: .run(startedIn: .idle, endedIn: .idle, plan: .autocommit, completed: false)
            ) == [Self.dropped("people")]
        )
    }

    /// A bare `ROLLBACK` does not make a script manage its own transaction, so the app still wraps
    /// it, and that `ROLLBACK` is what ends the app's transaction.
    @Test("A ROLLBACK inside a run the app wrapped takes back what came before it")
    func rollbackInsideTheAppTransaction() {
        let wrapped = StatementCommitEvidence.run(startedIn: .idle, endedIn: .idle, plan: .appTransaction, completed: true)
        #expect(Self.edits(["DROP TABLE public.t", "ROLLBACK"], commit: wrapped).isEmpty)
        #expect(
            Self.edits(["DROP TABLE public.t", "ROLLBACK", "DROP TABLE public.u"], commit: wrapped)
                == [Self.dropped("u")]
        )
        #expect(Self.edits(["DROP TABLE public.t", "COMMIT"], commit: wrapped) == [Self.dropped("t")])
    }

    @Test("Turning implicit transactions on leaves nothing after it that can be judged")
    func implicitTransactions() {
        #expect(
            Self.edits(
                ["SET IMPLICIT_TRANSACTIONS ON", "DROP TABLE dbo.t", "ROLLBACK"], on: .mssql, database: "sales", schema: "dbo"
            ).isEmpty
        )
    }

    @Test("A SQL Server run holding control flow adopts nothing, since a statement in its batch may have been skipped")
    func controlFlowInsideABatch() {
        #expect(Self.sqlServerEdits(["GOTO done", "DROP TABLE dbo.people", "done: SELECT 1"]).isEmpty)
        #expect(Self.sqlServerEdits(["DROP TABLE dbo.a", "IF 1 = 0 BEGIN", "DROP TABLE dbo.b", "END"]).isEmpty)
        #expect(Self.sqlServerEdits(["BEGIN TRY", "DROP TABLE dbo.people", "END TRY BEGIN CATCH", "END CATCH"]).isEmpty)
    }

    // MARK: - Name context and hazards

    @Test("USE moves a MySQL bare name onto the database it selected")
    func useMovesMySQLNames() {
        #expect(
            Self.edits(["USE archive", "DROP TABLE orders"], on: .mysql, schema: nil)
                == [Self.dropped("orders", database: "archive", schema: nil)]
        )
    }

    @Test("A schema moved by hand leaves bare names unplaced from then on, in this run and every later one")
    func schemaMovedByHand() {
        var hazards = TableNameHazards()
        #expect(
            Self.edits(
                ["ALTER SESSION SET CURRENT_SCHEMA = SCOTT", "DROP TABLE emp", "DROP TABLE hr.dept"],
                on: .oracle, database: "ORCL", schema: "HR", hazards: &hazards
            ) == [Self.dropped("DEPT", database: "ORCL", schema: "HR")]
        )
        #expect(hazards.namesMayBeShadowed)
        #expect(Self.edits(["DROP TABLE emp"], on: .oracle, database: "ORCL", schema: "HR", hazards: &hazards).isEmpty)
    }

    @Test("A temporary table shadows the real one for good, in this run and every later one")
    func temporaryShadowing() {
        var hazards = TableNameHazards()
        #expect(
            Self.edits(
                ["CREATE TEMP TABLE people (id int)", "DROP TABLE people", "DROP TABLE people"],
                on: .sqlite, database: "/tmp/app.db", schema: nil, hazards: &hazards
            ).isEmpty
        )
        #expect(hazards.temporaryNames == ["people"])
        #expect(
            Self.edits(
                ["DROP TABLE people", "DROP TABLE orders"], on: .sqlite, database: "/tmp/app.db", schema: nil, hazards: &hazards
            ) == [Self.dropped("orders", database: "/tmp/app.db", schema: nil)]
        )
        var caseFolded = TableNameHazards()
        #expect(
            Self.edits(
                ["CREATE TEMP TABLE People (id int)", "DROP TABLE people"],
                on: .sqlite, database: "/tmp/app.db", schema: nil, hazards: &caseFolded
            ).isEmpty
        )
        var sqliteQualified = TableNameHazards()
        _ = Self.edits(
            ["CREATE TABLE temp.people (id int)"], on: .sqlite, database: "/tmp/app.db", schema: nil, hazards: &sqliteQualified
        )
        #expect(sqliteQualified.temporaryNames == ["people"])
    }

    @Test("A temporary table renamed onto a real table's name keeps shadowing it")
    func renamedTemporaryTable() {
        var hazards = TableNameHazards()
        #expect(
            Self.edits(
                ["CREATE TEMP TABLE scratch (id int)", "ALTER TABLE scratch RENAME TO people", "DROP TABLE people"],
                on: .sqlite, database: "/tmp/app.db", schema: nil, hazards: &hazards
            ).isEmpty
        )
        #expect(hazards.temporaryNames == ["scratch", "people"])
        var qualified = TableNameHazards()
        _ = Self.edits(
            ["ALTER TABLE temp.scratch RENAME TO orders"], on: .sqlite, database: "/tmp/app.db", schema: nil,
            hazards: &qualified
        )
        #expect(qualified.temporaryNames == ["orders"])
    }

    @Test("A temporary table is remembered even when its transaction is one the text cannot judge")
    func temporaryTableInsideATransaction() {
        var hazards = TableNameHazards()
        _ = Self.edits(
            ["CREATE TEMP TABLE people (id int)"], on: .sqlite, database: "/tmp/app.db", schema: nil,
            commit: .statementLeftSession(.inTransaction), hazards: &hazards
        )
        #expect(hazards.temporaryNames == ["people"])
    }

    @Test("A MySQL temporary table hides the real one under its qualified name too, even after it is dropped")
    func mySQLTemporaryTables() {
        var hazards = TableNameHazards()
        #expect(
            Self.edits(
                ["CREATE TEMPORARY TABLE people (id int)", "DROP TABLE shop.people"], on: .mysql, schema: nil, hazards: &hazards
            ).isEmpty
        )
        #expect(
            Self.edits(["DROP TEMPORARY TABLE people", "DROP TABLE people"], on: .mysql, schema: nil, hazards: &hazards)
                .isEmpty
        )
    }

    @Test("A schema-qualified PostgreSQL name never reaches a temporary table or a moved search path")
    func qualifiedNamesAreNotShadowed() {
        var hazards = TableNameHazards(temporaryNames: ["people"], namesMayBeShadowed: true)
        #expect(Self.edits(["DROP TABLE public.people"], hazards: &hazards) == [Self.dropped("people")])
    }

    @Test("Code the server runs unseen leaves bare MySQL names, and qualified ones, unplaced")
    func unseenCode() {
        #expect(Self.edits(["CALL rebuild()", "DROP TABLE people", "DROP TABLE shop.orders"], on: .mysql, schema: nil).isEmpty)
        #expect(
            Self.edits(["CALL rebuild()", "DROP TABLE public.people"])
                == [Self.dropped("people")]
        )
    }

    @Test("An Oracle global temporary table is a real table and is dropped like one")
    func oracleGlobalTemporaryTable() {
        #expect(
            Self.edits(
                ["CREATE GLOBAL TEMPORARY TABLE gtt (id NUMBER)", "DROP TABLE gtt"], on: .oracle, database: "ORCL", schema: "HR"
            ) == [Self.dropped("GTT", database: "ORCL", schema: "HR")]
        )
    }

    // MARK: - Renames

    @Test("SQL Server's sp_rename keeps the table in its schema and takes the new name as written")
    func sqlServerStoredProcedureRename() {
        #expect(
            Self.edits(["EXEC sp_rename 'dbo.people', 'Persons'"], on: .mssql, database: "sales", schema: "dbo")
                == [Self.renamed("people", to: "Persons", database: "sales", schema: "dbo")]
        )
        #expect(Self.edits(["EXEC sp_rename 'people', 'persons'"], on: .mssql, database: "sales", schema: "dbo").isEmpty)
    }

    @Test("A conditional rename is never adopted")
    func conditionalRename() {
        #expect(Self.edits(["ALTER TABLE IF EXISTS public.missing RENAME TO live"]).isEmpty)
    }

    @Test("A rename chain is applied pair by pair in the order it was written")
    func renameChain() {
        #expect(
            Self.edits(["RENAME TABLE a TO tmp, b TO a, tmp TO b"], on: .mysql, schema: nil) == [
                Self.renamed("a", to: "tmp", schema: nil),
                Self.renamed("b", to: "a", schema: nil),
                Self.renamed("tmp", to: "b", schema: nil)
            ]
        )
    }

    @Test("A rename that moves the table to another database is left alone, whole")
    func crossDatabaseRename() {
        #expect(Self.edits(["RENAME TABLE a TO b, c TO archive.c"], on: .mysql, schema: nil).isEmpty)
        #expect(Self.edits(["ALTER TABLE a RENAME TO archive.a"], on: .mysql, schema: nil).isEmpty)
        #expect(
            Self.edits(["RENAME TABLE archive.a TO archive.b"], on: .mysql, schema: nil)
                == [Self.renamed("a", to: "b", database: "archive", schema: nil)]
        )
    }

    @Test("An engine with no known dialect adopts nothing")
    func unknownEngine() {
        #expect(Self.edits(["DROP TABLE people"], on: .snowflake).isEmpty)
        #expect(Self.edits(["DROP TABLE people"], on: .cockroachdb).isEmpty)
    }
}

struct SucceededStatementsProbeTests {
    private static func probe(
        _ sql: String, on type: DatabaseType, state: PluginSessionTransactionState
    ) async -> SucceededStatements? {
        let connection = TestFixtures.makeConnection(type: type)
        let driver = ScriptAnsweringDriver(connection: connection, transactionState: state)
        return await SucceededStatements.single(
            sql,
            scope: DatabaseScope(connectionId: connection.id, database: "shop", schema: "public"),
            databaseType: type,
            grammar: type.lexicalGrammar,
            ranOn: driver
        )
    }

    @Test("A statement that edits no table reports nothing")
    func readsReportNothing() async {
        #expect(await Self.probe("SELECT * FROM people", on: .postgresql, state: .idle) == nil)
        #expect(await Self.probe("DROP TABLE people", on: .snowflake, state: .idle) == nil)
    }

    @Test("A drop on a transactional engine carries what the session held after it")
    func transactionalEngineAsksTheSession() async {
        let report = await Self.probe("DROP TABLE people", on: .postgresql, state: .inTransaction)
        #expect(report?.commit == .statementLeftSession(.inTransaction))
        #expect(report?.statements == ["DROP TABLE people"])
    }

    @Test("An engine that commits DDL as it runs is not asked")
    func implicitCommitEngineIsNotAsked() async {
        let report = await Self.probe("DROP TABLE people", on: .mysql, state: .inTransaction)
        #expect(report?.commit == .statementLeftSession(.unknown))
    }

    @Test("A run asks the session how it ended only when it drops or renames a table on a transactional engine")
    func runNeedsEndState() {
        #expect(SucceededStatements.runNeedsEndState(
            ["SELECT 1", "DROP TABLE dbo.people"], databaseType: .mssql, grammar: DatabaseType.mssql.lexicalGrammar
        ))
        #expect(!SucceededStatements.runNeedsEndState(
            ["SELECT 1", "INSERT INTO t VALUES (1)"], databaseType: .postgresql, grammar: DatabaseType.postgresql.lexicalGrammar
        ))
        #expect(!SucceededStatements.runNeedsEndState(
            ["DROP TABLE people"], databaseType: .mysql, grammar: DatabaseType.mysql.lexicalGrammar
        ))
        #expect(!SucceededStatements.runNeedsEndState(
            ["DROP TABLE people"], databaseType: .snowflake, grammar: DatabaseType.snowflake.lexicalGrammar
        ))
    }

    @Test("A temporary table's creation and a procedure call are reported without asking the session")
    func hazardsAreReported() async {
        let created = await Self.probe("CREATE TEMP TABLE people (id int)", on: .sqlite, state: .inTransaction)
        #expect(created?.commit == .statementLeftSession(.unknown))
        let called = await Self.probe("CALL rebuild()", on: .mysql, state: .idle)
        #expect(called?.statements == ["CALL rebuild()"])
    }
}

struct ExecutedStatementTextsTests {
    /// `GO 2` runs a rename chain twice, which leaves every table where it started, so the chain has
    /// to be replayed twice too.
    @Test("A batch run more than once with GO n reports its statements once per run")
    func repeatedBatch() {
        let grammar = DatabaseType.mssql.lexicalGrammar
        let batches = QueryBatchPlanner.batches(
            in: "EXEC sp_rename 'dbo.a', 'tmp'; EXEC sp_rename 'dbo.b', 'a'; EXEC sp_rename 'dbo.tmp', 'b'\nGO 2",
            model: QueryStatementModel.forDatabaseType(.mssql),
            grammar: grammar
        )
        #expect(batches.count == 1)
        let statements = batches.flatMap(\.executedStatementTexts)
        #expect(statements.count == 6)
        var hazards = TableNameHazards()
        let edits = CommittedTableEdits.edits(
            in: SucceededStatements(
                scope: DatabaseScope(connectionId: UUID(), database: "sales", schema: "dbo"),
                databaseType: .mssql,
                statements: statements,
                commit: .runStartedIn(.idle, endedIn: .idle, appTransaction: .none)
            ),
            grammar: grammar,
            hazards: &hazards
        )
        let placed = { (name: String) in TablePlacement(database: "sales", schema: "dbo", name: name) }
        let swap: [TableCatalogEdit] = [
            .renamed(placed("a"), to: "tmp", kind: .table),
            .renamed(placed("b"), to: "a", kind: .table),
            .renamed(placed("tmp"), to: "b", kind: .table)
        ]
        #expect(edits == swap + swap)
    }
}

struct ImportNameHazardTests {
    /// The import runs on the editor's own session, so a temporary table it makes shadows the real
    /// one there for every later run.
    @Test("An imported file's temporary tables and procedure calls are kept for the catalog, and nothing else")
    func importRecordsHazards() async throws {
        let connection = TestFixtures.makeConnection(type: .mysql)
        let sink = ImportDataSinkAdapter(driver: ScriptAnsweringDriver(connection: connection), databaseType: .mysql)

        try await sink.execute(statement: "CREATE TEMPORARY TABLE people (id int)")
        try await sink.execute(statement: "INSERT INTO people VALUES (1)")
        try await sink.execute(statement: "DROP TABLE IF EXISTS orders")
        try await sink.execute(statement: "CALL rebuild()")

        #expect(sink.nameHazardStatements == ["CREATE TEMPORARY TABLE people (id int)", "CALL rebuild()"])
    }
}

@MainActor
struct ScriptBatchProgressTests {
    /// SQL Server commits each batch of a script as it runs, so the batches before a failing one
    /// have to be reported even though the call fails.
    @Test("A script that fails part way records the batches that finished and the state it started in")
    func failedScriptKeepsItsPrefix() async throws {
        let connection = TestFixtures.makeConnection(database: "sales", type: .mssql)
        let driver = ScriptAnsweringDriver(connection: connection, transactionState: .idle) { query in
            guard query.contains("missing") else { return .empty }
            return ScriptAnsweringDriver.batch(
                [],
                errors: [
                    PluginBatchError(
                        message: "Invalid object name 'missing'.", code: 208, line: 1, procedure: nil,
                        precedingResultSetCount: 0
                    )
                ]
            )
        }
        let grammar = DatabaseType.mssql.lexicalGrammar
        let batches = QueryBatchPlanner.batches(
            in: "DROP TABLE dbo.people\nGO\nSELECT * FROM missing\nGO\nDROP TABLE dbo.orders",
            model: QueryStatementModel.forDatabaseType(.mssql),
            grammar: grammar
        )
        let progress = ScriptBatchProgress()

        await #expect(throws: DatabaseError.self) {
            try await ScriptBatchRun.run(
                batches, startLines: [1, 3, 5], rowCap: 100, driver: driver, progress: progress
            )
        }

        #expect(batches.count == 3)
        #expect(progress.completedBatchCount == 1)
        #expect(progress.startState == .idle)
        #expect(progress.endState == .idle)
        let succeeded = progress.succeededStatements(
            of: batches, scope: Self.scope(of: connection), databaseType: .mssql
        )
        #expect(succeeded?.statements == ["DROP TABLE dbo.people"])
        var hazards = TableNameHazards()
        let edits = succeeded.map { CommittedTableEdits.edits(in: $0, grammar: grammar, hazards: &hazards) }
        #expect(edits == [.dropped(TablePlacement(database: "sales", schema: "dbo", name: "people"), kind: .table)])
    }

    /// `SET IMPLICIT_TRANSACTIONS ON` in an earlier call leaves `@@TRANCOUNT` at 0 until the
    /// script's `DROP` opens a transaction that nothing in the script commits.
    @Test("A script that leaves the session inside a transaction records it, and adopts nothing")
    func scriptEndingInsideATransaction() async throws {
        let connection = TestFixtures.makeConnection(database: "sales", type: .mssql)
        let driver = ScriptAnsweringDriver(
            connection: connection, transactionState: .idle, transactionStateAfterBatches: .inTransaction
        )
        let grammar = DatabaseType.mssql.lexicalGrammar
        let batches = QueryBatchPlanner.batches(
            in: "DROP TABLE dbo.people\nGO\nSELECT 1",
            model: QueryStatementModel.forDatabaseType(.mssql),
            grammar: grammar
        )
        let progress = ScriptBatchProgress()

        _ = try await ScriptBatchRun.run(batches, startLines: [1, 3], rowCap: 100, driver: driver, progress: progress)

        #expect(progress.startState == .idle)
        #expect(progress.endState == .inTransaction)
        let succeeded = try #require(
            progress.succeededStatements(of: batches, scope: Self.scope(of: connection), databaseType: .mssql)
        )
        var hazards = TableNameHazards()
        #expect(CommittedTableEdits.edits(in: succeeded, grammar: grammar, hazards: &hazards).isEmpty)
    }

    @Test("A script that never started reports nothing")
    func scriptThatNeverStarted() {
        let connection = TestFixtures.makeConnection(database: "sales", type: .mssql)
        let progress = ScriptBatchProgress()
        #expect(progress.succeededStatements(of: [], scope: Self.scope(of: connection), databaseType: .mssql) == nil)
    }

    private static func scope(of connection: DatabaseConnection) -> DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: "sales", schema: "dbo")
    }
}

struct BatchStatementOutcomeSucceededCountTests {
    @Test("A statement failure leaves the statements before it, and a batch failure drops the batch that answered")
    func succeededCount() {
        let completed = BatchStatementOutcome<Int>.completed(results: [1, 2, 3])
        #expect(completed.succeededCount == 3)
        #expect(completed.isCompleted)
        let statementFailure = BatchStatementOutcome<Int>.failed(
            results: [1, 2], failure: .statement(sql: "x"), errorDescription: ""
        )
        #expect(statementFailure.succeededCount == 2)
        #expect(!statementFailure.isCompleted)
        let batchFailure = BatchStatementOutcome<Int>.failed(results: [1, 2], failure: .batch(sql: "x"), errorDescription: "")
        #expect(batchFailure.succeededCount == 1)
        #expect(BatchStatementOutcome<Int>.cancelled(results: [1]).succeededCount == 1)
    }
}
