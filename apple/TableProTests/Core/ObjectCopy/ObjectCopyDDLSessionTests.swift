//
//  ObjectCopyDDLSessionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct StatementFailure: Error {}

private final class DDLRecordingDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private let failing: Set<String>

    init(failing: Set<String> = []) {
        self.failing = failing
    }

    var events: [String] { lock.withLock { log } }

    private func record(_ event: String) {
        lock.withLock { log.append(event) }
    }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        record("open \(purpose)")
        return PluginSessionScope(purpose: purpose, saved: [], applied: [])
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        record("close \(scope.purpose)")
    }

    func execute(query: String) async throws -> PluginQueryResult {
        record(query)
        if failing.contains(query) { throw StatementFailure() }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
}

private final class SourceTableDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private let opensScope: Bool
    private let failsListing: Bool

    init(opensScope: Bool = true, failsListing: Bool = false) {
        self.opensScope = opensScope
        self.failsListing = failsListing
    }

    var events: [String] { lock.withLock { log } }

    private func record(_ event: String) {
        lock.withLock { log.append(event) }
    }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        record("open \(purpose)")
        guard opensScope else { return nil }
        return PluginSessionScope(purpose: purpose, saved: [], applied: [])
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        record("close \(scope.purpose)")
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        record("fetchTables")
        if failsListing { throw StatementFailure() }
        return [
            PluginTableInfo(name: "dd", comment: nil, partitionCount: nil),
            PluginTableInfo(name: "unrelated", comment: nil, partitionCount: nil)
        ]
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        record("fetchColumns \(table)")
        return [PluginColumnInfo(name: "d", dataType: "TIMESTAMP", defaultValue: "'2024-01-01 07:00:00'")]
    }
}

@MainActor
private final class TargetOnlyProvider: ScopedMetadataProviding {
    private let driver: DatabaseDriver

    init(driver: DatabaseDriver) {
        self.driver = driver
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? { nil }
}

@MainActor
struct ObjectCopyDDLSessionTests {
    private let createTable = "CREATE TABLE `dd` (`d` DATE NOT NULL DEFAULT '0000-00-00')"
    private let createProcedure = "CREATE PROCEDURE `add_c`(d DATE) INSERT INTO `dd` VALUES (d)"
    private let createTrigger = "CREATE TRIGGER `stamp` BEFORE INSERT ON `dd` FOR EACH ROW SET NEW.d = NEW.d"
    private let saveMode = "SET @saved_sql_mode = @@sql_mode"
    private let setMode = "SET sql_mode = 'NO_ENGINE_SUBSTITUTION'"
    private let restoreMode = "SET sql_mode = @saved_sql_mode"

    private var creationScope: PluginStatementScope {
        PluginStatementScope(opening: [saveMode, setMode], closing: [restoreMode])
    }

    private func endpoint(_ type: DatabaseType, _ database: String) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: UUID(), database: database, schema: nil),
            connectionName: database,
            databaseType: type,
            safeModeLevel: .silent,
            color: .blue
        )
    }

    private func statement(_ sql: String, _ name: String) -> SyncStatement {
        SyncStatement(sql: sql, objectName: name, summary: "create")
    }

    private func tableStep() -> ObjectCopyTableStep {
        ObjectCopyTableStep(
            selection: ObjectCopySelection(kind: .table, name: "dd", schema: nil),
            dropStatements: [],
            sequenceStatements: [],
            createStatements: [statement(createTable, "dd")],
            truncateStatements: [],
            columns: [],
            primaryKeyColumns: [],
            sourceQuery: "SELECT `d` FROM `dd`",
            targetTable: "dd",
            targetSchema: nil,
            estimatedRows: nil,
            copiesData: false,
            copiesIdentityColumn: false,
            note: nil
        )
    }

    private func definitionStep(
        _ kind: CompareObjectKind,
        _ name: String,
        create sql: String,
        scope: PluginStatementScope?
    ) -> ObjectCopyDefinitionStep {
        ObjectCopyDefinitionStep(
            selection: ObjectCopySelection(kind: kind, name: name, schema: nil),
            dropStatements: [],
            createStatements: [statement(sql, name)],
            creationScope: scope
        )
    }

    private func plan(
        from sourceType: DatabaseType = .mysql,
        tables: [ObjectCopyTableStep] = [],
        definitions: [ObjectCopyDefinitionStep] = [],
        isStructureReadPinned: Bool = true
    ) -> ObjectCopyPlan {
        let selections = tables.map(\.selection) + definitions.map(\.selection)
        return ObjectCopyPlan(
            request: ObjectCopyRequest(
                source: endpoint(sourceType, "shop"),
                destination: .existing(endpoint(.mysql, "staging")),
                objects: selections,
                content: .structure,
                existingPolicy: .replace
            ),
            createsDatabase: false,
            tableSteps: tables,
            definitionSteps: definitions,
            isStructureReadPinned: isStructureReadPinned,
            keysInside: ObjectCopyKeysInside(created: true, rows: true)
        )
    }

    private func run(_ plan: ObjectCopyPlan, on driver: DDLRecordingDriver) async throws -> ObjectCopyRunResult {
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .mysql), pluginDriver: driver)
        let runner = ObjectCopyRunner(manager: TargetOnlyProvider(driver: adapter), gate: AlwaysAllowGate())
        return try await runner.run(plan, progress: ObjectCopyProgress(progress: Progress()))
    }

    // MARK: - Tables

    /// A strict MySQL 8 session refuses this `CREATE TABLE` with 1067 before any row is copied.
    @Test("A same-engine copy creates its tables under the target's write scope")
    func sameEngineTableDDLIsPinned() async throws {
        let driver = DDLRecordingDriver()

        let result = try await run(plan(tables: [tableStep()]), on: driver)

        #expect(result.failedCount == 0)
        #expect(driver.events == [
            "open relaxedForeignKeys", "open verbatimWrite", createTable, "close verbatimWrite", "close relaxedForeignKeys"
        ])
    }

    @Test("A failed CREATE TABLE still closes the write scope")
    func failedTableDDLClosesTheWriteScope() async throws {
        let driver = DDLRecordingDriver(failing: [createTable])

        let result = try await run(plan(tables: [tableStep()]), on: driver)

        #expect(result.failedCount == 1)
        #expect(driver.events == [
            "open relaxedForeignKeys", "open verbatimWrite", createTable, "close verbatimWrite", "close relaxedForeignKeys"
        ])
    }

    /// MariaDB renders a TIMESTAMP default in the session's zone, so DDL read as the session is
    /// would move by the offset if it were written under the pinned zone.
    @Test("Tables read as the session is are created as the session is")
    func unpinnedReadRunsDDLUnscoped() async throws {
        let driver = DDLRecordingDriver()

        _ = try await run(plan(tables: [tableStep()], isStructureReadPinned: false), on: driver)

        #expect(driver.events == ["open relaxedForeignKeys", createTable, "close relaxedForeignKeys"])
    }

    @Test("A copy between engines creates its tables under the session as it is")
    func crossEngineTableDDLIsNotPinned() async throws {
        let driver = DDLRecordingDriver()

        _ = try await run(plan(from: .postgresql, tables: [tableStep()]), on: driver)

        #expect(driver.events == ["open relaxedForeignKeys", createTable, "close relaxedForeignKeys"])
    }

    // MARK: - Reading the source tables

    @Test("The source tables are read inside the read scope and the read reports it pinned")
    func sourceTablesAreReadPinned() async throws {
        let source = SourceTableDriver()

        let read = try await ObjectCopyPlanner.pinnedTableReads(
            names: ["DD"], schema: nil, databaseType: .mariadb, using: source
        )

        #expect(read.isPinned)
        #expect(read.reads.map(\.table.name) == ["dd"])
        #expect(read.reads.first?.columns.first?.defaultValue == "'2024-01-01 07:00:00'")
        #expect(source.events.first == "open verbatimRead")
        #expect(source.events.last == "close verbatimRead")
        #expect(source.events.contains("fetchColumns dd"))
        #expect(!source.events.contains("fetchColumns unrelated"))
    }

    @Test("A source with no read scope is read as the session is and reports it")
    func sourceWithoutScopeReadsUnpinned() async throws {
        let source = SourceTableDriver(opensScope: false)

        let read = try await ObjectCopyPlanner.pinnedTableReads(
            names: ["dd"], schema: nil, databaseType: .mariadb, using: source
        )

        #expect(!read.isPinned)
        #expect(read.reads.map(\.table.name) == ["dd"])
        #expect(!source.events.contains { $0.hasPrefix("close") })
    }

    @Test("A failed source read still closes the read scope")
    func failedSourceReadClosesTheScope() async {
        let source = SourceTableDriver(failsListing: true)

        await #expect(throws: StatementFailure.self) {
            _ = try await ObjectCopyPlanner.pinnedTableReads(
                names: ["dd"], schema: nil, databaseType: .mariadb, using: source
            )
        }

        #expect(source.events == ["open verbatimRead", "fetchTables", "close verbatimRead"])
    }

    // MARK: - Routines and triggers

    @Test("A routine is created under its own settings, outside the write scope")
    func routineUsesItsCreationSettings() async throws {
        let driver = DDLRecordingDriver()
        let procedure = definitionStep(.procedure, "add_c", create: createProcedure, scope: creationScope)

        let result = try await run(plan(tables: [tableStep()], definitions: [procedure]), on: driver)

        #expect(result.failedCount == 0)
        #expect(driver.events == [
            "open relaxedForeignKeys", "open verbatimWrite", createTable, "close verbatimWrite", "close relaxedForeignKeys",
            saveMode, setMode, createProcedure, restoreMode
        ])
    }

    @Test("A routine that fails still gets the session's settings back")
    func failedRoutineRestoresSettings() async throws {
        let driver = DDLRecordingDriver(failing: [createProcedure])
        let procedure = definitionStep(.procedure, "add_c", create: createProcedure, scope: creationScope)

        let result = try await run(plan(definitions: [procedure]), on: driver)

        #expect(result.failedCount == 1)
        #expect(driver.events == [saveMode, setMode, createProcedure, restoreMode])
    }

    @Test("Settings that fail to apply leave the routine to be created as before")
    func unappliedSettingsStillCreateTheRoutine() async throws {
        let partly = DDLRecordingDriver(failing: [setMode])
        let procedure = definitionStep(.procedure, "add_c", create: createProcedure, scope: creationScope)

        let partlyApplied = try await run(plan(definitions: [procedure]), on: partly)

        #expect(partlyApplied.failedCount == 0)
        #expect(partly.events == [saveMode, setMode, createProcedure, restoreMode])

        let none = DDLRecordingDriver(failing: [saveMode])
        _ = try await run(plan(definitions: [procedure]), on: none)

        #expect(none.events == [saveMode, createProcedure])
    }

    @Test("A routine with no recorded settings runs its CREATE alone")
    func routineWithoutSettingsRunsAlone() async throws {
        let driver = DDLRecordingDriver()
        let procedure = definitionStep(.procedure, "add_c", create: createProcedure, scope: nil)

        _ = try await run(plan(definitions: [procedure]), on: driver)

        #expect(driver.events == [createProcedure])
    }

    @Test("A trigger installed after the rows gets its own settings")
    func triggerUsesItsCreationSettings() async throws {
        let driver = DDLRecordingDriver()
        let trigger = definitionStep(.trigger, "stamp", create: createTrigger, scope: creationScope)

        let result = try await run(plan(definitions: [trigger]), on: driver)

        #expect(result.failedCount == 0)
        #expect(driver.events == [saveMode, setMode, createTrigger, restoreMode])
    }

    // MARK: - The review

    @Test("The script under review shows the settings around the definition")
    func scriptShowsCreationSettings() {
        let procedure = definitionStep(.procedure, "add_c", create: createProcedure, scope: creationScope)
        let trigger = definitionStep(.trigger, "stamp", create: createTrigger, scope: creationScope)

        let reviewed = plan(definitions: [procedure, trigger])

        #expect(reviewed.creationStatements.map(\.sql) == [saveMode, setMode, createProcedure, restoreMode])
        #expect(reviewed.afterDataStatements.map(\.sql) == [saveMode, setMode, createTrigger, restoreMode])
    }
}
