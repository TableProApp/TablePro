import Foundation
import os
@testable import TablePro
import TableProPluginKit
import Testing

private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

struct ConnectionDeadlineTests {
    @Test("Connect timeout policy defaults and rejects out-of-range values")
    func connectPolicy() {
        #expect(ConnectionTimeoutPolicy.effectiveConnectTimeoutSeconds(configuredSeconds: nil) == 30)
        #expect(ConnectionTimeoutPolicy.effectiveConnectTimeoutSeconds(configuredSeconds: 1) == 1)
        #expect(ConnectionTimeoutPolicy.effectiveConnectTimeoutSeconds(configuredSeconds: 600) == 600)
        #expect(ConnectionTimeoutPolicy.effectiveConnectTimeoutSeconds(configuredSeconds: 0) == 30)
        #expect(ConnectionTimeoutPolicy.effectiveConnectTimeoutSeconds(configuredSeconds: 601) == 30)
    }

    @Test("Query timeout inherits, preserves zero, and rejects negative imported values")
    func queryPolicy() {
        #expect(ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(configuredSeconds: nil, globalSeconds: 45) == 45)
        #expect(ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(configuredSeconds: 0, globalSeconds: 45) == 0)
        #expect(ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(configuredSeconds: 12, globalSeconds: 45) == 12)
        #expect(DatabaseConnection.queryTimeoutSecondsRange.upperBound == 2_147_483)
        #expect(
            ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(
                configuredSeconds: 2_147_483,
                globalSeconds: 45
            ) == 2_147_483
        )
        #expect(
            ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(
                configuredSeconds: 2_147_484,
                globalSeconds: 45
            ) == 45
        )
        #expect(
            ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(
                configuredSeconds: nil,
                globalSeconds: 2_147_484
            ) == 2_147_483
        )
        #expect(ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(configuredSeconds: -1, globalSeconds: 45) == 45)
        #expect(ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(configuredSeconds: nil, globalSeconds: -1) == 0)
    }

    @Test("Only proven in-process file opens skip the host deadline")
    func hostDeadlineClassification() {
        let localSQLite = DatabaseConnection(name: "SQLite", type: .sqlite)
        var remoteSQLite = localSQLite
        remoteSQLite.additionalFields[RemoteSQLiteWire.backendFieldKey] = RemoteSQLiteWire.agentBackendValue

        let localLibSQL = DatabaseConnection(
            name: "libSQL file",
            type: .libsql,
            additionalFields: ["libsqlMode": "local", "libsqlFilePath": "/tmp/local.db"]
        )
        let remoteLibSQL = DatabaseConnection(
            name: "libSQL server",
            type: .libsql,
            additionalFields: ["libsqlMode": "remote"]
        )
        let localTurso = DatabaseConnection(
            name: "Turso file",
            type: .turso,
            additionalFields: ["libsqlMode": "local", "libsqlFilePath": "/tmp/local.db"]
        )
        let remoteTurso = DatabaseConnection(
            name: "Turso server",
            type: .turso,
            additionalFields: ["libsqlMode": "remote"]
        )

        #expect(!ConnectionTimeoutPolicy.requiresHostDeadline(for: localSQLite))
        #expect(ConnectionTimeoutPolicy.requiresHostDeadline(for: remoteSQLite))
        #expect(!ConnectionTimeoutPolicy.requiresHostDeadline(for: localLibSQL))
        #expect(ConnectionTimeoutPolicy.requiresHostDeadline(for: remoteLibSQL))
        #expect(!ConnectionTimeoutPolicy.requiresHostDeadline(for: localTurso))
        #expect(ConnectionTimeoutPolicy.requiresHostDeadline(for: remoteTurso))
        let pglite = DatabaseConnection(name: "PGlite", host: "pglite.example.com", type: .pglite)
        let localDuckDB = DatabaseConnection(
            name: "DuckDB",
            type: .duckdb,
            additionalFields: ["duckdbMode": "local", "duckdbFilePath": "/tmp/local.duckdb"]
        )
        let quack = DatabaseConnection(
            name: "Quack",
            host: "quack.example.com",
            type: .duckdb,
            additionalFields: ["duckdbMode": "remote"]
        )

        #expect(ConnectionTimeoutPolicy.requiresHostDeadline(for: pglite))
        #expect(ConnectionTimeoutPolicy.requiresHostDeadline(for: localDuckDB))
        #expect(ConnectionTimeoutPolicy.requiresHostDeadline(for: quack))
        #expect(ConnectionTimeoutPolicy.requiresHostDeadline(for: DatabaseConnection(name: "Beancount", type: .beancount)))
        #expect(ConnectionTimeoutPolicy.requiresHostDeadline(
            for: DatabaseConnection(name: "External", type: DatabaseType(rawValue: "FuturePlugin"))
        ))
    }

    @Test("Deadline exposes one monotonic budget in both units")
    func remainingBudget() {
        let start = ContinuousClock.now
        let deadline = ConnectionDeadline(configuredSeconds: 5, startedAt: start)
        let sampledAt = start.advanced(by: .milliseconds(3_750))

        #expect(deadline.instant == start.advanced(by: .seconds(5)))
        #expect(deadline.remainingDuration(at: sampledAt) == .milliseconds(1_250))
        #expect(deadline.remainingMilliseconds(at: sampledAt) == 1_250)
        #expect(deadline.remainingSeconds(at: sampledAt) == 2)
        #expect(!deadline.isExpired(at: sampledAt))
        #expect(deadline.isExpired(at: deadline.instant))
    }

    @Test("Timeout error keeps the endpoint that exhausted the budget")
    func attributedError() {
        let deadline = ConnectionDeadline(configuredSeconds: 9, startedAt: .now)
        let error = deadline.timeoutError(for: .tunnel("bastion.example.com"))

        #expect(error.endpoint == .tunnel("bastion.example.com"))
        #expect(error.configuredSeconds == 9)
        #expect(error.localizedDescription.contains("bastion.example.com"))
    }

    @Test("AWS credential requests keep the full remaining connection budget")
    @MainActor
    func credentialRequestBudget() {
        let startedAt = ContinuousClock.now
        let deadline = ConnectionDeadline(configuredSeconds: 600, startedAt: startedAt)

        #expect(
            ConnectionCredentialResolver.credentialRequestTimeout(
                for: deadline,
                at: startedAt.advanced(by: .seconds(50))
            ) == 550
        )
    }

    @Test("Driver configuration receives the same remaining budget in both units")
    @MainActor
    func driverConfigurationFields() {
        let sampledAt = ContinuousClock.now
        let deadline = ConnectionDeadline(
            configuredSeconds: 30,
            instant: sampledAt.advanced(by: .milliseconds(2_500))
        )

        let fields = DatabaseDriverFactory.timeoutAdditionalFields(
            deadline: deadline,
            effectiveQueryTimeoutSeconds: 0,
            at: sampledAt
        )

        #expect(fields["connectTimeoutSeconds"] == "3")
        #expect(fields["connectTimeoutMilliseconds"] == "2500")
        #expect(fields["queryTimeoutSeconds"] == "0")

        let kafkaFields = DatabaseDriverFactory.timeoutAdditionalFields(
            deadline: deadline,
            effectiveQueryTimeoutSeconds: 0,
            databaseType: .kafka,
            at: sampledAt
        )
        #expect(kafkaFields["kafkaConnectTimeout"] == "3")

        let localFields = DatabaseDriverFactory.timeoutAdditionalFields(
            deadline: deadline,
            effectiveQueryTimeoutSeconds: 0,
            usesRemainingBudget: false,
            at: deadline.instant
        )
        #expect(localFields["connectTimeoutSeconds"] == "30")
        #expect(localFields["connectTimeoutMilliseconds"] == "30000")
    }

    @Test("Effective transport fields reach the driver without restoring rejected source fields")
    @MainActor
    func effectiveTransportFields() {
        let fields = DatabaseDriverFactory.mergeEffectiveAdditionalFields(
            prepared: [
                "connectionId": "id",
                "secureValue": "secret",
                "removedByTunnel": "old"
            ],
            source: [
                "rejectedByGate": "unsafe",
                "removedByTunnel": "old"
            ],
            effective: [
                "rejectedByGate": "unsafe",
                RemoteSQLiteWire.backendFieldKey: RemoteSQLiteWire.agentBackendValue,
                RemoteSQLiteWire.tokenFieldKey: "token"
            ]
        )

        #expect(fields["connectionId"] == "id")
        #expect(fields["secureValue"] == "secret")
        #expect(fields["rejectedByGate"] == nil)
        #expect(fields["removedByTunnel"] == nil)
        #expect(fields[RemoteSQLiteWire.backendFieldKey] == RemoteSQLiteWire.agentBackendValue)
        #expect(fields[RemoteSQLiteWire.tokenFieldKey] == "token")
    }

    @Test("Credential resolution cannot outlive the shared connection deadline")
    @MainActor
    func credentialResolutionDeadline() async throws {
        let resolver = DeadlineBlockingCredentialResolver()
        let resolution = Task {
            let deadline = ConnectionDeadline(
                configuredSeconds: 1,
                instant: ContinuousClock.now.advanced(by: .milliseconds(500))
            )
            try await DatabaseDriverFactory.resolvePasswordWithinDeadline(
                deadline: deadline,
                endpoint: .database("db.example.com")
            ) {
                await resolver.resolve()
            }
        }
        defer {
            resolution.cancel()
            resolver.finish()
        }
        try #require(await waitUntil { resolver.isResolving })
        let startedAt = ContinuousClock.now

        let result = try #require(await BoundedCall.result(within: .seconds(2)) {
            await resolution.result
        })
        guard case .failure(let error) = result else {
            Issue.record("Expected credential resolution to reach the connection deadline")
            return
        }
        #expect((error as? ConnectionTimeoutError) == ConnectionTimeoutError(
            endpoint: .database("db.example.com"),
            configuredSeconds: 1
        ))

        #expect(ContinuousClock.now - startedAt < .seconds(1))
        #expect(resolver.isResolving)
        resolver.finish()
    }
}

struct PluginDriverAdapterConnectDeadlineTests {
    @Test("A local SQLite open is not ended by the host deadline")
    func localSQLiteOpen() async throws {
        let plugin = DeadlineBlockingPluginDriver()
        let deadline = ConnectionDeadline(
            configuredSeconds: 1,
            instant: ContinuousClock.now.advanced(by: .milliseconds(80))
        )
        let adapter = PluginDriverAdapter(
            connection: DatabaseConnection(name: "Local", type: .sqlite),
            pluginDriver: plugin,
            deadline: deadline,
            timeoutEndpoint: .database("Local")
        )
        let connect = Task { try await adapter.connect() }
        defer {
            connect.cancel()
            plugin.finishConnect()
        }

        try #require(await waitUntil { plugin.isConnecting })
        try await Task.sleep(for: .milliseconds(120))
        #expect(plugin.isConnecting)
        #expect(plugin.disconnectCallCount == 0)

        plugin.finishConnect()
        let result = try #require(await BoundedCall.result(within: .seconds(2)) {
            await connect.result
        })
        try result.get()
        #expect(adapter.status == .connected)
        #expect(plugin.disconnectCallCount == 0)

        adapter.disconnect()
        #expect(plugin.disconnectCallCount == 1)
    }

    @Test("A cancellation-deaf connect returns at its deadline and cleans up only after it returns")
    func cancellationDeafConnect() async throws {
        let plugin = DeadlineBlockingPluginDriver()
        let adapterBox = OSAllocatedUnfairLock(initialState: Optional<PluginDriverAdapter>.none)
        let stages = OSAllocatedUnfairLock(initialState: [ConnectionStage]())
        let connect = Task {
            let deadline = ConnectionDeadline(
                configuredSeconds: 1,
                instant: ContinuousClock.now.advanced(by: .milliseconds(500))
            )
            let adapter = PluginDriverAdapter(
                connection: DatabaseConnection(name: "Test", host: "db.example.com", type: .mysql),
                pluginDriver: plugin,
                deadline: deadline,
                timeoutEndpoint: .database("db.example.com")
            )
            adapterBox.withLock { $0 = adapter }
            try await adapter.connectReporting { stage in
                stages.withLock { $0.append(stage) }
            }
        }
        defer {
            connect.cancel()
            plugin.finishConnect()
        }
        try #require(await waitUntil { plugin.isConnecting })
        let adapter = try #require(adapterBox.withLock { $0 })
        let startedAt = ContinuousClock.now

        let result = try #require(await BoundedCall.result(within: .seconds(2)) {
            await connect.result
        })
        guard case .failure(let error) = result else {
            Issue.record("Expected the plugin connect to reach the connection deadline")
            return
        }
        #expect((error as? ConnectionTimeoutError) == ConnectionTimeoutError(
            endpoint: .database("db.example.com"),
            configuredSeconds: 1
        ))

        #expect(ContinuousClock.now - startedAt < .seconds(1))
        #expect(plugin.isConnecting)
        #expect(plugin.disconnectCallCount == 0)
        #expect(!plugin.disconnectedWhileConnecting)

        let repeatedConnect = Task { try await adapter.connect() }
        defer { repeatedConnect.cancel() }
        let repeatedResult = try #require(await BoundedCall.result(within: .seconds(2)) {
            await repeatedConnect.result
        })
        guard case .failure(let repeatedError) = repeatedResult else {
            Issue.record("Expected a second connect to fail while late cleanup was pending")
            return
        }
        #expect(repeatedError is DatabaseError)

        plugin.finishConnect()
        try #require(await waitUntil { plugin.disconnectCallCount == 1 })

        #expect(!plugin.disconnectedWhileConnecting)
        #expect(stages.withLock { $0 } == [.authenticating])
    }
}

private final class DeadlineBlockingPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var isConnecting = false
        var disconnectCallCount = 0
        var disconnectedWhileConnecting = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isConnecting: Bool {
        state.withLock { $0.isConnecting }
    }

    var disconnectCallCount: Int {
        state.withLock { $0.disconnectCallCount }
    }

    var disconnectedWhileConnecting: Bool {
        state.withLock { $0.disconnectedWhileConnecting }
    }

    func connect() async throws {
        try await connect(reportingStage: { _ in })
    }

    func connect(reportingStage report: @escaping ConnectionStageReporter) async throws {
        state.withLock { $0.isConnecting = true }
        report(.authenticating)
        await withCheckedContinuation { continuation in
            state.withLock { $0.continuation = continuation }
        }
        report(.custom("late stage"))
        state.withLock { $0.isConnecting = false }
    }

    func finishConnect() {
        let continuation = state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func disconnect() {
        state.withLock { state in
            state.disconnectCallCount += 1
            state.disconnectedWhileConnecting = state.disconnectedWhileConnecting || state.isConnecting
        }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

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

private final class DeadlineBlockingCredentialResolver: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var isResolving = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isResolving: Bool {
        state.withLock { $0.isResolving }
    }

    func resolve() async -> String {
        state.withLock { $0.isResolving = true }
        await withCheckedContinuation { continuation in
            state.withLock { $0.continuation = continuation }
        }
        state.withLock { $0.isResolving = false }
        return "secret"
    }

    func finish() {
        let continuation = state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}
