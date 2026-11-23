//
//  DuckDBPlugin.swift
//  TablePro
//

import CDuckDB
import Foundation
import os
import TableProDuckDBCore
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLQuoting
import TableProSQLVocabulary

nonisolated final class DuckDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "DuckDB Driver"
    static let pluginVersion = "1.1.0"
    static let pluginDescription = "DuckDB analytical database support"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "DuckDB"

    static let supportsRenameTable = true
    static let databaseDisplayName = "DuckDB"
    static let iconName = "duckdb-icon"
    static let defaultPort = 9_494

    // MARK: - UI/Capability Metadata

    static let isDownloadable = true
    static let pathFieldRole: PathFieldRole = .database
    static let requiresAuthentication = false
    static let connectionMode: ConnectionMode = .apiOnly
    static let supportsHealthMonitor = false
    // Remote carries its own SSL Mode: the shared one is keyed to the built-in Host, which this driver
    // never dials, and every connection saved before it stores Disabled while Quack uses HTTPS.
    static let supportsSSL = false
    // The app forwards duckdbHost and duckdbPort and rewrites them to the loopback, so every tunnel kind
    // carries a Remote connection. Local File dials nothing, and the app offers none there.
    static let supportsSSH = true
    // DuckDB has no switch for foreign key checks: `PRAGMA foreign_keys=OFF` is accepted and changes
    // nothing, so a Drop prompt offering to ignore them would add no statement.
    static let supportsForeignKeyDisable = false
    static let urlSchemes: [String] = ["duckdb", "quack"]

    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(
            id: "duckdbMode",
            label: String(localized: "Connection Type"),
            defaultValue: "local",
            fieldType: .dropdown(options: [
                ConnectionField.DropdownOption(value: "local", label: String(localized: "Local File")),
                ConnectionField.DropdownOption(value: "remote", label: String(localized: "Remote (Quack, experimental)"))
            ]),
            section: .authentication
        ),
        ConnectionField(
            id: "duckdbFilePath",
            label: String(localized: "Database File"),
            placeholder: "/path/to/database.duckdb",
            required: true,
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["local"])
        ),
        ConnectionField(
            id: "duckdbHost",
            label: String(localized: "Host"),
            placeholder: "localhost",
            required: true,
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["remote"])
        ),
        ConnectionField(
            id: "duckdbPort",
            label: String(localized: "Port"),
            placeholder: "9494",
            defaultValue: "9494",
            fieldType: .number,
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["remote"])
        ),
        ConnectionField(
            id: "duckdbToken",
            label: String(localized: "Token"),
            required: true,
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true,
            visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["remote"])
        ),
        ConnectionField(
            id: "duckdbAlias",
            label: String(localized: "Database Alias"),
            placeholder: "remotedb",
            required: true,
            defaultValue: "remotedb",
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["remote"])
        ),
        ConnectionField(
            id: "duckdbSSLMode",
            label: String(localized: "SSL Mode"),
            defaultValue: QuackSSLMode.automatic.rawValue,
            fieldType: .dropdown(options: [
                ConnectionField.DropdownOption(value: QuackSSLMode.automatic.rawValue, label: String(localized: "Automatic")),
                ConnectionField.DropdownOption(value: QuackSSLMode.disabled.rawValue, label: String(localized: "Disabled")),
                ConnectionField.DropdownOption(value: QuackSSLMode.required.rawValue, label: String(localized: "Required (skip verify)")),
                ConnectionField.DropdownOption(value: QuackSSLMode.verifyIdentity.rawValue, label: String(localized: "Verify Identity")),
                ConnectionField.DropdownOption(value: QuackSSLMode.verifyFingerprint.rawValue, label: String(localized: "Verify Fingerprint"))
            ]),
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["remote"])
        ),
        ConnectionField(
            id: "duckdbCACertificateFilePath",
            label: String(localized: "CA Certificate"),
            placeholder: String(localized: "Optional"),
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "duckdbSSLMode", values: [QuackSSLMode.verifyIdentity.rawValue])
        ),
        ConnectionField(
            id: "duckdbCertificateFingerprint",
            label: String(localized: "Certificate Fingerprint"),
            required: true,
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: "duckdbSSLMode", values: [QuackSSLMode.verifyFingerprint.rawValue])
        ),
        /// Named for what it does to the file rather than to TablePro, to keep it apart from
        /// Safe Mode's own Read-Only level: that one is a policy this app applies to itself and
        /// can be changed while connected, this one is how the file is opened and is fixed for
        /// the life of the connection.
        ConnectionField(
            id: DuckDBAccessMode.fieldId,
            label: String(localized: "Open the File Read-Only"),
            defaultValue: "false",
            fieldType: .toggle,
            section: .advanced,
            visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["local"])
        ),
        ConnectionField(
            id: DuckDBIdleRelease.fieldId,
            label: String(localized: "Release the File Lock After (minutes, 0 to keep it)"),
            defaultValue: DuckDBIdleRelease.neverValue,
            fieldType: .stepper(range: ConnectionField.IntRange(0...DuckDBIdleRelease.maximumMinutes)),
            section: .advanced,
            visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["local"])
        ),
        .attachedDatabases(visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["local"]))
    ]
    static let fileExtensions: [String] = DuckDBFileKinds.all
    static let brandColorHex = "#FFD900"
    static let parameterStyle: ParameterStyle = .dollar

    static let supportsDatabaseSwitching = true
    static let supportsSchemaSwitching = true
    static let supportsRoutines = true
    static let databaseGroupingStrategy: GroupingStrategy = .bySchema
    static let defaultSchemaName = "main"
    static let systemDatabaseNames: [String] = ["system", "temp"]
    static let postConnectActions: [PostConnectAction] = [.selectSchemaFromLastSession]
    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT", "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT"],
        "Float": ["FLOAT", "DOUBLE", "DECIMAL", "NUMERIC"],
        "String": ["VARCHAR", "TEXT", "CHAR", "BPCHAR"],
        "Date": ["DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "TIMESTAMP_S", "TIMESTAMP_MS", "TIMESTAMP_NS", "INTERVAL"],
        "Binary": ["BLOB", "BYTEA", "BIT", "BITSTRING"],
        "Boolean": ["BOOLEAN"],
        "JSON": ["JSON"],
        "UUID": ["UUID"],
        "List": ["LIST"],
        "Struct": ["STRUCT"],
        "Map": ["MAP"],
        "Union": ["UNION"],
        "Enum": ["ENUM"]
    ]

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "FULL",
            "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "ILIKE", "BETWEEN", "AS",
            "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "FETCH", "FIRST", "ROWS", "ONLY",
            "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
            "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
            "ADD", "MODIFY", "COLUMN", "RENAME",
            "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",
            "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "NULLIF",
            "UNION", "INTERSECT", "EXCEPT",
            "COPY", "PRAGMA", "DESCRIBE", "SUMMARIZE", "PIVOT", "UNPIVOT",
            "QUALIFY", "SAMPLE", "TABLESAMPLE", "RETURNING",
            "INSTALL", "LOAD", "FORCE", "ATTACH", "DETACH",
            "EXPORT", "IMPORT",
            "WITH", "RECURSIVE", "MATERIALIZED",
            "EXPLAIN", "ANALYZE",
            "WINDOW", "OVER", "PARTITION"
        ],
        functions: SQLEngineVocabulary.duckDB.functions,
        dataTypes: SQLEngineVocabulary.duckDB.dataTypes,
        tableOptions: SQLEngineVocabulary.duckDB.tableOptions,
        regexSyntax: .regexpMatches,
        booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit,
        paginationStyle: .limit,
        caseSensitivityStyle: .ilikeOperator,
        operators: SQLEngineVocabulary.duckDB.operators.compactMap(SQLOperatorDescriptor.init(vocabulary:)),
        // DuckDB has no LIKE or lower() for INTEGER, UUID or DATE: `~~(INTEGER, STRING_LITERAL)` is a binder error.
        textCastTypeName: "VARCHAR",
        functionNamesAreCaseInsensitive: SQLEngineVocabulary.duckDB.functionNamesAreCaseInsensitive,
        typeNamesAreCaseInsensitive: true
    )

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        DuckDBPluginDriver(config: config)
    }
}

nonisolated private extension SQLOperatorDescriptor {
    init?(vocabulary entry: SQLEngineVocabulary.Operator) {
        guard let category = Category(rawValue: entry.category),
              let placement = Placement(rawValue: entry.placement) else { return nil }
        self.init(
            symbol: entry.symbol,
            summary: entry.summary,
            category: category,
            placement: placement,
            appliesToTypes: entry.appliesToTypes
        )
    }
}

// MARK: - DuckDB Plugin Driver

nonisolated final class DuckDBPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let liveConnection: DuckDBLiveConnectionBox
    private let connectionActor: DuckDBConnectionActor
    // A transfer connection's reads are handed out a batch per pull, so the session sharing its executor runs between.
    private let pullsReads: Bool
    private let idleReleaseTimer = DuckDBIdleReleaseTimer()
    private let trustBundleFile = DuckDBTrustBundleFile()
    private let stateLock = NSLock()
    nonisolated(unsafe) private var _currentSchema: String = "main"
    nonisolated(unsafe) private var _currentDatabase: String?
    nonisolated(unsafe) private var _attachSetup: [String] = []
    nonisolated(unsafe) private var _connectionWarning: String?

    private static let logger = Logger(subsystem: "com.TablePro", category: "DuckDBPluginDriver")

    var currentSchema: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentSchema
    }

    var currentDatabase: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentDatabase
    }
    var serverVersion: String? { String(cString: duckdb_library_version()) }
    var connectionWarning: String? { stateLock.withLock { _connectionWarning } }
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }
    var supportsTransactionalDDL: Bool { true }
    var parameterStyle: ParameterStyle { .dollar }

    func sessionTransactionState() async -> PluginSessionTransactionState {
        await connectionActor.sessionTransactionState()
    }

    var capabilities: PluginCapabilities {
        [
            .parameterizedQueries,
            .transactions,
            .alterTableDDL,
            .multiSchema,
            .cancelQuery,
            .schemaCompare,
            .dataCompare,
            .readOnlyStatements,
            .enforcesReadOnlyMode,
        ]
    }

    init(config: DriverConnectionConfig) {
        self.config = config
        let liveConnection = DuckDBLiveConnectionBox()
        self.liveConnection = liveConnection
        self.connectionActor = DuckDBConnectionActor(liveConnection: liveConnection)
        pullsReads = false
    }

    private init(
        config: DriverConnectionConfig,
        transferOn connectionActor: DuckDBConnectionActor,
        liveConnection: DuckDBLiveConnectionBox,
        database: String?,
        schema: String
    ) {
        self.config = config
        self.liveConnection = liveConnection
        self.connectionActor = connectionActor
        pullsReads = true
        _currentDatabase = database
        _currentSchema = schema
    }

    // A driver on a connection of its own to this session's database, for a transfer: open already, on the session's
    // catalog and schema, and its disconnect ends only that connection.
    func openTransferDriver() async throws -> DuckDBPluginDriver {
        let live = DuckDBLiveConnectionBox()
        let transfer = try await connectionActor.openTransferConnection(liveConnection: live)
        let (database, schema) = stateLock.withLock { (_currentDatabase, _currentSchema) }
        if let database, !database.isEmpty {
            do {
                _ = try await transfer.executeQuery(DuckDBSchemaQueries.useSchema(schema, in: database))
            } catch {
                await transfer.close()
                throw error
            }
        }
        return DuckDBPluginDriver(
            config: config, transferOn: transfer, liveConnection: live, database: database, schema: schema
        )
    }

    /// The timer's task holds the connection actor, not the driver, so a driver dropped without
    /// `disconnect()` leaves it waking forever over a handle nobody can reach.
    deinit {
        let timer = idleReleaseTimer
        Task { await timer.stop() }
    }

    private func resolveSchema(_ schema: String?) -> String {
        if let schema { return schema }
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentSchema
    }

    // `duckdb_tables()` and its siblings span every attached database, so a schema name alone matches all of them.
    func requireCatalog() throws -> String {
        stateLock.lock()
        let catalog = _currentDatabase
        stateLock.unlock()
        guard let catalog, !catalog.isEmpty else { throw DuckDBPluginError.catalogUnresolved }
        return catalog
    }

    // MARK: - Connection

    private var isRemoteMode: Bool {
        config.additionalFields["duckdbMode"] == "remote"
    }

    private var remoteAlias: String? {
        guard isRemoteMode else { return nil }
        let alias = (config.additionalFields["duckdbAlias"] ?? "").trimmingCharacters(in: .whitespaces)
        return alias.isEmpty ? "remotedb" : alias
    }

    private var resolvedFilePath: String {
        let raw = config.additionalFields["duckdbFilePath"].flatMap { $0.isEmpty ? nil : $0 } ?? config.database
        return expandPath(raw)
    }

    func connect() async throws {
        if isRemoteMode {
            try await connectRemote()
        } else {
            try await connectLocal()
        }
    }

    private func connectLocal() async throws {
        let path = resolvedFilePath

        if !FileManager.default.fileExists(atPath: path) {
            guard DuckDBFileKinds.canBeCreated(atPath: path) else {
                throw DuckDBPluginError.connectionFailed(
                    String(format: String(localized: "No file at %@"), path)
                )
            }
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try? FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
            }
        }

        let spec = DuckDBOpenSpec(
            path: path,
            accessMode: DuckDBAccessMode.resolve(fields: config.additionalFields, path: path)
        )
        try await connectionActor.open(spec: spec)
        // DuckDB holds an exclusive lock on the file for as long as the handle is open, and
        // nothing upstream disconnects a driver whose connect threw: DatabaseManager only
        // calls disconnect on a cancelled attempt. Without this, one failure here locks the
        // file against every later attempt until TablePro quits.
        do {
            await enableExtensionAutoloading()
            try await refreshCurrentPosition()
        } catch {
            await connectionActor.close()
            throw error
        }
        // After the position is read: with more than one catalog open and nothing `USE`d yet, the
        // opened file's catalog can no longer be told from the attached ones.
        // A CSV, Parquet or in-memory main file opens read-write whatever the setting says, but an
        // attached database file can still be written, so it follows the setting itself.
        await attachConfiguredDatabases(readOnly: config.additionalFields[DuckDBAccessMode.fieldId] == "true")
        await connectionActor.captureSettingsBaseline()
        await startIdleReleaseIfRequested()
    }

    private func connectRemote() async throws {
        let plan: QuackConnectPlan
        do {
            plan = try QuackConnectPlan(QuackConnectRequest(
                host: config.additionalFields["duckdbHost"] ?? "",
                port: config.additionalFields["duckdbPort"] ?? "",
                alias: config.additionalFields["duckdbAlias"] ?? "",
                token: config.additionalFields["duckdbToken"] ?? "",
                sslMode: config.additionalFields["duckdbSSLMode"],
                caCertificatePath: config.additionalFields["duckdbCACertificateFilePath"],
                certificateFingerprint: config.additionalFields["duckdbCertificateFingerprint"],
                // Through a tunnel the app has rewritten duckdbHost and duckdbPort to the loopback forward
                // and keeps the server's own name here, which is the name its certificate carries.
                tunneledServerHost: config.tunneledServerName
            ))
        } catch {
            throw Self.remoteConnectFailure(error, tunneled: false)
        }
        let attempt = DuckDBConnectAttempt(
            additionalFields: config.additionalFields,
            interrupt: { [liveConnection] in liveConnection.interrupt() }
        )
        let timeoutTask = Task.detached { [attempt] in
            do {
                try await ContinuousClock().sleep(until: attempt.deadline)
            } catch {
                return
            }
            attempt.expire()
        }

        // Every step below can throw, and nothing upstream closes a driver whose connect failed:
        // `DatabaseManager` disconnects only a cancelled attempt. A remote host that does not
        // resolve is enough to reach this, and each attempt used to leak a whole DuckDB instance
        // and its worker threads for the life of the app. `connectLocal` has the same guard.
        do {
            try await withTaskCancellationHandler(
                operation: {
                    try attempt.check()
                    try await connectionActor.open(spec: DuckDBOpenSpec(
                        path: ":memory:", accessMode: .readWrite, allowsPersistentSecrets: false
                    ))
                    try attempt.check()
                    try await enableExtensionAutoloading(during: attempt)
                    for step in plan.steps {
                        try await runRemoteConnectStep(step, during: attempt)
                    }
                    try attempt.finish {
                        stateLock.withLock {
                            _currentSchema = "main"
                            _currentDatabase = plan.alias
                        }
                    }
                },
                onCancel: {
                    attempt.cancel()
                }
            )
        } catch {
            timeoutTask.cancel()
            let attemptError = attempt.stop()
            resetCurrentPosition()
            await connectionActor.close()
            trustBundleFile.remove()
            if attemptError is DuckDBConnectAttemptError {
                throw DuckDBPluginError.connectionFailed(
                    String(localized: "Connecting to the remote DuckDB database timed out.")
                )
            }
            if let attemptError { throw attemptError }
            throw Self.remoteConnectFailure(error, tunneled: plan.isTunneled)
        }
        timeoutTask.cancel()
    }

    private func runRemoteConnectStep(_ step: QuackConnectPlan.Step, during attempt: DuckDBConnectAttempt) async throws {
        switch step {
        case .loadExtension(let name):
            try await QuackExtensionLoader.load(name) { statement in
                try await executeRemoteConnectStatement(statement, during: attempt)
            }
        case .trustCACertificate(let path):
            let bundlePath = try trustBundleFile.write(caCertificatePath: path)
            try await executeRemoteConnectStatement(
                QuackConnectPlan.setCACertFileStatement(bundlePath: bundlePath),
                during: attempt
            )
        case .statement(let statement):
            try await executeRemoteConnectStatement(statement, during: attempt)
        }
    }

    /// curl's TLS texts name no field, and one of them mentions an SSH key, so they are replaced by
    /// messages that name the SSL Mode, CA Certificate or Certificate Fingerprint to change.
    private static func remoteConnectFailure(_ error: any Error, tunneled: Bool) -> any Error {
        guard let classified = QuackConnectErrorClassifier.classify(error, tunneled: tunneled) else { return error }
        return DuckDBPluginError.connectionFailed(classified.localizedDescription)
    }

    /// Every metadata query is anchored to the catalog, and the app seeds the browsed
    /// database from `currentDatabase`, so the driver has to know which catalog the file
    /// opened as. DuckDB names it after the file stem, which is not derivable from the
    /// path alone once an alias or a URL is involved.
    ///
    /// This throws rather than logging and carrying on. Swallowing it left the connection
    /// reporting success with no catalog, which every later query then filtered on, so the
    /// sidebar came up empty and nothing said why.
    private func refreshCurrentPosition() async throws {
        let position = try await readPosition()
        let catalog = try await resolveOpenedCatalog(named: position.catalog)

        stateLock.withLock {
            _currentDatabase = catalog
            if let schema = position.schema { _currentSchema = schema }
        }
    }

    /// Nothing has run `USE` yet at connect, so `search_path` is usually empty and the catalog
    /// comes from the one non-internal database the file opened as. Anything other than exactly
    /// one is reported rather than guessed at: picking a row would anchor every metadata query
    /// to a database the connection is not on, which is the empty sidebar this all started from.
    private func resolveOpenedCatalog(named: String?) async throws -> String {
        if let named, let canonical = await canonicalCatalogName(matching: named) {
            return canonical
        }

        let databases = try await connectionActor.executeQuery(DuckDBSchemaQueries.listDatabases)
        let names = databases.rows.compactMap { $0[safe: 0]?.asText?.nilIfEmpty }
        guard names.count == 1, let only = names.first else {
            throw DuckDBPluginError.connectionFailed(
                names.isEmpty
                    ? String(localized: "DuckDB opened the file but reported no catalog to browse")
                    : String(
                        format: String(localized: "DuckDB opened %d catalogs and none of them is current"),
                        names.count
                    )
            )
        }
        return only
    }

    private func attachConfiguredDatabases(readOnly: Bool) async {
        let databases: [AttachedDatabase]
        do {
            databases = try AttachedDatabaseList.decode(config.additionalFields[AttachedDatabaseList.fieldId])
        } catch {
            stateLock.withLock { _connectionWarning = error.localizedDescription }
            return
        }
        var attached: [AttachedDatabase] = []
        let actor = connectionActor
        let failures = await AttachedDatabaseAttacher.attach(databases) { database in
            _ = try await actor.executeQuery(DuckDBSchemaQueries.attach(database, readOnly: readOnly))
            attached.append(database)
        }
        await actor.setConfiguredAttachments(attached, readOnly: readOnly)
        stateLock.withLock {
            _attachSetup = attached.map { DuckDBSchemaQueries.attach($0, readOnly: readOnly) }
            _connectionWarning = AttachedDatabaseAttacher.warning(for: failures)
        }
    }

    private func readPosition() async throws -> DuckDBPositionParser.Position {
        let result = try await connectionActor.executeQuery(DuckDBSchemaQueries.currentPosition)
        var settings: [String: String] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText, let value = row[safe: 1]?.asText else { continue }
            settings[name] = value
        }
        return DuckDBPositionParser.parse(settings: settings)
    }

    private func enableExtensionAutoloading() async {
        do {
            for statement in DuckDBExtensionPolicy.sessionStatements {
                try await connectionActor.executeQuery(statement)
            }
        } catch {
            Self.logger.warning("Failed to enable DuckDB extension autoloading: \(error.localizedDescription)")
        }
    }

    private func enableExtensionAutoloading(during attempt: DuckDBConnectAttempt) async throws {
        for statement in DuckDBExtensionPolicy.sessionStatements {
            do {
                try await executeRemoteConnectStatement(statement, during: attempt)
            } catch {
                try attempt.check()
                Self.logger.warning("DuckDB '\(statement)' failed: \(error.localizedDescription)")
            }
        }
    }

    private func executeRemoteConnectStatement(
        _ statement: String,
        during attempt: DuckDBConnectAttempt
    ) async throws {
        try attempt.check()
        do {
            try await connectionActor.executeQuery(statement)
        } catch {
            try attempt.check()
            throw error
        }
        try attempt.check()
    }

    private func resetCurrentPosition() {
        stateLock.withLock {
            _currentSchema = "main"
            _currentDatabase = nil
            _attachSetup = []
        }
    }

    // MARK: - Idle file-lock release

    /// Only a file-backed DuckDB database holds a lock worth giving up. `:memory:`, which the
    /// remote Quack mode opens, holds none and is destroyed by a close, and the Parquet, CSV and
    /// JSON readers are never written back to.
    private var canReleaseFile: Bool {
        guard !isRemoteMode else { return false }
        return DuckDBAccessMode.carriesAccessMode(path: resolvedFilePath)
    }

    var releasableResourceCommandTitle: String? {
        guard canReleaseFile, liveConnection.isOpen else { return nil }
        return String(localized: "Release File Lock")
    }

    /// The statements that put a reopened session back where it was. Recomputed rather than
    /// appended to, so a session that has switched database a dozen times replays one `USE`.
    private func refreshSessionSetup() async {
        var statements = DuckDBExtensionPolicy.sessionStatements
        let (database, schema, attachSetup) = stateLock.withLock { (_currentDatabase, _currentSchema, _attachSetup) }
        statements += attachSetup
        if let database, !database.isEmpty {
            statements.append(DuckDBSchemaQueries.useSchema(schema, in: database))
        }
        await connectionActor.setSessionSetup(statements)
    }

    private func startIdleReleaseIfRequested() async {
        await refreshSessionSetup()
        guard canReleaseFile,
              let interval = DuckDBIdleRelease.interval(
                  fromFieldValue: config.additionalFields[DuckDBIdleRelease.fieldId]
              )
        else { return }

        let actor = connectionActor
        await idleReleaseTimer.start(interval: interval) {
            let outcome = await actor.releaseFile(idleFor: interval)
            guard outcome != .released, outcome != .notIdleYet, outcome != .alreadyReleased else { return }
            Self.logger.debug("DuckDB kept the file lock: \(String(describing: outcome), privacy: .public)")
        }
    }

    /// Gives the file's lock back now, for the Release File Lock command. A session holding
    /// something a reopen would destroy keeps the lock and says which thing, because a command
    /// that silently does nothing reads as broken.
    func releaseIdleResource() async throws -> PluginResourceRelease {
        guard canReleaseFile else { return .nothingToRelease }
        let outcome = await connectionActor.releaseFile(idleFor: nil)
        switch outcome {
        case .released:
            return .released
        case .alreadyReleased, .notOpen, .notIdleYet:
            return .nothingToRelease
        case .holdsOpenTransaction:
            return .kept(String(localized: "This connection has an open transaction. Commit or roll it back first."))
        case .holdsSessionObjects:
            return .kept(String(localized: "This connection has session objects, such as a temporary table, a macro or a prepared statement, which closing the file would delete."))
        case .holdsAttachedCatalogs:
            return .kept(String(localized: "This connection has another database attached, which closing the file would detach."))
        case .holdsChangedSettings:
            return .kept(String(localized: "This connection has settings that closing the file would reset."))
        case .stateUnreadable:
            return .kept(String(localized: "TablePro could not read what this connection is holding, so it kept the file."))
        }
    }

    func importExportedDatabase(from folder: URL, into file: URL) async throws {
        try await DuckDBIsolatedImport.run(folder: folder.path, into: file.path)
    }

    func disconnect() {
        let closing = beginClose()
        Task { await closing() }
    }

    // The disconnect that returns once the file is closed, for a caller that hands the file on next.
    func close() async {
        await beginClose()()
    }

    private func beginClose() -> @Sendable () async -> Void {
        liveConnection.interrupt()
        resetCurrentPosition()
        let actor = connectionActor
        let timer = idleReleaseTimer
        let trustBundle = trustBundleFile.take()
        return {
            await timer.stop()
            await actor.close()
            // Only once the instance is closed, so no request of it reads a bundle that is gone.
            if let trustBundle { try? FileManager.default.removeItem(at: trustBundle) }
        }
    }

    /// A ping is TablePro asking whether the connection still works, not the user using it, so it
    /// neither counts as activity nor takes the file back. A released connection is healthy by
    /// definition: nothing is wrong with it, it is waiting to be used, and reopening the file to
    /// prove that would take the lock straight back off whatever the release handed it to.
    func ping() async throws {
        guard !(await connectionActor.hasReleasedFile) else { return }
        try await connectionActor.pingQuery()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        // DuckDB doesn't have a session-level query timeout like network databases
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        Self.queryResult(try await connectionActor.executeQuery(query))
    }

    func execute(query: String, context: PluginStatementContext) async throws -> PluginQueryResult {
        guard let reason = DuckDBReadOnlyStatement.reason(for: context) else { return try await execute(query: query) }
        return Self.queryResult(try await connectionActor.executeReadOnly(
            query, parameters: [], byteLimit: context.resultByteLimit, reason: reason
        ))
    }

    func executeParameterized(
        query: String,
        parameters: [PluginCellValue]
    ) async throws -> PluginQueryResult {
        Self.queryResult(try await connectionActor.executePrepared(query, parameters: parameters))
    }

    func executeParameterized(
        query: String,
        parameters: [PluginCellValue],
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        guard let reason = DuckDBReadOnlyStatement.reason(for: context) else {
            return try await executeParameterized(query: query, parameters: parameters)
        }
        return Self.queryResult(try await connectionActor.executeReadOnly(
            query, parameters: parameters, byteLimit: context.resultByteLimit, reason: reason
        ))
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        guard rowCap > 0 else { return nil }
        return Self.queryResult(try await connectionActor.executeBounded(query, parameters: [], rowCap: rowCap))
    }

    // A context the read-only mode does not cover goes back to the host as PluginKit's default sends it.
    func executeBoundedQuery(
        query: String,
        rowCap: Int,
        context: PluginStatementContext
    ) async throws -> PluginQueryResult? {
        guard let reason = DuckDBReadOnlyStatement.reason(for: context) else {
            guard !context.enforcesReadOnly, !context.readOnly, !context.readsCatalog,
                  context.allowsDestructive, context.allowsServerCode
            else { return nil }
            return try await executeBoundedQuery(query: query, rowCap: rowCap)
        }
        guard rowCap > 0 else { return nil }
        return Self.queryResult(try await connectionActor.executeReadOnly(
            query, parameters: [], rowCap: rowCap, byteLimit: context.resultByteLimit, reason: reason
        ))
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        guard let cap = rowCap, cap > 0 else {
            return Self.queryResult(try await connectionActor.executePrepared(query, parameters: parameters ?? []))
        }
        return Self.queryResult(try await connectionActor.executeBounded(query, parameters: parameters ?? [], rowCap: cap))
    }

    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [PluginCellValue]?,
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        guard let reason = DuckDBReadOnlyStatement.reason(for: context) else {
            return try await executeUserQuery(query: query, rowCap: rowCap, parameters: parameters)
        }
        let cap = rowCap.flatMap { $0 > 0 ? $0 : nil }
        return Self.queryResult(try await connectionActor.executeReadOnly(
            query, parameters: parameters ?? [], rowCap: cap, byteLimit: context.resultByteLimit, reason: reason
        ))
    }

    private static func queryResult(_ rawResult: DuckDBRawResult) -> PluginQueryResult {
        PluginQueryResult(
            columns: rawResult.columns,
            columnTypeNames: rawResult.columnTypeNames,
            rows: rawResult.rows,
            rowsAffected: rawResult.rowsAffected,
            executionTime: rawResult.executionTime,
            isTruncated: rawResult.isTruncated
        )
    }

    func cancelQuery() throws {
        liveConnection.interrupt()
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard !pullsReads else { return pulledRows(query: query, context: PluginStatementContext()) }
        let actor = connectionActor

        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(DuckDBBoundedStream.bufferedBatches)) { continuation in
            Task {
                do {
                    try await actor.streamQuery(query, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func streamRows(query: String, context: PluginStatementContext) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard !pullsReads else { return pulledRows(query: query, context: context) }
        guard let reason = DuckDBReadOnlyStatement.reason(for: context) else { return streamRows(query: query) }
        let actor = connectionActor
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(DuckDBBoundedStream.bufferedBatches)) { continuation in
            Task {
                do {
                    try await actor.streamReadOnly(query, reason: reason, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // The rows a batch per pull, so the connection's executor runs other work between batches. Any other statement on
    // the connection ends the read.
    func pulledRows(query: String, context: PluginStatementContext) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let cursor = pulledCursor(query: query, context: context) { _, value in value.pluginValue }
        return AsyncThrowingStream(unfolding: {
            switch try await cursor.next() {
            case .header(let header): return .header(header)
            case .rows(let rows): return .rows(rows)
            case nil: return nil
            }
        })
    }

    // The same read with each value made by `read` from the chunk in place, so a host that cuts a value for display
    // never copies the rest of it.
    func pulledValues<Value: Sendable>(
        query: String,
        context: PluginStatementContext,
        reading read: @escaping DuckDBValueReader<Value>
    ) -> AsyncThrowingStream<DuckDBPulledElement<Value>, Error> {
        let cursor = pulledCursor(query: query, context: context, reading: read)
        return AsyncThrowingStream(unfolding: { try await cursor.next() })
    }

    private func pulledCursor<Value: Sendable>(
        query: String,
        context: PluginStatementContext,
        reading read: @escaping DuckDBValueReader<Value>
    ) -> DuckDBPulledRows<Value> {
        DuckDBPulledRows(
            actor: connectionActor,
            query: query,
            reason: DuckDBReadOnlyStatement.reason(for: context),
            live: liveConnection,
            read: read
        )
    }

    // Gives up the read `pulledRows` handed out, for a consumer that stopped before its end.
    func endPulledRows() async {
        await connectionActor.endPulledRead()
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        try await DuckDBExportCatalog.tables(catalog: try requireCatalog(), schema: resolveSchema(schema), run: catalogRun)
    }

    /// A remote catalog answers its schema list best-effort, falling back to `main` when it cannot,
    /// and one query filtered by that list has no such fallback, so it keeps the per-schema listing.
    func fetchTablesInAllSchemas() async throws -> [PluginTableInfo]? {
        guard remoteAlias == nil else { return nil }
        let result = try await executeParameterized(
            query: DuckDBSchemaQueries.listTables(in: .allSchemas),
            parameters: [.text(try requireCatalog())]
        )
        return DuckDBExportCatalog.tableInfos(from: result)
    }

    /// A remote catalog answers metadata best-effort, so it stays per schema, where a failed read
    /// names its one schema instead of failing the whole set.
    func fetchTables(inSchemas schemas: [String]) async throws -> [PluginTableInfo]? {
        guard remoteAlias == nil else { return nil }
        guard !schemas.isEmpty else { return [] }
        let result = try await executeParameterized(
            query: DuckDBSchemaQueries.listTables(in: .schemas(schemas)),
            parameters: [.text(try requireCatalog())]
        )
        return DuckDBExportCatalog.tableInfos(from: result)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let schemaName = resolveSchema(schema)
        return try await DuckDBExportCatalog.columns(
            catalog: try requireCatalog(), schema: schemaName, table: table, run: catalogRun
        )
    }

    var fetchesAllColumnsInOneRequest: Bool { true }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let schemaName = resolveSchema(schema)
        return try await DuckDBExportCatalog.allColumns(
            catalog: try requireCatalog(), schema: schemaName, keepsSpellingsApart: true, run: catalogRun
        )
    }

    func fetchAllColumnsForExport(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        try await DuckDBExportCatalog.allColumns(
            catalog: try requireCatalog(), schema: resolveSchema(schema), keepsSpellingsApart: true, run: catalogRun
        )
    }

    func fetchAllForeignKeysForExport(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        try await PluginNameSpellings.readEachTable(try await fetchTables(schema: schema).map(\.name)) {
            try await fetchForeignKeys(table: $0, schema: schema)
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let schemaName = resolveSchema(schema)
        let catalog = try requireCatalog()
        do {
            let result = try await executeParameterized(
                query: DuckDBSchemaQueries.indexesForTable,
                parameters: [.text(catalog), .text(schemaName), .text(table)]
            )
            return result.rows.compactMap { row in
                guard let name = row[safe: 0]?.asText else { return nil }
                let sql = row[safe: 2]?.asText

                let keys = DuckDBIndexClauses.keyParts(ofCreateIndex: sql)
                /// `duckdb_indexes()` lists user indexes only, so nothing here backs a primary key.
                /// Reading one out of the name matched any index called something like
                /// `idx_primary_contact`, which then reported as the table's primary key and as
                /// unique.
                return PluginIndexInfo(
                    name: name,
                    columns: keys.columns,
                    isUnique: (row[safe: 1]?.asText) == "true",
                    isPrimary: false,
                    type: "ART",
                    expressions: keys.expressions.isEmpty ? nil : keys.expressions,
                    includedColumns: nil,
                    ddlMethodAndKeys: nil,
                    ddlWhereClause: nil,
                    isValid: nil
                )
            }
        } catch {
            return []
        }
    }

    var tableDDLIncludesForeignKeys: Bool { DuckDBExportCatalog.tableDDLIncludesForeignKeys }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let schemaName = resolveSchema(schema)
        return try await DuckDBExportCatalog.foreignKeys(
            catalog: try requireCatalog(), schema: schemaName, table: table, run: catalogRun
        )
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let schemaName = resolveSchema(schema)
        return try await DuckDBExportCatalog.tableDDL(
            catalog: try requireCatalog(), schema: schemaName, table: table, run: catalogRun
        )
    }

    func fetchIndexDDL(table: String, schema: String?) async throws -> [String] {
        try await DuckDBExportCatalog.indexDDL(
            catalog: try requireCatalog(), schema: resolveSchema(schema), table: table, run: catalogRun
        )
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let schemaName = resolveSchema(schema)
        return try await DuckDBExportCatalog.viewDefinition(
            catalog: try requireCatalog(), schema: schemaName, view: view, run: catalogRun
        )
    }

    // The catalog reads bind the catalog, schema and name; the macro list binds nothing and runs unprepared, as it
    // always has.
    var catalogRun: DuckDBExportCatalog.Run {
        { [self] query, parameters in
            if parameters.isEmpty {
                return try await execute(query: query)
            }
            return try await executeParameterized(query: query, parameters: parameters)
        }
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let schemaName = resolveSchema(schema)
        let countResult = try await execute(
            query: DuckDBSchemaQueries.rowCountProbe(schema: schemaName, table: table, limit: 100_001)
        )
        let rowCount: Int64? = {
            guard let row = countResult.rows.first, let firstCell = row.first else { return nil }
            return Int64(firstCell.asText ?? "0")
        }()
        let comment = try await catalogComment(table: table, schema: schemaName)

        return PluginTableMetadata(
            tableName: table,
            rowCount: rowCount,
            comment: comment,
            engine: "DuckDB"
        )
    }

    // fetchTableMetadata probes up to 100,001 rows; the comment alone is a catalog read.
    func fetchObjectComment(table: String, schema: String?) async throws -> String? {
        try await catalogComment(table: table, schema: resolveSchema(schema))
    }

    private func catalogComment(table: String, schema: String) async throws -> String? {
        let result = try await executeParameterized(
            query: DuckDBSchemaQueries.objectComment,
            parameters: [.text(try requireCatalog()), .text(schema), .text(table)]
        )
        return result.rows.lazy.compactMap { $0[safe: 0]?.asText?.nilIfEmpty }.first
    }

    func quoteIdentifier(_ name: String) -> String {
        DuckDBSchemaQueries.quoteIdentifier(name)
    }

    // DuckDB reads statement text as a C string, which ends at a NUL, so each one is joined in with chr(0).
    func escapeStringLiteral(_ value: String) -> String {
        guard value.utf8.contains(0) else { return SQLQuoting.stringLiteralBody(value) }
        return value.unicodeScalars.split(separator: "\0", omittingEmptySubsequences: false)
            .map { SQLQuoting.stringLiteralBody(String(Substring($0))) }
            .joined(separator: "'||chr(0)||'")
    }

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        DuckDBSchemaQueries.objectCommentStatement(
            objectType: objectType, schema: resolveSchema(schema), name: name, comment: comment
        )
    }

    // MARK: - Schema Navigation

    func fetchSchemas() async throws -> [String] {
        let query = DuckDBSchemaQueries.listSchemas
        let parameters: [PluginCellValue] = [.text(try requireCatalog())]
        if remoteAlias != nil {
            let result = try? await executeParameterized(query: query, parameters: parameters)
            let schemas = result?.rows.compactMap { $0[safe: 0]?.asText } ?? []
            return schemas.isEmpty ? ["main"] : schemas
        }
        let result = try await executeParameterized(query: query, parameters: parameters)
        return result.rows.compactMap { $0[safe: 0]?.asText }
    }

    func switchSchema(to schema: String) async throws {
        _ = try await execute(query: DuckDBSchemaQueries.useSchema(schema, in: currentDatabase))
        stateLock.withLock { _currentSchema = schema }
        await refreshSessionSetup()
    }

    // MARK: - Database Operations

    /// `USE` on a catalog also moves the connection onto that catalog's default schema, so
    /// the tracked schema has to follow or the next `pin` skips a switch it still needs.
    /// The new schema is read back rather than assumed to be `main`: a catalog attached
    /// through the postgres or mysql scanner defaults to that engine's own schema.
    /// The name is canonicalised against `duckdb_databases()` rather than stored as typed.
    /// DuckDB resolves a catalog case-insensitively, so `USE "FIXTURE"` moves to `fixture`
    /// and writes `FIXTURE.main` into `search_path`, but `duckdb_tables()` compares
    /// `database_name` exactly: every metadata query would then filter on `FIXTURE` and
    /// return nothing, which is an empty sidebar on a connection that switched fine.
    ///
    /// The reads run before the state is committed and each falls back rather than throwing.
    /// The `USE` has already moved the connection by then, so an early return would leave the
    /// tracked catalog pointing at the database the connection just left.
    func switchDatabase(to database: String) async throws {
        _ = try await execute(query: DuckDBSchemaQueries.useDatabase(database))
        let canonical = await canonicalCatalogName(matching: database) ?? database
        let landedSchema = try? await readPosition().schema
        stateLock.withLock {
            _currentDatabase = canonical
            _currentSchema = landedSchema.flatMap { $0 } ?? "main"
        }
        await refreshSessionSetup()
    }

    private func canonicalCatalogName(matching database: String) async -> String? {
        guard let result = try? await execute(query: DuckDBSchemaQueries.listDatabases) else { return nil }
        let names = result.rows.compactMap { $0[safe: 0]?.asText }
        return names.first { $0 == database } ?? names.first { $0.lowercased() == database.lowercased() }
    }

    func fetchDatabases() async throws -> [String] {
        if let remoteAlias {
            return [remoteAlias]
        }
        let result = try await execute(query: DuckDBSchemaQueries.listDatabases)
        return result.rows.compactMap { row in
            row[safe: 0]?.asText
        }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN \(sql)"
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "CREATE OR REPLACE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        let quoted = quoteIdentifier(viewName)
        return "CREATE OR REPLACE VIEW \(quoted) AS\nSELECT * FROM table_name;"
    }

    // MARK: - All Tables Metadata

    /// The app hands this an already escaped schema literal, so it is passed through rather
    /// than escaped a second time.
    func allTablesMetadataSQL(schema: String?) -> String? {
        guard let catalog = currentDatabase?.nilIfEmpty else { return nil }
        let escapedSchema = schema ?? escapeStringLiteral(currentSchema ?? "main")
        return DuckDBSchemaQueries.allTablesMetadata(catalog: catalog, escapedSchema: escapedSchema)
    }

    // MARK: - Private Helpers

    private func expandPath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return NSString(string: path).expandingTildeInPath
        }
        return path
    }

    // MARK: - Create Table DDL

    func generateCreateTableStatements(definition: PluginCreateTableDefinition, schema: String?) -> [String]? {
        duckdbCreateTableStatements(definition: definition, schema: resolveSchema(schema), quote: quoteIdentifier)
    }

    func schemaOperationRefusal(_ operation: PluginSchemaOperation) -> String? {
        switch operation {
        case .addColumn(let column):
            if column.autoIncrement, let defaultValue = column.defaultValue,
               !defaultValue.trimmingCharacters(in: .whitespaces).isEmpty {
                return String(localized: "An auto-increment column takes its values from a sequence, so it cannot also have a default.")
            }
            return duckdbColumnTextRefusal(for: column)
        case .modifyColumn(_, let column):
            return duckdbColumnTextRefusal(for: column)
        case .addIndex(let index):
            return duckdbIndexExpressionRefusal(for: index)
        default:
            return nil
        }
    }

    private func qualifiedTableName(_ table: String, schema: String?) -> String {
        "\(quoteIdentifier(resolveSchema(schema))).\(quoteIdentifier(table))"
    }

    // MARK: - ALTER TABLE DDL

    // One statement only; an auto-increment column needs its sequence created first, so it is unsupported here.
    func generateAddColumnSQL(table: String, schema: String?, column: PluginColumnDefinition) -> String? {
        guard !column.autoIncrement, duckdbColumnTextRefusal(for: column) == nil else { return nil }
        let colDef = duckdbColumnDefinition(
            column, schema: resolveSchema(schema), table: table, inlinePK: false, inCreateTable: false, quote: quoteIdentifier
        )
        return "ALTER TABLE \(qualifiedTableName(table, schema: schema)) ADD COLUMN \(colDef)"
    }

    func generateModifyColumnSQL(
        table: String,
        schema: String?,
        oldColumn: PluginColumnDefinition,
        newColumn: PluginColumnDefinition
    ) -> String? {
        guard duckdbColumnTextRefusal(for: newColumn) == nil else { return nil }
        let qt = qualifiedTableName(table, schema: schema)
        var stmts: [String] = []

        if oldColumn.name != newColumn.name {
            stmts.append("ALTER TABLE \(qt) RENAME COLUMN \(quoteIdentifier(oldColumn.name)) TO \(quoteIdentifier(newColumn.name))")
        }

        let colName = quoteIdentifier(newColumn.name)

        if oldColumn.dataType.uppercased() != newColumn.dataType.uppercased() {
            stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) TYPE \(newColumn.dataType)")
        }

        if oldColumn.isNullable != newColumn.isNullable {
            let clause = newColumn.isNullable ? "DROP NOT NULL" : "SET NOT NULL"
            stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) \(clause)")
        }

        if oldColumn.defaultValue != newColumn.defaultValue {
            if let defaultValue = newColumn.defaultValue {
                stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) SET DEFAULT \(defaultValue)")
            } else {
                stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) DROP DEFAULT")
            }
        }

        return stmts.isEmpty ? nil : stmts.joined(separator: ";\n")
    }

    func generateDropColumnSQL(table: String, schema: String?, columnName: String) -> String? {
        "ALTER TABLE \(qualifiedTableName(table, schema: schema)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    func generateAddIndexSQL(table: String, schema: String?, index: PluginIndexDefinition) -> String? {
        guard duckdbIndexExpressionRefusal(for: index) == nil else { return nil }
        return DuckDBIndexClauses.createStatement(
            for: index, qualifiedTable: qualifiedTableName(table, schema: schema), quote: quoteIdentifier
        )
    }

    func generateDropIndexSQL(table: String, schema: String?, indexName: String) -> String? {
        "DROP INDEX \(quoteIdentifier(resolveSchema(schema))).\(quoteIdentifier(indexName))"
    }

    func generateAddForeignKeySQL(table: String, schema: String?, fk: PluginForeignKeyDefinition) -> String? {
        duckdbForeignKeyDefinition(fk, quote: quoteIdentifier).map {
            "ALTER TABLE \(qualifiedTableName(table, schema: schema)) ADD \($0)"
        }
    }

    func generateDropForeignKeySQL(table: String, schema: String?, constraintName: String) -> String? {
        "ALTER TABLE \(qualifiedTableName(table, schema: schema)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
    }

    func generateModifyPrimaryKeySQL(
        table: String,
        schema: String?,
        oldColumns: [String],
        newColumns: [String],
        constraintName: String?
    ) -> [String]? {
        let qt = qualifiedTableName(table, schema: schema)
        var stmts: [String] = []
        if !oldColumns.isEmpty {
            let name = constraintName.map { quoteIdentifier($0) } ?? "/* unknown constraint */"
            stmts.append("ALTER TABLE \(qt) DROP CONSTRAINT \(name)")
        }
        if !newColumns.isEmpty {
            let cols = newColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
            stmts.append("ALTER TABLE \(qt) ADD PRIMARY KEY (\(cols))")
        }
        return stmts.isEmpty ? nil : stmts
    }
}

// The pull side of a read handed out a batch at a time. A stream dropped before its end gives the read up.
nonisolated private final class DuckDBPulledRows<Value: Sendable>: @unchecked Sendable {
    private let actor: DuckDBConnectionActor
    private let query: String
    private let reason: DuckDBReadOnlyStatement.Reason?
    private let live: DuckDBLiveConnectionBox
    private let read: DuckDBValueReader<Value>
    private let lock = NSLock()
    private var generation: UInt64?
    private var ended = false

    init(
        actor: DuckDBConnectionActor,
        query: String,
        reason: DuckDBReadOnlyStatement.Reason?,
        live: DuckDBLiveConnectionBox,
        read: @escaping DuckDBValueReader<Value>
    ) {
        self.actor = actor
        self.query = query
        self.reason = reason
        self.live = live
        self.read = read
    }

    deinit {
        let open = lock.withLock { ended ? nil : generation }
        guard let open else { return }
        let actor = actor
        Task { await actor.endPulledRead(open) }
    }

    func next() async throws -> DuckDBPulledElement<Value>? {
        let actor = actor
        let live = live
        let read = read
        do {
            return try await withTaskCancellationHandler {
                if let current = lock.withLock({ generation }) {
                    guard let rows = try await actor.nextPulledBatch(current, reading: read) else {
                        markEnded()
                        return nil
                    }
                    return .rows(rows)
                }
                let begun = try await actor.beginPulledRead(query, reason: reason)
                lock.withLock { generation = begun.generation }
                return .header(begun.header)
            } onCancel: {
                live.interrupt()
            }
        } catch {
            markEnded()
            throw error
        }
    }

    private func markEnded() {
        lock.withLock { ended = true }
    }
}
