//
//  FakeMSSQLPlugin.swift
//  TableProTests
//
//  Minimal MSSQL driver stub registered with PluginManager so tests that
//  resolve the SQL Server plugin (queryBuildingDriver, sqlDialect lookups)
//  succeed without bundling the real MSSQLDriverPlugin.
//

import Foundation
import os
@testable import TablePro
import TableProPluginKit

actor FakeMSSQLConnectHold {
    private var reachedConnect = false
    private var released = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReached() async {
        guard !reachedConnect else { return }
        await withCheckedContinuation { reachedWaiters.append($0) }
    }

    func waitForRelease() async {
        reachedConnect = true
        let waitingForReach = reachedWaiters
        reachedWaiters = []
        for waiter in waitingForReach {
            waiter.resume()
        }

        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        guard !released else { return }
        released = true
        let waitingForRelease = releaseWaiters
        releaseWaiters = []
        for waiter in waitingForRelease {
            waiter.resume()
        }
    }
}

final class FakeMSSQLPlugin: NSObject, TableProPlugin, DriverPlugin {
    struct CreatedDriverConfiguration: Equatable, Sendable {
        let host: String
        let username: String
        let connectTimeoutSeconds: Int?
        let queryTimeoutSeconds: Int?
    }

    static let pluginName = "Fake MSSQL Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Test stub for MSSQL plugin lookups"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "SQL Server"
    static let databaseDisplayName = "SQL Server"
    static let iconName = "mssql-icon"
    static let defaultPort = 1_433
    static let isDownloadable = true
    static let parameterStyle: ParameterStyle = .questionMark
    static let supportsSchemaSwitching = true
    static let defaultSchemaName = "dbo"

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "[",
        keywords: [],
        functions: [],
        dataTypes: [],
        regexSyntax: .unsupported,
        booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit,
        paginationStyle: .offsetFetch,
        autoLimitStyle: .top
    )

    private struct ConnectFailure: Sendable {
        let error: any Error & Sendable
        let delay: Duration
    }

    private static let connectFailures = OSAllocatedUnfairLock<[String: ConnectFailure]>(initialState: [:])
    private static let connectHolds = OSAllocatedUnfairLock<[String: FakeMSSQLConnectHold]>(initialState: [:])
    private static let createdDriverConfigurations = OSAllocatedUnfairLock<[String: [CreatedDriverConfiguration]]>(
        initialState: [:]
    )

    static func failConnect(for connectionId: UUID, with error: any Error & Sendable, after delay: Duration = .zero) {
        connectFailures.withLock { $0[connectionId.uuidString] = ConnectFailure(error: error, delay: delay) }
    }

    static func clearConnectFailure(for connectionId: UUID) {
        _ = connectFailures.withLock { $0.removeValue(forKey: connectionId.uuidString) }
    }

    static func holdConnect(for connectionId: UUID) -> FakeMSSQLConnectHold {
        let hold = FakeMSSQLConnectHold()
        connectHolds.withLock { $0[connectionId.uuidString] = hold }
        return hold
    }

    static func clearConnectHold(for connectionId: UUID) {
        _ = connectHolds.withLock { $0.removeValue(forKey: connectionId.uuidString) }
    }

    static func configurations(for connectionId: UUID) -> [CreatedDriverConfiguration] {
        createdDriverConfigurations.withLock { $0[connectionId.uuidString] ?? [] }
    }

    static func recordConfigurations(for connectionId: UUID) {
        createdDriverConfigurations.withLock { $0[connectionId.uuidString] = [] }
    }

    static func clearConfigurations(for connectionId: UUID) {
        _ = createdDriverConfigurations.withLock { $0.removeValue(forKey: connectionId.uuidString) }
    }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        let connectionId = config.additionalFields["connectionId"] ?? ""
        let connectHold = Self.connectHolds.withLock { $0[connectionId] }
        let createdConfiguration = CreatedDriverConfiguration(
            host: config.host,
            username: config.username,
            connectTimeoutSeconds: config.additionalFields["connectTimeoutSeconds"].flatMap(Int.init),
            queryTimeoutSeconds: config.additionalFields["queryTimeoutSeconds"].flatMap(Int.init)
        )
        Self.createdDriverConfigurations.withLock {
            $0[connectionId]?.append(createdConfiguration)
        }
        guard let failure = Self.connectFailures.withLock({ $0[connectionId] }) else {
            return FakeMSSQLPluginDriver(connectHold: connectHold)
        }
        return FakeMSSQLPluginDriver(
            connectFailure: failure.error,
            connectDelay: failure.delay,
            connectHold: connectHold
        )
    }

    override required init() {
        super.init()
    }
}

final class FakeMSSQLPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { true }
    var currentSchema: String? { "dbo" }
    var parameterStyle: ParameterStyle { .questionMark }
    var applyQueryTimeoutValues: [Int] { queryTimeoutValues.withLock { $0 } }

    /// The one fact a driver reports about a connection the server has closed under it.
    var hasLostConnection = false
    private(set) var disconnectCallCount = 0
    private let connectFailure: (any Error & Sendable)?
    private let connectDelay: Duration
    private let connectHold: FakeMSSQLConnectHold?
    private let queryTimeoutValues = OSAllocatedUnfairLock<[Int]>(initialState: [])

    init(
        connectFailure: (any Error & Sendable)? = nil,
        connectDelay: Duration = .zero,
        connectHold: FakeMSSQLConnectHold? = nil
    ) {
        self.connectFailure = connectFailure
        self.connectDelay = connectDelay
        self.connectHold = connectHold
    }

    func connect() async throws {
        if let connectHold {
            await connectHold.waitForRelease()
        }
        if connectDelay > .zero {
            try? await Task.sleep(for: connectDelay)
        }
        if let connectFailure { throw connectFailure }
    }
    func disconnect() { disconnectCallCount += 1 }

    func applyQueryTimeout(_ seconds: Int) async throws {
        queryTimeoutValues.withLock { $0.append(seconds) }
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

    func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "]", with: "]]")
        return "[\(escaped)]"
    }

    func qualifiedName(schema: String?, table: String) -> String {
        guard let schema, !schema.isEmpty else { return quoteIdentifier(table) }
        return "\(quoteIdentifier(schema)).\(quoteIdentifier(table))"
    }

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildBrowseQuery(
            table: table, schema: nil, sortColumns: sortColumns,
            columns: columns, limit: limit, offset: offset
        )
    }

    func buildBrowseQuery(
        table: String,
        schema: String?,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        let target = qualifiedName(schema: schema, table: table)
        let orderBy = orderByClause(sortColumns: sortColumns, columns: columns) ?? "ORDER BY (SELECT NULL)"
        return "SELECT * FROM \(target) \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
    }

    func buildFilteredQuery(
        table: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildFilteredQuery(
            table: table, schema: nil, filters: filters, logicMode: logicMode,
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset
        )
    }

    func buildFilteredQuery(
        table: String,
        schema: String?,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        let target = qualifiedName(schema: schema, table: table)
        var query = "SELECT * FROM \(target)"
        let whereClause = whereClause(filters: filters, logicMode: logicMode)
        if !whereClause.isEmpty {
            query += " WHERE \(whereClause)"
        }
        let orderBy = orderByClause(sortColumns: sortColumns, columns: columns) ?? "ORDER BY (SELECT NULL)"
        query += " \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }

    private func orderByClause(
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String]
    ) -> String? {
        let parts = sortColumns.compactMap { sortCol -> String? in
            guard sortCol.columnIndex >= 0, sortCol.columnIndex < columns.count else { return nil }
            let direction = sortCol.ascending ? "ASC" : "DESC"
            return "\(quoteIdentifier(columns[sortCol.columnIndex])) \(direction)"
        }
        guard !parts.isEmpty else { return nil }
        return "ORDER BY " + parts.joined(separator: ", ")
    }

    private func whereClause(
        filters: [(column: String, op: String, value: String)],
        logicMode: String
    ) -> String {
        let connector = logicMode.lowercased() == "or" ? " OR " : " AND "
        let parts = filters.map { filter in
            "\(quoteIdentifier(filter.column)) \(filter.op) '\(filter.value)'"
        }
        return parts.joined(separator: connector)
    }
}

enum FakeMSSQLPluginRegistration {
    private static let didRegister = OSAllocatedUnfairLock(initialState: false)

    @MainActor
    static func registerIfNeeded() {
        let alreadyRegistered = didRegister.withLock { registered -> Bool in
            defer { registered = true }
            return registered
        }
        guard !alreadyRegistered else { return }
        let manager = PluginManager.shared
        guard manager.driverPlugins[FakeMSSQLPlugin.databaseTypeId] == nil else { return }
        manager.driverPlugins[FakeMSSQLPlugin.databaseTypeId] = FakeMSSQLPlugin()
    }
}
