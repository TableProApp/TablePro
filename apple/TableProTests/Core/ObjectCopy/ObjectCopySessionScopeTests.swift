//
//  ObjectCopySessionScopeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct WriteFailure: Error {}

private final class ScopedCopyDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var cancelledAtClose: [Bool] = []
    private let streamed: [[PluginCellValue]]
    private let opensScope: Bool
    private let failsWrites: Bool
    private let cancelsOnWrite: Bool

    init(
        streamed: [[PluginCellValue]] = [],
        opensScope: Bool = true,
        failsWrites: Bool = false,
        cancelsOnWrite: Bool = false
    ) {
        self.streamed = streamed
        self.opensScope = opensScope
        self.failsWrites = failsWrites
        self.cancelsOnWrite = cancelsOnWrite
    }

    var events: [String] { lock.withLock { log } }
    var closesSawCancellation: [Bool] { lock.withLock { cancelledAtClose } }

    var supportsTransactions: Bool { true }

    private func record(_ event: String) {
        lock.withLock { log.append(event) }
    }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        record("open \(purpose)")
        guard opensScope else { return nil }
        return PluginSessionScope(
            purpose: purpose, saved: [], applied: [PluginSessionSetting(name: "sql_mode", value: "")])
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        let isCancelled = Task.isCancelled
        lock.withLock {
            log.append("close \(scope.purpose)")
            cancelledAtClose.append(isCancelled)
        }
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { .idle }

    func beginTransaction() async throws { record("begin") }
    func commitTransaction() async throws { record("commit") }
    func rollbackTransaction() async throws { record("rollback") }

    func quoteIdentifier(_ name: String) -> String { "`\(name)`" }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        record("stream")
        let rows = streamed
        return AsyncThrowingStream { continuation in
            continuation.yield(.header(PluginStreamHeader(columns: ["id", "name"], columnTypeNames: [])))
            continuation.yield(.rows(rows))
            continuation.finish()
        }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        record("execute")
        if failsWrites { throw WriteFailure() }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 2, executionTime: 0)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        record("insert")
        if cancelsOnWrite {
            withUnsafeCurrentTask { task in
                guard let task else { return }
                task.cancel()
            }
        }
        if failsWrites { throw WriteFailure() }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
}

@MainActor
private final class TwoConnectionProvider: ScopedMetadataProviding {
    private let drivers: [UUID: DatabaseDriver]

    init(drivers: [UUID: DatabaseDriver]) {
        self.drivers = drivers
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        guard let driver = drivers[scope.connectionId] else {
            throw ObjectCopyError.refused("No driver for \(scope.connectionId)")
        }
        return try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? { nil }
}

struct ObjectCopySessionScopeTests {
    private func step(serverSideInsert: SyncStatement? = nil, hasRowFilter: Bool = false) -> ObjectCopyTableStep {
        ObjectCopyTableStep(
            selection: ObjectCopySelection(kind: .table, name: "orders", schema: nil),
            dropStatements: [],
            sequenceStatements: [],
            createStatements: [],
            truncateStatements: [],
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            sourceQuery: "SELECT `id`, `name` FROM `orders`",
            targetTable: "orders",
            targetSchema: nil,
            estimatedRows: nil,
            copiesData: true,
            copiesIdentityColumn: false,
            serverSideInsert: serverSideInsert,
            hasRowFilter: hasRowFilter,
            note: nil
        )
    }

    private let zeroDates: [[PluginCellValue]] = [
        [.text("0"), .text("0000-00-00")],
        [.text("1"), .text("2020-00-15")]
    ]

    private let serverSideInsert = SyncStatement(
        sql: "INSERT INTO `orders` (`id`, `name`) SELECT `id`, `name` FROM `shop`.`orders`",
        objectName: "orders",
        summary: "server side"
    )

    // MARK: - Streamed rows

    @Test("A same-engine copy reads under the source's scope and writes under the target's", arguments: [
        DatabaseType.mysql, .mariadb
    ])
    func sameEngineCopyPinsBothSessions(sourceType: DatabaseType) async throws {
        let source = ScopedCopyDriver(streamed: zeroDates)
        let target = ScopedCopyDriver()

        let outcome = try await ObjectCopyRowCopier(
            step: step(), sourceDatabaseType: sourceType, targetDatabaseType: .mysql
        ).copy(from: source, to: target) { _ in }

        #expect(outcome.inserted == 2)
        #expect(source.events == ["open verbatimRead", "stream", "close verbatimRead"])
        #expect(target.events == ["open verbatimWrite", "insert", "close verbatimWrite"])
    }

    @Test("A write that fails still closes both scopes")
    func failedWriteClosesBothScopes() async {
        let source = ScopedCopyDriver(streamed: zeroDates)
        let target = ScopedCopyDriver(failsWrites: true)

        await #expect(throws: WriteFailure.self) {
            _ = try await ObjectCopyRowCopier(
                step: step(), sourceDatabaseType: .mysql, targetDatabaseType: .mysql
            ).copy(from: source, to: target) { _ in }
        }

        #expect(source.events == ["open verbatimRead", "stream", "close verbatimRead"])
        #expect(target.events == ["open verbatimWrite", "insert", "close verbatimWrite"])
    }

    @Test("A stopped copy closes both scopes outside the cancellation")
    func stoppedCopyClosesBothScopes() async throws {
        let source = ScopedCopyDriver(streamed: zeroDates)
        let target = ScopedCopyDriver(cancelsOnWrite: true)
        let copier = ObjectCopyRowCopier(step: step(), sourceDatabaseType: .mysql, targetDatabaseType: .mysql)

        let outcome = try await Task {
            try await copier.copy(from: source, to: target) { _ in }
        }.value

        #expect(outcome.cancelled)
        #expect(source.events.last == "close verbatimRead")
        #expect(target.events.last == "close verbatimWrite")
        #expect(source.closesSawCancellation == [false])
        #expect(target.closesSawCancellation == [false])
    }

    @Test("A copy between engines opens no scope")
    func crossEngineCopyOpensNoScope() async throws {
        let source = ScopedCopyDriver(streamed: zeroDates)
        let target = ScopedCopyDriver()

        let outcome = try await ObjectCopyRowCopier(
            step: step(), sourceDatabaseType: .postgresql, targetDatabaseType: .mysql
        ).copy(from: source, to: target) { _ in }

        #expect(outcome.inserted == 2)
        #expect(source.events == ["stream"])
        #expect(target.events == ["insert"])
    }

    @Test("A target with no scope closes the source's and still copies every row")
    func targetWithoutScopeStillCopies() async throws {
        let source = ScopedCopyDriver(streamed: zeroDates)
        let target = ScopedCopyDriver(opensScope: false)

        let outcome = try await ObjectCopyRowCopier(
            step: step(), sourceDatabaseType: .mysql, targetDatabaseType: .mysql
        ).copy(from: source, to: target) { _ in }

        #expect(outcome.inserted == 2)
        #expect(source.events == ["open verbatimRead", "close verbatimRead", "stream"])
        #expect(target.events == ["open verbatimWrite", "insert"])
    }

    // MARK: - Row filters

    /// The `WHERE` is the user's SQL for their own session, so pinned settings could select other rows.
    @Test("A copy narrowed by a row filter reads and writes on the sessions as they are")
    func filteredCopyOpensNoScope() async throws {
        let source = ScopedCopyDriver(streamed: zeroDates)
        let target = ScopedCopyDriver()
        let filtered = PluginExportRowScope(filter: "created_at >= '2024-06-01 00:00:00'")

        let outcome = try await ObjectCopyRowCopier(
            step: step(hasRowFilter: VerbatimTransferScopes.filtersRows(filtered)),
            sourceDatabaseType: .mysql,
            targetDatabaseType: .mysql
        ).copy(from: source, to: target) { _ in }

        #expect(outcome.inserted == 2)
        #expect(source.events == ["stream"])
        #expect(target.events == ["insert"])
    }

    @Test("A filtered INSERT ... SELECT runs on the session as it is")
    func filteredServerSideInsertOpensNoScope() async throws {
        let target = ScopedCopyDriver()

        _ = try await ObjectCopyRowCopier(
            step: step(serverSideInsert: serverSideInsert, hasRowFilter: true),
            sourceDatabaseType: .mysql,
            targetDatabaseType: .mysql
        ).copy(from: ScopedCopyDriver(), to: target) { _ in }

        #expect(target.events == ["execute"])
    }

    @Test("A row limit or a column list alone keeps the scopes", arguments: [
        PluginExportRowScope(rowLimit: 10), PluginExportRowScope(columns: ["id"])
    ])
    func limitOnlyCopyKeepsScopes(rowScope: PluginExportRowScope) async throws {
        let source = ScopedCopyDriver(streamed: zeroDates)
        let target = ScopedCopyDriver()

        _ = try await ObjectCopyRowCopier(
            step: step(hasRowFilter: VerbatimTransferScopes.filtersRows(rowScope)),
            sourceDatabaseType: .mysql,
            targetDatabaseType: .mysql
        ).copy(from: source, to: target) { _ in }

        #expect(source.events == ["open verbatimRead", "stream", "close verbatimRead"])
        #expect(target.events == ["open verbatimWrite", "insert", "close verbatimWrite"])
    }

    // MARK: - Server side

    @Test("INSERT ... SELECT opens only the write scope, on its one connection")
    func serverSideInsertOpensOnlyTheWriteScope() async throws {
        let source = ScopedCopyDriver()
        let target = ScopedCopyDriver()

        let outcome = try await ObjectCopyRowCopier(
            step: step(serverSideInsert: serverSideInsert), sourceDatabaseType: .mysql, targetDatabaseType: .mysql
        ).copy(from: source, to: target) { _ in }

        #expect(outcome.inserted == 2)
        #expect(source.events.isEmpty)
        #expect(target.events == ["open verbatimWrite", "execute", "close verbatimWrite"])
    }

    @Test("A failed INSERT ... SELECT still closes its write scope")
    func failedServerSideInsertClosesTheWriteScope() async {
        let target = ScopedCopyDriver(failsWrites: true)

        await #expect(throws: WriteFailure.self) {
            _ = try await ObjectCopyRowCopier(
                step: step(serverSideInsert: serverSideInsert), sourceDatabaseType: .mysql, targetDatabaseType: .mysql
            ).copy(from: ScopedCopyDriver(), to: target) { _ in }
        }

        #expect(target.events == ["open verbatimWrite", "execute", "close verbatimWrite"])
    }

    // MARK: - Through the runner

    @MainActor
    private func runCopy(
        from sourceType: DatabaseType,
        source: ScopedCopyDriver,
        target: ScopedCopyDriver
    ) async throws -> ObjectCopyRunResult {
        let sourceScope = DatabaseScope(connectionId: UUID(), database: "shop", schema: nil)
        let targetScope = DatabaseScope(connectionId: UUID(), database: "staging", schema: nil)
        let sourceEndpoint = DatabaseEndpoint(
            scope: sourceScope, connectionName: "source", databaseType: sourceType, safeModeLevel: .silent, color: .blue
        )
        let targetEndpoint = DatabaseEndpoint(
            scope: targetScope, connectionName: "target", databaseType: .mysql, safeModeLevel: .silent, color: .blue
        )
        let selection = ObjectCopySelection(kind: .table, name: "orders", schema: nil)
        let plan = ObjectCopyPlan(
            request: ObjectCopyRequest(
                source: sourceEndpoint,
                destination: .existing(targetEndpoint),
                objects: [selection],
                content: .data,
                existingPolicy: .appendData
            ),
            createsDatabase: false,
            tableSteps: [step()],
            definitionSteps: [],
            keysInside: ObjectCopyKeysInside(created: true, rows: true)
        )
        let provider = TwoConnectionProvider(drivers: [
            sourceScope.connectionId: PluginDriverAdapter(
                connection: TestFixtures.makeConnection(type: sourceType), pluginDriver: source
            ),
            targetScope.connectionId: PluginDriverAdapter(
                connection: TestFixtures.makeConnection(type: .mysql), pluginDriver: target
            )
        ])
        let runner = ObjectCopyRunner(manager: provider, gate: AlwaysAllowGate())
        return try await runner.run(plan, progress: ObjectCopyProgress(progress: Progress()))
    }

    /// The scopes sit inside the table's transaction: a `SET` commits nothing on MySQL, and the
    /// transaction logic stays as it was.
    @MainActor @Test("The runner pins a same-engine copy inside the table's transaction")
    func runnerPinsSameEngineCopy() async throws {
        let source = ScopedCopyDriver(streamed: zeroDates)
        let target = ScopedCopyDriver()

        let result = try await runCopy(from: .mysql, source: source, target: target)

        #expect(result.rowsCopied == 2)
        #expect(source.events == ["open verbatimRead", "stream", "close verbatimRead"])
        #expect(target.events == [
            "begin", "open relaxedForeignKeys", "open verbatimWrite", "insert", "close verbatimWrite",
            "close relaxedForeignKeys", "commit"
        ])
    }

    @MainActor @Test("The runner opens no scope for a copy between engines")
    func runnerLeavesCrossEngineCopyUnscoped() async throws {
        let source = ScopedCopyDriver(streamed: zeroDates)
        let target = ScopedCopyDriver()

        let result = try await runCopy(from: .postgresql, source: source, target: target)

        #expect(result.rowsCopied == 2)
        #expect(source.events == ["stream"])
        #expect(target.events == ["begin", "open relaxedForeignKeys", "insert", "close relaxedForeignKeys", "commit"])
    }
}
