//
//  RedisKeyTreeViewModelLoadTests.swift
//  TableProTests
//
//  The key tree used to catch every load failure, log it and clear itself, so a refused `SCAN` or a
//  `MULTI` block left open on the session read as a database with no keys. It also ran each load as
//  an unowned task, so a load for a database the user had already left could land over the one they
//  had moved to.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private actor KeyTreeLatch {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private enum KeyTreeReply: Sendable {
    case keys([String])
    case failure(any Error)
}

private struct UnscriptedDatabase: Error {}

/// The statements the stub driver was asked to run. The driver runs off the main actor, so the log
/// is locked rather than isolated.
private final class ExecutedQueryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []

    var all: [String] {
        lock.withLock { queries }
    }

    func record(_ query: String) {
        lock.withLock { queries.append(query) }
    }
}

/// Answers each database with whatever the test scripted for it at the moment the read runs, and can
/// hold a database's read until the test releases it, the way a driver blocked on the wire holds one.
@MainActor
private final class ScriptedKeyTreeProvider: ScopedMetadataProviding {
    private struct Hold {
        let reached: KeyTreeLatch
        let release: KeyTreeLatch
    }

    private let connection: DatabaseConnection
    private let log = ExecutedQueryLog()
    private var replies: [String: KeyTreeReply] = [:]
    private var holds: [String: Hold] = [:]
    private(set) var requestedDatabases: [String] = []

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    var executedQueries: [String] {
        log.all
    }

    func answer(_ database: String, with reply: KeyTreeReply) {
        replies[database] = reply
    }

    /// The next read of `database` waits for `release`, after opening `reached`.
    func hold(_ database: String) -> (reached: KeyTreeLatch, release: KeyTreeLatch) {
        let hold = Hold(reached: KeyTreeLatch(), release: KeyTreeLatch())
        holds[database] = hold
        return (hold.reached, hold.release)
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        requestedDatabases.append(scope.database)
        if let hold = holds.removeValue(forKey: scope.database) {
            await hold.reached.open()
            await hold.release.wait()
        }
        switch replies[scope.database] {
        case .keys(let keys):
            let driver = KeyTreePluginDriver(keys: keys, log: log)
            return try await body(PluginDriverAdapter(connection: connection, pluginDriver: driver))
        case .failure(let error):
            throw error
        case nil:
            throw UnscriptedDatabase()
        }
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? {
        nil
    }
}

@Suite("Redis key tree load state", .serialized)
@MainActor
struct RedisKeyTreeViewModelLoadTests {
    private let connection = TestFixtures.makeConnection(database: "0", type: .redis)

    private func makeViewModel() -> (RedisKeyTreeViewModel, ScriptedKeyTreeProvider) {
        let provider = ScriptedKeyTreeProvider(connection: connection)
        return (RedisKeyTreeViewModel(metadataProvider: provider), provider)
    }

    private func load(_ viewModel: RedisKeyTreeViewModel, databaseIndex: Int) async {
        await viewModel.loadKeys(connectionId: connection.id, databaseIndex: databaseIndex, separator: ":").value
    }

    @Test("A load commits the keys the server listed, for the database it asked about")
    func loadCommitsTheKeys() async throws {
        let (viewModel, provider) = makeViewModel()
        provider.answer("3", with: .keys(["user:1", "user:2", "counter"]))

        await load(viewModel, databaseIndex: 3)

        let content = try #require(viewModel.state.value)
        #expect(content.database == "3")
        #expect(content.keys.map(\.key) == ["user:1", "user:2", "counter"])
        #expect(content.rootNodes.count == 2)
        #expect(!content.isTruncated)
        #expect(provider.requestedDatabases == ["3"])
        #expect(provider.executedQueries == ["KEYTREE DB 3 LIMIT \(RedisKeyTreeViewModel.maxKeys)"])
    }

    /// Each of these used to become an empty tree, which the section drew as "No items".
    @Test("A refused scan, an open MULTI block and a lost session each commit their failure")
    func failuresCommitTheirMessage() async {
        let failures: [any Error] = [
            RedisPluginError(code: 0, message: "NOPERM User noscan has no permissions to run the 'scan' command"),
            RedisQueuedCommand(command: "SCAN"),
            DatabaseError.notConnected
        ]
        for error in failures {
            let (viewModel, provider) = makeViewModel()
            provider.answer("0", with: .failure(error))

            await load(viewModel, databaseIndex: 0)

            #expect(viewModel.state.erased == .failed(error.localizedDescription), "\(error)")
        }
    }

    @Test("Moving to another database shows the loading row at once")
    func movingShowsTheLoadingRow() async {
        let (viewModel, provider) = makeViewModel()
        provider.answer("0", with: .keys(["a"]))
        provider.answer("2", with: .keys(["b"]))
        await load(viewModel, databaseIndex: 0)

        let move = viewModel.loadKeys(connectionId: connection.id, databaseIndex: 2, separator: ":")
        #expect(viewModel.state.erased == .loading)
        await move.value

        #expect(viewModel.state.value?.database == "2")
    }

    /// A driver blocked on the wire finishes after the user has moved on, and cancelling its task
    /// cannot stop it. Whatever it comes back with belongs to a database nobody is looking at.
    @Test("A load superseded by another database commits nothing, whatever it returns")
    func supersededLoadCommitsNothing() async {
        let outcomes: [KeyTreeReply] = [
            .keys(["stale:1"]),
            .failure(RedisPluginError(code: 0, message: "ERR stale")),
            .failure(CancellationError())
        ]
        for outcome in outcomes {
            let (viewModel, provider) = makeViewModel()
            let (reached, release) = provider.hold("1")
            provider.answer("2", with: .keys(["fresh:1"]))

            let stale = viewModel.loadKeys(connectionId: connection.id, databaseIndex: 1, separator: ":")
            await reached.wait()
            await load(viewModel, databaseIndex: 2)
            #expect(viewModel.state.value?.database == "2")

            provider.answer("1", with: outcome)
            await release.open()
            await stale.value

            #expect(viewModel.state.value?.database == "2", "\(outcome)")
            #expect(viewModel.state.value?.keys.map(\.key) == ["fresh:1"], "\(outcome)")
        }
    }

    /// A drained driver gate cancels the read it was holding. A spinner left behind would have
    /// nothing coming to replace it.
    @Test("A cancelled load on another database settles to nothing rather than a spinner")
    func cancelledMoveSettlesToIdle() async {
        let (viewModel, provider) = makeViewModel()
        provider.answer("0", with: .keys(["a"]))
        provider.answer("1", with: .failure(CancellationError()))
        await load(viewModel, databaseIndex: 0)

        await load(viewModel, databaseIndex: 1)

        #expect(viewModel.state.erased == .idle)
    }

    @Test("A cancelled refresh keeps the rows it was refreshing")
    func cancelledRefreshKeepsTheRows() async {
        let (viewModel, provider) = makeViewModel()
        provider.answer("0", with: .keys(["a"]))
        await load(viewModel, databaseIndex: 0)

        provider.answer("0", with: .failure(CancellationError()))
        await viewModel.reload()?.value

        #expect(viewModel.state.value?.keys.map(\.key) == ["a"])
    }

    /// A refresh never clears the cache it is refreshing: the rows stay while it runs and survive
    /// a refresh that fails.
    @Test("Refresh re-reads the same database and keeps its rows while it runs and when it fails")
    func refreshKeepsItsRows() async throws {
        let (viewModel, provider) = makeViewModel()
        provider.answer("0", with: .keys(["a"]))
        await load(viewModel, databaseIndex: 0)

        provider.answer("0", with: .failure(RedisPluginError(code: 0, message: "ERR refused")))
        let refresh = try #require(viewModel.reload())
        #expect(viewModel.state.value?.database == "0")
        await refresh.value

        #expect(viewModel.state.value?.keys.map(\.key) == ["a"])
        #expect(provider.requestedDatabases == ["0", "0"])
    }

    /// A typed `SELECT` moves the session, and a refresh that named no database listed wherever it
    /// had moved.
    @Test("Refresh names the database it lists, the same one each time")
    func refreshNamesItsDatabase() async throws {
        let (viewModel, provider) = makeViewModel()
        provider.answer("0", with: .keys(["zero:a"]))
        await load(viewModel, databaseIndex: 0)

        try await #require(viewModel.reload()).value

        let listing = "KEYTREE DB 0 LIMIT \(RedisKeyTreeViewModel.maxKeys)"
        #expect(provider.executedQueries == [listing, listing])
        #expect(viewModel.state.value?.database == "0")
    }

    @Test("The shown database is the one whose keys are on screen, and none while none are")
    func shownDatabaseIndexFollowsTheKeysOnScreen() async throws {
        let (viewModel, provider) = makeViewModel()
        #expect(viewModel.shownDatabaseIndex == nil)

        provider.answer("4", with: .keys(["a"]))
        await load(viewModel, databaseIndex: 4)
        #expect(viewModel.shownDatabaseIndex == 4)

        let (refreshReached, refreshRelease) = provider.hold("4")
        let refresh = try #require(viewModel.reload())
        await refreshReached.wait()
        #expect(viewModel.shownDatabaseIndex == 4)
        await refreshRelease.open()
        await refresh.value

        let (moveReached, moveRelease) = provider.hold("6")
        provider.answer("6", with: .failure(RedisPluginError(code: 0, message: "ERR refused")))
        let move = viewModel.loadKeys(connectionId: connection.id, databaseIndex: 6, separator: ":")
        await moveReached.wait()
        #expect(viewModel.shownDatabaseIndex == nil)
        await moveRelease.open()
        await move.value

        #expect(viewModel.shownDatabaseIndex == nil)
    }

    @Test("Refresh after a failed load retries it and shows the keys it gets")
    func refreshRecoversAFailedLoad() async throws {
        let (viewModel, provider) = makeViewModel()
        provider.answer("0", with: .failure(RedisQueuedCommand(command: "SCAN")))
        await load(viewModel, databaseIndex: 0)
        #expect(viewModel.state.value == nil)

        provider.answer("0", with: .keys(["a", "b"]))
        let refresh = try #require(viewModel.reload())
        #expect(viewModel.state.erased == .loading)
        await refresh.value

        #expect(viewModel.state.value?.keys.map(\.key) == ["a", "b"])
    }

    @Test("Refresh before anything was loaded has nothing to reload")
    func refreshBeforeAnyLoadDoesNothing() {
        let (viewModel, provider) = makeViewModel()

        #expect(viewModel.reload() == nil)
        #expect(viewModel.state.erased == .idle)
        #expect(provider.requestedDatabases.isEmpty)
    }
}

private final class KeyTreePluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let keys: [String]
    private let log: ExecutedQueryLog

    init(keys: [String], log: ExecutedQueryLog) {
        self.keys = keys
        self.log = log
    }

    func execute(query: String) async throws -> PluginQueryResult {
        log.record(query)
        return PluginQueryResult(
            columns: ["Key", "Type"],
            columnTypeNames: ["TEXT", "TEXT"],
            rows: keys.map { [.text($0), .text("string")] },
            rowsAffected: 0,
            executionTime: 0
        )
    }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
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
