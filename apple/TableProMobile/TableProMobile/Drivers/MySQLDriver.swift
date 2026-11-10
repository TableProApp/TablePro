import CMariaDB
import Foundation
import os
import TableProCoreTypes
import TableProDatabase
import TableProModels
import TableProMSSQLCore
import TableProMySQLCore
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLQuoting

nonisolated final class MySQLDriver: DatabaseDriver, @unchecked Sendable {
    private let actor = MySQLActor()
    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    private let database: String
    let ssl: DriverSSLConfiguration
    let databaseType: DatabaseType
    private let connectionEncoding: MySQLConnectionEncoding
    let signsInWithToken: Bool
    let queryTimeoutSeconds: Int?
    // None without a query timeout: Connector/C reports its own read timeout as a lost connection while the server
    // runs the statement to the end, so it only backs up a limit the server enforces. The keepalive fails a dead path.
    let socketTimeoutSeconds: UInt32
    // A kill signs in anew, which an IAM token minted more than 15 minutes ago cannot, as on the Mac.
    private let refreshPassword: (@Sendable () async throws -> String?)?
    private let clock: any Clock<Duration>

    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    var supportsTransactions: Bool { true }

    private let settledFacts = OSAllocatedUnfairLock<SQLSessionLexicalFacts?>(initialState: nil)

    var settledLexicalFacts: SQLSessionLexicalFacts? {
        settledFacts.withLock { $0 }
    }

    func escapeStringLiteral(_ value: String) -> String {
        SQLQuoting.stringLiteralBody(value, escapes: literalEscapes)
    }

    private var literalEscapes: SQLStringEscapes {
        Self.stringEscapes(
            for: databaseType,
            session: settledLexicalFacts,
            isDatabend: Self.serverFlavor(for: databaseType, banner: serverVersion).isDatabend
        )
    }

    // Set once during connect(), before the driver is shared, so concurrent reads are safe.
    nonisolated(unsafe) private(set) var serverVersion: String?

    init(
        host: String,
        port: Int,
        user: String,
        password: String,
        database: String,
        ssl: DriverSSLConfiguration = .disabled,
        databaseType: DatabaseType = .mysql,
        connectionEncoding: MySQLConnectionEncoding = .utf8,
        signsInWithToken: Bool = false,
        queryTimeoutSeconds: Int? = nil,
        refreshPassword: (@Sendable () async throws -> String?)? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.ssl = ssl
        self.databaseType = databaseType
        self.connectionEncoding = connectionEncoding
        self.signsInWithToken = signsInWithToken
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.socketTimeoutSeconds = mysqlSocketTimeoutSeconds(forQueryTimeout: queryTimeoutSeconds ?? 0)
        self.refreshPassword = refreshPassword
        self.clock = clock
    }

    // MARK: - Connection

    private static let logger = Logger(subsystem: "com.TablePro", category: "MySQLDriver")

    // OceanBase stops a statement after 10 s by default, so a session without a query timeout lifts that limit.
    static func sessionSetupStatements(
        for databaseType: DatabaseType,
        banner: String? = nil,
        queryTimeoutSeconds: Int? = nil
    ) -> [String] {
        if let queryTimeoutSeconds, queryTimeoutSeconds > 0 {
            return serverFlavor(for: databaseType, banner: banner).queryTimeoutStatements(seconds: queryTimeoutSeconds)
        }
        guard databaseType == .oceanbase else { return [] }
        return MySQLServerFlavor.oceanbase(version: nil).queryTimeoutStatements(seconds: 0)
    }

    static func serverFlavor(for databaseType: DatabaseType, banner: String?) -> MySQLServerFlavor {
        switch databaseType {
        case .tidb:
            return .tidb(version: banner.flatMap(MySQLServerFlavor.tidbVersion(fromBanner:)))
        case .oceanbase:
            return .oceanbase(version: banner.flatMap(MySQLServerFlavor.oceanbaseVersion(fromServerVersion:)))
        default:
            return MySQLServerFlavor.fromBanner(banner)
        }
    }

    // A database names another one's tables, as `otherdb.` in the editor does; nil reads the session's.
    static func tableListStatement(for databaseType: DatabaseType, banner: String?, database: String? = nil) -> String {
        let flavor = serverFlavor(for: databaseType, banner: banner)
        let full = MySQLServerVersion.hasInformationSchema(banner: banner, flavor: flavor)
        let statement = full ? "SHOW FULL TABLES" : "SHOW TABLES"
        guard let database, !database.isEmpty else { return statement }
        return "\(statement) FROM \(quotedIdentifier(database))"
    }

    static func readsForeignKeyCatalog(for databaseType: DatabaseType, banner: String?) -> Bool {
        MySQLServerVersion.hasReferentialConstraintsCatalog(
            banner: banner, flavor: serverFlavor(for: databaseType, banner: banner)
        )
    }

    static func labelsShowTextAsBinary(for databaseType: DatabaseType, banner: String?) -> Bool {
        MySQLServerVersion.labelsShowTextAsBinary(
            banner: banner, flavor: serverFlavor(for: databaseType, banner: banner)
        )
    }

    func connect() async throws {
        try await LocalNetworkPermission.shared.ensureAccess(for: host)
        try await actor.connect(
            host: host, port: port, user: user, password: password, database: database,
            ssl: ssl, encoding: connectionEncoding, databaseType: databaseType,
            signsInWithToken: signsInWithToken,
            signIn: MySQLKillSignIn(password: password, refresh: refreshPassword, clock: clock)
        )
        serverVersion = await actor.serverVersion()
        let setup = Self.sessionSetupStatements(
            for: databaseType, banner: serverVersion, queryTimeoutSeconds: queryTimeoutSeconds
        )
        // A server that refuses the limit still runs queries, as on the Mac.
        for statement in setup {
            do {
                _ = try await actor.execute(statement)
            } catch {
                Self.logger.warning(
                    "Session setup failed with \(statement, privacy: .private): \(error.localizedDescription, privacy: .private)"
                )
                break
            }
        }
        try await actor.completeConnect(socketTimeoutSeconds: socketTimeoutSeconds)
        await settleLexicalFacts()
    }

    func disconnect() async throws {
        await actor.close()
    }

    func ping() async throws -> Bool {
        try await actor.ping()
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        let raw = try await actor.execute(query)
        await settleLexicalFacts()
        return QueryResult(
            columns: raw.columns.enumerated().map { i, name in
                ColumnInfo(
                    name: name,
                    typeName: i < raw.columnTypes.count ? raw.columnTypes[i] : "",
                    isPrimaryKey: false,
                    isNullable: true,
                    defaultValue: nil,
                    comment: nil,
                    characterMaxLength: nil,
                    ordinalPosition: i
                )
            },
            rows: raw.rows,
            rowsAffected: raw.rowsAffected,
            executionTime: raw.executionTime,
            isTruncated: raw.isTruncated,
            statusMessage: nil
        )
    }

    // Runs without the actor, which stays blocked in Connector/C for as long as the statement runs. The editor's Stop
    // leaves its stream first, so this stops only a statement whose reader is gone.
    func cancelCurrentQuery() async throws {
        actor.killer.stop()
    }

    // The statement is reserved before the producer starts, so a reader that leaves names this stream's statement and
    // never another surface's.
    func executeStreaming(query: String, options: StreamOptions) -> AsyncThrowingStream<StreamElement, Error> {
        let actor = self.actor
        let killer = actor.killer
        let statement = killer.reserve()
        return AsyncThrowingStream { continuation in
            let task = Task {
                var openStream: MySQLStreamID?
                do {
                    switch try await actor.beginStream(query: query, statement: statement) {
                    case .noResult(let affectedRows):
                        if affectedRows != 0 {
                            continuation.yield(.rowsAffected(affectedRows))
                        }
                    case .rowSet(let stream, let columns):
                        openStream = stream
                        continuation.yield(.columns(columns))
                        var emitted = 0
                        while !Task.isCancelled, emitted < options.maxRows {
                            guard let cells = try await actor.fetchNextRow(
                                stream, options: options, columns: columns
                            ) else {
                                break
                            }
                            continuation.yield(.row(Row(cells: cells)))
                            emitted += 1
                        }
                        if Task.isCancelled {
                            continuation.yield(.truncated(reason: .cancelled))
                        } else if emitted >= options.maxRows {
                            continuation.yield(.truncated(reason: .rowCap(options.maxRows)))
                        }
                        openStream = nil
                        try await actor.endStream(stream)
                    }
                    await self.settleLexicalFacts()
                    continuation.finish()
                } catch is CancellationError {
                    if let openStream { try? await actor.endStream(openStream) }
                    continuation.yield(.truncated(reason: .cancelled))
                    continuation.finish()
                } catch {
                    // The statement already failed with `error`; releasing its result cannot add a second one.
                    if let openStream { try? await actor.endStream(openStream) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason {
                    killer.readerLeft(statement)
                }
            }
        }
    }

    // MARK: - Schema

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let raw = try await actor.execute(
            Self.tableListStatement(for: databaseType, banner: serverVersion, database: schema)
        )
        return MySQLTableListing.tables(fromShowTables: raw.rows, databaseType: databaseType)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let raw = try await actor.execute(Self.showFullColumnsStatement(table: table, database: schema))
        let source = MySQLColumnListing.defaultSource(
            flavor: Self.serverFlavor(for: databaseType, banner: serverVersion),
            banner: serverVersion
        )
        let catalog = await catalogDefaults(table: table, database: schema, source: source)
        return MySQLColumnListing.columns(fromShowFullColumns: raw.rows, catalogDefaults: catalog, source: source)
    }

    // A catalog that refuses leaves the defaults SHOW FULL COLUMNS reported, as on the Mac.
    private func catalogDefaults(
        table: String,
        database: String?,
        source: MySQLColumnListing.DefaultSource
    ) async -> [String: MySQLCatalogDefault] {
        guard let query = MySQLColumnListing.catalogDefaultsQuery(
            table: table, database: database, source: source, escapes: literalEscapes
        ) else {
            return [:]
        }
        do {
            let raw = try await actor.execute(query)
            return MySQLColumnListing.catalogDefaults(fromRows: raw.rows, source: source)
        } catch {
            Self.logger.warning(
                "Column default catalog read failed: \(error.localizedDescription, privacy: .private)"
            )
            return [:]
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] {
        let raw = try await actor.execute(Self.showIndexStatement(table: table, database: schema))

        var indexMap: [String: (isUnique: Bool, isPrimary: Bool, columns: [String])] = [:]
        var order: [String] = []

        for row in raw.rows {
            guard row.count >= 5, let keyName = row[2], let colName = row[4] else { continue }
            if indexMap[keyName] == nil {
                indexMap[keyName] = (
                    isUnique: row[1] == "0",
                    isPrimary: keyName == "PRIMARY",
                    columns: []
                )
                order.append(keyName)
            }
            indexMap[keyName]?.columns.append(colName)
        }

        return order.compactMap { name in
            guard let entry = indexMap[name] else { return nil }
            return IndexInfo(
                name: name,
                columns: entry.columns,
                isUnique: entry.isUnique,
                isPrimary: entry.isPrimary,
                type: "BTREE"
            )
        }
    }

    // Below 5.1.10 there is no REFERENTIAL_CONSTRAINTS. Failing there would also drop the columns and
    // indexes loaded with the keys, so those servers read SHOW CREATE TABLE, as on the Mac.
    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        guard Self.readsForeignKeyCatalog(for: databaseType, banner: serverVersion) else {
            return try await declaredForeignKeys(table: table, database: schema)
        }
        let raw = try await actor.execute(
            Self.foreignKeyCatalogQuery(table: table, database: schema, escapes: literalEscapes)
        )
        return Self.foreignKeys(fromCatalogRows: raw.rows)
    }

    private func declaredForeignKeys(table: String, database: String?) async throws -> [ForeignKeyInfo] {
        let raw = try await actor.execute(Self.showCreateTableStatement(table: table, database: database))
        guard let row = raw.rows.first, row.count > 1, let ddl = row[1] else { return [] }
        let omittedAction = MySQLServerVersion.omittedForeignKeyAction(
            banner: serverVersion,
            flavor: Self.serverFlavor(for: databaseType, banner: serverVersion)
        )
        return Self.foreignKeys(declaredIn: ddl, database: database, omittedAction: omittedAction)
    }

    func fetchDatabases() async throws -> [String] {
        let raw = try await actor.execute("SHOW DATABASES")
        return raw.rows.compactMap { $0.first ?? nil }
    }

    func switchDatabase(to name: String) async throws {
        _ = try await actor.execute("USE \(Self.quotedIdentifier(name))")
    }

    func switchSchema(to name: String) async throws {
        throw MySQLError.unsupported("MySQL does not support schemas")
    }

    func fetchSchemas() async throws -> [String] { [] }

    func beginTransaction() async throws {
        try await beginTransaction(mode: .serverDefault)
    }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        let flavor = Self.serverFlavor(for: databaseType, banner: serverVersion)
        _ = try await actor.execute(flavor.beginTransactionStatement(mode: mode))
    }

    func commitTransaction() async throws {
        _ = try await actor.execute("COMMIT")
    }

    func rollbackTransaction() async throws {
        _ = try await actor.execute("ROLLBACK")
    }

    func sessionTransactionState() async -> DriverTransactionState {
        guard Self.reportsSessionStatusFlags(for: databaseType, banner: serverVersion) else { return .unknown }
        return await actor.transactionState()
    }

    static func reportsSessionStatusFlags(for databaseType: DatabaseType, banner: String?) -> Bool {
        serverFlavor(for: databaseType, banner: banner).reportsSessionStatusFlags
    }

    /// Databend reports no `NO_BACKSLASH_ESCAPES` flag, so its session says nothing.
    func sessionLexicalFacts() async -> SQLSessionLexicalFacts? {
        guard !Self.serverFlavor(for: databaseType, banner: serverVersion).isDatabend else { return nil }
        return await actor.lexicalFacts()
    }

    // NO_BACKSLASH_ESCAPES rides on every reply's status flags, so a `SET sql_mode` is read once it has run.
    private func settleLexicalFacts() async {
        let facts = await sessionLexicalFacts()
        settledFacts.withLock { $0 = facts }
    }

    // `.mysql` keeps a NUL and 0x1A as MySQL's own escapes; Databend is not known to decode `\Z`.
    static func stringEscapes(
        for databaseType: DatabaseType,
        session: SQLSessionLexicalFacts?,
        isDatabend: Bool
    ) -> SQLStringEscapes {
        let escapes = SQLLexicalReadings.stringEscapes(databaseTypeId: databaseType.rawValue, declared: nil, session: session)
        return escapes == .backslash && !isDatabend ? .mysql : escapes
    }

    // Kept text declares no sql_mode, so it is written for a session that has not settled the backslash rule.
    static func keptTextEscapes(for databaseType: DatabaseType, banner: String?) -> SQLStringEscapes {
        stringEscapes(for: databaseType, session: nil, isDatabend: serverFlavor(for: databaseType, banner: banner).isDatabend)
    }
}

nonisolated enum MySQLTokenSignIn {
    // A token session refuses a server without TLS before the token is sent; this names that refusal.
    static func connectFailure(
        signsInWithToken: Bool,
        errorCode: UInt32,
        serverCapabilities: UInt
    ) -> IAMSignInError? {
        guard signsInWithToken,
              errorCode == UInt32(CR_SSL_CONNECTION_ERROR),
              serverCapabilities & UInt(CLIENT_SSL) == 0 else { return nil }
        return .encryptionNotEstablished
    }
}

// The SSL mode as Connector/C options. MYSQL_OPT_SSL_ENFORCE alone falls back to plaintext when the
// server offers no TLS (mariadb_lib.c:3643, my_auth.c:319-338), so only Preferred is left with that.
nonisolated enum MySQLTLSPolicy: Equatable, Sendable {
    case disabled
    case preferred
    case required
    case verifyChain
    case verifyIdentity

    init(_ ssl: DriverSSLConfiguration, signsInWithToken: Bool = false) {
        // A token is never sent in plaintext.
        switch ssl.mode {
        case .disable:
            self = signsInWithToken ? .required : .disabled
        case .require:
            self = ssl.isPreferred && !signsInWithToken ? .preferred : .required
        case .verifyCa:
            self = .verifyChain
        case .verifyFull:
            self = .verifyIdentity
        }
    }

    func apply(to handle: UnsafeMutablePointer<MYSQL>, ssl: DriverSSLConfiguration, serverName: MySQLTLSServerName?) {
        switch self {
        case .disabled, .preferred:
            var enforce: my_bool = self == .preferred ? 1 : 0
            var verify: my_bool = 0
            mysql_options(handle, MYSQL_OPT_SSL_ENFORCE, &enforce)
            mysql_options(handle, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &verify)
        case .required:
            tablepro_mysql_require_tls_without_verification(handle)
        case .verifyChain:
            tablepro_mysql_require_trusted_chain(handle)
        case .verifyIdentity:
            tablepro_mysql_require_server_identity(handle)
        }
        // Connector/C turns TLS on for any CA, certificate or key it is given (my_auth.c:396-407).
        guard self != .disabled else { return }
        if let serverName {
            tablepro_mysql_set_tunneled_server_name(handle, serverName.pointer)
        }
        if let caPath = ssl.existingCACertificatePath {
            _ = caPath.withCString { mysql_options(handle, MYSQL_OPT_SSL_CA, $0) }
        }
        if let clientCertPath = ssl.existingClientCertificatePath {
            _ = clientCertPath.withCString { mysql_options(handle, MYSQL_OPT_SSL_CERT, $0) }
        }
        if let clientKeyPath = ssl.existingClientKeyPath {
            _ = clientKeyPath.withCString { mysql_options(handle, MYSQL_OPT_SSL_KEY, $0) }
        }
    }
}

// What every connection to the server is opened with, so the one that sends a kill signs in the way the session did.
nonisolated enum MySQLDialOptions {
    static func apply(
        to handle: UnsafeMutablePointer<MYSQL>,
        policy: MySQLTLSPolicy,
        ssl: DriverSSLConfiguration,
        serverName: MySQLTLSServerName?,
        signsInWithToken: Bool,
        connectSeconds: UInt32,
        socketSeconds: UInt32
    ) {
        mysql_options(handle, MYSQL_SET_CHARSET_NAME, MySQLConnectionEncoding.sessionCharacterSetName)

        var connectTimeout = connectSeconds
        mysql_options(handle, MYSQL_OPT_CONNECT_TIMEOUT, &connectTimeout)
        var readTimeout = socketSeconds
        mysql_options(handle, MYSQL_OPT_READ_TIMEOUT, &readTimeout)
        var writeTimeout = socketSeconds
        mysql_options(handle, MYSQL_OPT_WRITE_TIMEOUT, &writeTimeout)

        var reconnect: my_bool = 0
        mysql_options(handle, MYSQL_OPT_RECONNECT, &reconnect)

        var allowLocalInfile: UInt32 = 0
        mysql_options(handle, MYSQL_OPT_LOCAL_INFILE, &allowLocalInfile)

        policy.apply(to: handle, ssl: ssl, serverName: serverName)
        if policy == .disabled || policy == .preferred {
            _ = MySQLPlaintextPassword.methodsWithoutTLS.withCString {
                mysql_options(handle, MARIADB_OPT_RESTRICTED_AUTH, $0)
            }
        }
        if signsInWithToken {
            // A no-op in Connector/C 3.4, which answers a cleartext request anyway; set to match the Mac.
            var enableCleartext: my_bool = 1
            mysql_options(handle, MYSQL_ENABLE_CLEARTEXT_PLUGIN, &enableCleartext)
        }
    }
}

// The name a tunneled connection's certificate must carry, as a C string the TLS callback reads
// during the handshake.
nonisolated final class MySQLTLSServerName: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<CChar>

    init?(policy: MySQLTLSPolicy, ssl: DriverSSLConfiguration) {
        guard policy == .verifyChain || policy == .verifyIdentity,
              let name = ssl.serverName, !name.isEmpty,
              let copy = strdup(name) else { return nil }
        pointer = copy
    }

    deinit {
        free(pointer)
    }
}

nonisolated extension MySQLDriver {
    static func showFullColumnsStatement(table: String, database: String?) -> String {
        "SHOW FULL COLUMNS FROM \(qualifiedTable(table, database: database))"
    }

    static func showIndexStatement(table: String, database: String?) -> String {
        "SHOW INDEX FROM \(qualifiedTable(table, database: database))"
    }

    static func showCreateTableStatement(table: String, database: String?) -> String {
        "SHOW CREATE TABLE \(qualifiedTable(table, database: database))"
    }

    // Nil reads the session's database, which the last USE set. The one the driver connected with
    // goes stale after a switch.
    static func databaseLiteral(_ database: String?, escapes: SQLStringEscapes = .mysql) -> String {
        guard let database, !database.isEmpty else { return "DATABASE()" }
        return SQLQuoting.stringLiteral(database, escapes: escapes)
    }

    static func foreignKeyCatalogQuery(table: String, database: String?, escapes: SQLStringEscapes = .mysql) -> String {
        """
        SELECT
            kcu.CONSTRAINT_NAME,
            kcu.COLUMN_NAME,
            kcu.REFERENCED_TABLE_NAME,
            kcu.REFERENCED_COLUMN_NAME,
            rc.DELETE_RULE,
            rc.UPDATE_RULE,
            kcu.TABLE_SCHEMA,
            kcu.REFERENCED_TABLE_SCHEMA
        FROM information_schema.KEY_COLUMN_USAGE kcu
        JOIN information_schema.REFERENTIAL_CONSTRAINTS rc
            ON kcu.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
            AND kcu.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
        WHERE kcu.TABLE_SCHEMA = \(databaseLiteral(database, escapes: escapes))
            AND kcu.TABLE_NAME = \(SQLQuoting.stringLiteral(table, escapes: escapes))
            AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
        ORDER BY kcu.CONSTRAINT_NAME, kcu.ORDINAL_POSITION
        """
    }

    static func foreignKeys(fromCatalogRows rows: [[String?]]) -> [ForeignKeyInfo] {
        rows.compactMap { row in
            guard row.count >= 8,
                  let name = row[0],
                  let column = row[1],
                  let refTable = row[2],
                  let refColumn = row[3] else { return nil }
            return ForeignKeyInfo(
                name: name,
                column: column,
                referencedTable: refTable,
                referencedColumn: refColumn,
                referencedSchema: row[7] == row[6] ? nil : row[7],
                onDelete: row[4] ?? "NO ACTION",
                onUpdate: row[5] ?? "NO ACTION"
            )
        }
    }

    // The parser fills the source database into every unqualified key. Nil keeps a same-database key
    // the same as the catalog read gives it.
    static func foreignKeys(declaredIn createTable: String, database: String?, omittedAction: String) -> [ForeignKeyInfo] {
        MySQLForeignKeyClause.parse(createTable: createTable, database: database ?? "", omittedAction: omittedAction)
            .map { key in
                ForeignKeyInfo(
                    name: key.name,
                    column: key.column,
                    referencedTable: key.referencedTable,
                    referencedColumn: key.referencedColumn,
                    referencedSchema: key.referencedSchema == database ? nil : key.referencedSchema,
                    onDelete: key.onDelete,
                    onUpdate: key.onUpdate
                )
            }
    }

    private static func qualifiedTable(_ table: String, database: String?) -> String {
        let name = quotedIdentifier(table)
        guard let database, !database.isEmpty else { return name }
        return "\(quotedIdentifier(database)).\(name)"
    }

    private static func quotedIdentifier(_ name: String) -> String {
        SQLQuoting.identifier(name, quote: .backtick)
    }
}

nonisolated enum MySQLSessionTransaction {
    static func state(infoResult: my_bool, serverStatus: UInt32) -> DriverTransactionState {
        guard infoResult == 0 else { return .unknown }
        guard serverStatus & UInt32(SERVER_STATUS_IN_TRANS) != 0 else { return .idle }
        return serverStatus & UInt32(SERVER_STATUS_AUTOCOMMIT) != 0 ? .explicitTransaction : .implicitTransaction
    }
}

// MARK: - MySQL Actor (thread-safe C API access)

private actor MySQLActor {
    nonisolated let killer = MySQLStatementKiller()
    private var mysql: UnsafeMutablePointer<MYSQL>?

    private static let connectSeconds = 15
    // Bounds the sign-in and the setup statements after it; `completeConnect` gives the session its own.
    private static let signInSocketSeconds: UInt32 = 30
    private static let connectionLossCodes: Set<UInt32> = [
        UInt32(CR_SERVER_GONE_ERROR), UInt32(CR_SERVER_LOST), UInt32(CR_SERVER_LOST_EXTENDED)
    ]

    private var encoding: MySQLConnectionEncoding = .utf8
    private var errorLanguage: String.Encoding?
    private var showTextIsBinary = false
    private var tlsServerName: MySQLTLSServerName?
    private var flavor: MySQLServerFlavor = .mysql
    // The read timeout the socket has now: the sign-in's until `completeConnect`.
    private var socketTimeoutSeconds: UInt32 = 0

    private struct AttemptFailure: Error {
        let code: UInt32
        let message: String
        let serverCapabilities: UInt
    }

    func connect(
        host: String, port: Int, user: String, password: String, database: String,
        ssl: DriverSSLConfiguration, encoding: MySQLConnectionEncoding, databaseType: DatabaseType,
        signsInWithToken: Bool, signIn: MySQLKillSignIn
    ) async throws {
        self.encoding = encoding
        errorLanguage = nil
        showTextIsBinary = false
        close()
        socketTimeoutSeconds = Self.signInSocketSeconds

        guard let portU32 = UInt32(exactly: port), (1...65_535).contains(port) else {
            throw MySQLError.connectionFailed(
                "Port \(port) is out of range. Use a value between 1 and 65535."
            )
        }

        let policy = MySQLTLSPolicy(ssl, signsInWithToken: signsInWithToken)
        let serverName = MySQLTLSServerName(policy: policy, ssl: ssl)
        let deadline = DispatchTime.now() + .seconds(Self.connectSeconds)
        let endpoint = Endpoint(
            host: host, port: portU32, user: user, password: password, database: database,
            signsInWithToken: signsInWithToken
        )
        // Connector/C 3.4.4 takes a requested TLS for an established one and answers caching_sha2_password's full
        // authentication with the typed password, so Preferred asks for TLS outright and falls back without it.
        let firstPolicy: MySQLTLSPolicy = policy == .preferred ? .required : policy
        let handle: UnsafeMutablePointer<MYSQL>
        var dialedPolicy = firstPolicy
        do {
            do {
                handle = try await open(endpoint, ssl: ssl, policy: firstPolicy, serverName: serverName, deadline: deadline)
            } catch let failure as AttemptFailure
                where policy == .preferred && MariaDBSSLClassifier.sslOnlyErrorCodes.contains(failure.code) {
                // Preferred retries in plaintext after a failed handshake, as the Mac does.
                dialedPolicy = .disabled
                handle = try await open(endpoint, ssl: ssl, policy: .disabled, serverName: nil, deadline: deadline)
            }
        } catch let failure as AttemptFailure where MySQLPlaintextPassword.isRefusal(code: failure.code) {
            throw MySQLError.connectionFailed(MySQLPlaintextPassword.refusalMessage)
        } catch let failure as AttemptFailure {
            if let tokenFailure = MySQLTokenSignIn.connectFailure(
                signsInWithToken: signsInWithToken,
                errorCode: failure.code,
                serverCapabilities: failure.serverCapabilities
            ) {
                throw tokenFailure
            }
            throw MariaDBSSLClassifier.classifySSLError(code: failure.code, message: failure.message)
                ?? MySQLError.connectionFailed(failure.message)
        }

        guard MariaDBCharacterSet.establishSession(on: handle, encoding: encoding) else {
            let msg = message(from: handle)
            mysql_close(handle)
            throw MySQLError.connectionFailed(msg)
        }

        let banner = mysql_get_server_info(handle).map { String(cString: $0) }
        let sessionFlavor = MySQLDriver.serverFlavor(for: databaseType, banner: banner)
        // TiDB's handshake carries only the low 32 bits of its connection id.
        let tidbConnectionId = sessionFlavor.isTiDB ? connectionIdentifier(on: handle) : nil

        showTextIsBinary = MySQLDriver.labelsShowTextAsBinary(for: databaseType, banner: banner)
        errorLanguage = MariaDBCharacterSet.errorLanguage(on: handle)
        tlsServerName = serverName
        flavor = sessionFlavor
        self.mysql = handle

        let dial = MySQLKillDial(
            host: endpoint.host, port: endpoint.port, user: endpoint.user, signIn: signIn,
            ssl: ssl, policy: dialedPolicy, serverName: dialedPolicy == .disabled ? nil : serverName,
            signsInWithToken: signsInWithToken
        )
        killer.attach(MySQLKillStatement.text(
            flavor: sessionFlavor, banner: banner, threadId: mysql_thread_id(handle), tidbConnectionId: tidbConnectionId
        ).map { statement in
            MySQLSessionKill(
                statement: statement,
                absorbsLatchedKill: MySQLKillStatement.absorbsLatchedKill(flavor: sessionFlavor),
                killsWhenReaderLeaves: !sessionFlavor.dropsIdleSessionOnKillQuery,
                dial: dial
            )
        })
    }

    // Last, as the Mac's completeConnect: the sign-in's reads and the setup statements after it keep its bound, so a
    // server that stops answering right after the sign-in still fails the connect.
    func completeConnect(socketTimeoutSeconds sessionTimeout: UInt32) throws {
        guard let mysql else { throw MySQLError.notConnected }
        guard tablepro_mysql_set_io_timeout(mysql, sessionTimeout) == 0,
              SessionSocketKeepalive.enable(on: mysql_get_socket(mysql)) else {
            close()
            throw MySQLError.connectionFailed(String(localized: "Failed to configure the connection timeout"))
        }
        socketTimeoutSeconds = sessionTimeout
    }

    private func connectionIdentifier(on handle: UnsafeMutablePointer<MYSQL>) -> UInt64? {
        let probe = MySQLFlavorResolution.connectionIdentifierProbe
        guard mysql_real_query(handle, probe, UInt(probe.utf8.count)) == 0,
              let result = mysql_store_result(handle) else { return nil }
        defer { mysql_free_result(result) }
        guard let row = mysql_fetch_row(result), let value = row[0] else { return nil }
        return UInt64(String(cString: value))
    }

    private struct Endpoint: Sendable {
        let host: String
        let port: UInt32
        let user: String
        let password: String
        let database: String
        let signsInWithToken: Bool
    }

    private func open(
        _ endpoint: Endpoint,
        ssl: DriverSSLConfiguration,
        policy: MySQLTLSPolicy,
        serverName: MySQLTLSServerName?,
        deadline: DispatchTime
    ) async throws -> UnsafeMutablePointer<MYSQL> {
        let now = DispatchTime.now()
        guard deadline > now else { throw Self.timedOut() }
        let remaining = DispatchTimeInterval.nanoseconds(Int(deadline.uptimeNanoseconds - now.uptimeNanoseconds))

        guard let handle = mysql_init(nil) else {
            throw MySQLError.connectionFailed("Failed to initialize MySQL client")
        }

        MySQLDialOptions.apply(
            to: handle,
            policy: policy,
            ssl: ssl,
            serverName: serverName,
            signsInWithToken: endpoint.signsInWithToken,
            connectSeconds: 10,
            socketSeconds: Self.signInSocketSeconds
        )

        // A late call closes the handle it was still using, rather than the caller closing it.
        nonisolated(unsafe) let unsafeHandle = handle
        let connected = try await runCancellableBlocking(
            on: DispatchQueue(label: "com.TablePro.mysql.connect.\(UUID().uuidString)"),
            deadline: remaining,
            timeoutError: { Self.timedOut() },
            work: {
                withExtendedLifetime(serverName) {
                    mysql_real_connect(
                        unsafeHandle, endpoint.host, endpoint.user, endpoint.password, endpoint.database,
                        endpoint.port, nil, 0
                    ) != nil
                }
            },
            discardLateResult: { _ in mysql_close(unsafeHandle) }
        )

        guard connected else {
            let failure = AttemptFailure(
                code: mysql_errno(handle),
                message: message(from: handle),
                serverCapabilities: handle.pointee.server_capabilities
            )
            mysql_close(handle)
            throw failure
        }
        return handle
    }

    private static func timedOut() -> MySQLError {
        MySQLError.connectionFailed(String(localized: "Timed out connecting to the MySQL server."))
    }

    private func binaryStringsAreText(in query: String) -> Bool {
        showTextIsBinary && mysqlStatementListsServerMetadata(query)
    }

    func close() {
        killer.detach()
        guard let mysql else { return }
        if let result = streamingResult {
            // An open result points at the handle `mysql_close` frees, so it goes first; shutting the socket
            // makes `mysql_free_result` stop reading the rows it would otherwise skip one by one.
            mariadb_cancel(mysql)
            mysql_free_result(result)
            clearStream()
        }
        mysql_close(mysql)
        self.mysql = nil
        tlsServerName = nil
    }

    func ping() throws -> Bool {
        guard let mysql else { throw MySQLError.notConnected }
        if mysql_ping(mysql) != 0 {
            throw MySQLError.queryFailed(message(from: mysql))
        }
        return true
    }

    private func legacyText(_ value: PluginCellValue) -> String? {
        switch value {
        case .null:
            return nil
        case .text(let text):
            return text
        case .bytes(let data):
            return Self.hexText(data)
        @unknown default:
            return nil
        }
    }

    private static func hexText(_ data: Data) -> String {
        let shown = data.prefix(hexPreviewBytes)
        let hex = shown.map { String(format: "%02X", $0) }.joined()
        return data.count > hexPreviewBytes ? "0x\(hex)…" : "0x\(hex)"
    }

    private static let hexPreviewBytes = 256

    private func message(from mysql: UnsafeMutablePointer<MYSQL>) -> String {
        guard let text = mysql_error(mysql) else { return "" }
        return MySQLErrorText.decode(cString: text, language: errorLanguage, encoding: encoding)
    }

    func serverVersion() -> String? {
        guard let mysql else { return nil }
        return String(cString: mysql_get_server_info(mysql))
    }

    func transactionState() -> DriverTransactionState {
        guard let mysql else { return .unknown }
        var serverStatus: UInt32 = 0
        let infoResult = mariadb_get_info(mysql, MARIADB_CONNECTION_SERVER_STATUS, &serverStatus)
        return MySQLSessionTransaction.state(infoResult: infoResult, serverStatus: serverStatus)
    }

    /// `NO_BACKSLASH_ESCAPES` from the status flags of the last reply turns the backslash off in both string quotes.
    /// With it off, a double-quoted token is a string or an identifier depending on `ANSI_QUOTES`, which MySQL reports
    /// nowhere, so only the single quote is settled then.
    func lexicalFacts() -> SQLSessionLexicalFacts? {
        guard let mysql else { return nil }
        var serverStatus: UInt32 = 0
        guard mariadb_get_info(mysql, MARIADB_CONNECTION_SERVER_STATUS, &serverStatus) == 0 else { return nil }
        guard serverStatus & UInt32(SERVER_STATUS_NO_BACKSLASH_ESCAPES) != 0 else {
            return SQLSessionLexicalFacts(
                determined: .backslashEscapesInSingleQuotes,
                enabled: .backslashEscapesInSingleQuotes
            )
        }
        return SQLSessionLexicalFacts(
            determined: [.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes],
            enabled: []
        )
    }

    // As beginStream does: the server takes no command while a streamed result is unread ("Commands out of sync").
    func execute(_ query: String) throws -> RawMySQLResult {
        guard let mysql else { throw MySQLError.notConnected }
        endLeftoverStream(of: mysql)
        let sent = send(killer.reserve(), on: mysql)
        defer { finish(sent, on: mysql) }

        let start = Date()

        guard mysql_real_query(mysql, query, UInt(query.utf8.count)) == 0 else {
            throw MySQLError.queryFailed(message(from: mysql))
        }

        guard let result = mysql_store_result(mysql) else {
            if mysql_field_count(mysql) != 0 {
                throw MySQLError.queryFailed(message(from: mysql))
            }
            let raw = mysql_affected_rows(mysql)
            let affected = raw == .max ? 0 : Int(clamping: raw)
            try consumeTrailingResults(of: mysql)
            return RawMySQLResult(
                columns: [], columnTypes: [], rows: [],
                rowsAffected: affected, executionTime: Date().timeIntervalSince(start), isTruncated: false
            )
        }

        let fieldCount = Int(mysql_num_fields(result))
        let described = MariaDBCharacterSet.describeColumns(
            of: mysql_fetch_fields(result), count: fieldCount, encoding: encoding,
            binaryStringsAreText: binaryStringsAreText(in: query)
        )
        let columns = described.names
        let columnTypes = described.typeNames

        var rows: [[String?]] = []
        let maxRows = 100_000

        while let row = mysql_fetch_row(result) {
            if rows.count >= maxRows {
                break
            }

            let lengths = mysql_fetch_lengths(result)
            rows.append(described.row(encoding: encoding) { index in
                guard let value = row[index] else { return nil }
                return UnsafeRawBufferPointer(start: value, count: Int(clamping: lengths?[index] ?? 0))
            }.map(legacyText))
        }
        mysql_free_result(result)

        let isTruncated = rows.count >= maxRows
        let affected: Int
        if columns.isEmpty {
            let raw = mysql_affected_rows(mysql)
            affected = raw == .max ? 0 : Int(clamping: raw)
        } else {
            affected = 0
        }
        try consumeTrailingResults(of: mysql)
        return RawMySQLResult(
            columns: columns, columnTypes: columnTypes, rows: rows,
            rowsAffected: affected, executionTime: Date().timeIntervalSince(start), isTruncated: isTruncated
        )
    }

    // MARK: - Streaming

    private static let logger = Logger(subsystem: "com.TablePro", category: "MySQLDriver")

    /// `streamingResult`, while set, belongs to the stream `streamGeneration` names.
    private var streamingResult: UnsafeMutablePointer<MYSQL_RES>?
    private var streamGeneration: UInt64 = 0
    private var streamingColumns: [ColumnInfo] = []
    private var streamingDecoding = MySQLResultColumns()
    private var streamingStatement: SentStatement?

    func beginStream(query: String, statement: UInt64) throws -> MySQLBeginStreamResult {
        guard let mysql else { throw MySQLError.notConnected }
        endLeftoverStream(of: mysql)
        streamGeneration &+= 1
        let stream = MySQLStreamID(generation: streamGeneration)
        let sent = send(statement, on: mysql)
        // A reader that left while this waited for the session stops it here; one that leaves later finds it in
        // flight and kills it.
        guard !Task.isCancelled else {
            finish(sent, on: mysql)
            throw CancellationError()
        }

        guard mysql_real_query(mysql, query, UInt(query.utf8.count)) == 0 else {
            finish(sent, on: mysql)
            throw MySQLError.queryFailed(message(from: mysql))
        }

        guard let result = mysql_use_result(mysql) else {
            defer { finish(sent, on: mysql) }
            if mysql_field_count(mysql) != 0 {
                throw MySQLError.queryFailed(message(from: mysql))
            }
            let raw = mysql_affected_rows(mysql)
            let affected = raw == .max ? 0 : Int(clamping: raw)
            try consumeTrailingResults(of: mysql)
            return .noResult(affectedRows: affected)
        }

        streamingResult = result
        streamingStatement = sent

        let described = MariaDBCharacterSet.describeColumns(
            of: mysql_fetch_fields(result), count: Int(mysql_num_fields(result)), encoding: encoding,
            binaryStringsAreText: binaryStringsAreText(in: query)
        )
        streamingDecoding = described
        let columns = described.names.enumerated().map { index, name in
            ColumnInfo(
                name: name,
                typeName: described.typeNames[index],
                isPrimaryKey: false,
                isNullable: true,
                defaultValue: nil,
                comment: nil,
                characterMaxLength: nil,
                ordinalPosition: index
            )
        }
        streamingColumns = columns
        return .rowSet(stream: stream, columns: columns)
    }

    /// A stream that a newer `beginStream` or a close has ended stops short, so it reports as cut off rather
    /// than complete.
    func fetchNextRow(_ stream: MySQLStreamID, options: StreamOptions, columns: [ColumnInfo]) throws -> [Cell]? {
        guard let mysql, stream.generation == streamGeneration, let result = streamingResult else {
            throw CancellationError()
        }
        let errorBefore = mysql_errno(mysql)
        guard let row = mysql_fetch_row(result) else {
            if let failure = fetchFailure(of: mysql, errorBefore: errorBefore) { throw failure }
            return nil
        }

        let lengths = mysql_fetch_lengths(result)
        let values = streamingDecoding.row(encoding: encoding) { index in
            guard let value = row[index] else { return nil }
            return UnsafeRawBufferPointer(start: value, count: Int(clamping: lengths?[index] ?? 0))
        }

        return zip(values, columns).map { value, column in
            let ref = makeCellRef(column: column.name, row: row, options: options, columns: columns)
            switch value {
            case .null:
                return .null
            case .bytes(let data):
                return .binary(byteCount: data.count, ref: ref)
            case .text(let text):
                return Cell.from(
                    legacyValue: text,
                    columnTypeName: column.typeName,
                    options: options,
                    ref: ref
                )
            @unknown default:
                return .null
            }
        }
    }

    func endStream(_ stream: MySQLStreamID) throws {
        guard let mysql, stream.generation == streamGeneration else { return }
        try releaseStream(of: mysql)
    }

    /// The producer of a superseded stream only learns that its rows were cut off, so an error in the rest of
    /// its statement has no one to reach and is logged.
    private func endLeftoverStream(of mysql: UnsafeMutablePointer<MYSQL>) {
        do {
            try releaseStream(of: mysql)
        } catch {
            Self.logger.warning(
                "A superseded statement failed after its stream ended: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func releaseStream(of mysql: UnsafeMutablePointer<MYSQL>) throws {
        guard let result = streamingResult else { return }
        let sent = streamingStatement
        clearStream()
        defer { if let sent { finish(sent, on: mysql) } }
        try drain(result, of: mysql)
        try consumeTrailingResults(of: mysql)
    }

    private func clearStream() {
        streamingResult = nil
        streamingStatement = nil
        streamingColumns = []
        streamingDecoding = MySQLResultColumns()
    }

    // MARK: - Stopping a statement

    nonisolated private struct SentStatement: Sendable {
        let id: UInt64
        let sentAt: ContinuousClock.Instant
    }

    private func send(_ statement: UInt64, on mysql: UnsafeMutablePointer<MYSQL>) -> SentStatement {
        if killer.collectLatchedKill() {
            absorbLatchedKill(on: mysql)
        }
        killer.sent(statement)
        return SentStatement(id: statement, sentAt: .now)
    }

    // A throwaway statement collects the flag, failing with 1317 where the server kept it, so the user's runs as sent.
    // It costs the session its ROW_COUNT() and FOUND_ROWS(), as on the Mac.
    private func absorbLatchedKill(on mysql: UnsafeMutablePointer<MYSQL>) {
        let probe = "SELECT 1"
        guard mysql_real_query(mysql, probe, UInt(probe.utf8.count)) == 0 else { return }
        if let result = mysql_store_result(mysql) {
            mysql_free_result(result)
        }
    }

    // Connector/C reports its own read timeout as the same lost connection a server drop gives, and only that one
    // leaves the statement running, so only a wait that long kills it.
    private func finish(_ sent: SentStatement, on mysql: UnsafeMutablePointer<MYSQL>) {
        let code = mysql_errno(mysql)
        let interrupted = code != 0 && flavor.isInterruptedByKill(errno: code, message: message(from: mysql))
        killer.finished(sent.id, interrupted: interrupted)
        guard Self.connectionLossCodes.contains(code),
              mysqlWaitCouldOutlastSocketTimeout(sent.sentAt.duration(to: .now), socketTimeoutSeconds: socketTimeoutSeconds)
        else { return }
        killer.killOrphan()
    }

    /// The first result set is the statement's answer, as before. A later one, such as a `CALL` that selects
    /// twice, is read and dropped so the session can take the next command, and an error in one fails the statement.
    private func consumeTrailingResults(of mysql: UnsafeMutablePointer<MYSQL>) throws {
        while mysql_more_results(mysql) != 0 {
            let status = mysql_next_result(mysql)
            if status > 0 { throw MySQLError.queryFailed(message(from: mysql)) }
            if status < 0 { return }
            if let result = mysql_use_result(mysql) {
                try drain(result, of: mysql)
            } else if mysql_field_count(mysql) != 0 {
                throw MySQLError.queryFailed(message(from: mysql))
            }
        }
    }

    private func drain(_ result: UnsafeMutablePointer<MYSQL_RES>, of mysql: UnsafeMutablePointer<MYSQL>) throws {
        let errorBefore = mysql_errno(mysql)
        while mysql_fetch_row(result) != nil {}
        let failure = fetchFailure(of: mysql, errorBefore: errorBefore)
        mysql_free_result(result)
        if let failure { throw failure }
    }

    /// `mysql_fetch_row` returns nil both at the end and on an error, and a command refused while the result
    /// was open leaves its own code on the handle, so only a code the fetch set means the rows ended in an error.
    private func fetchFailure(of mysql: UnsafeMutablePointer<MYSQL>, errorBefore: UInt32) -> MySQLError? {
        let code = mysql_errno(mysql)
        guard code != 0, code != errorBefore else { return nil }
        return .queryFailed(message(from: mysql))
    }

    private func makeCellRef(column: String, row: MYSQL_ROW, options: StreamOptions, columns: [ColumnInfo]) -> CellRef? {
        guard let lazyContext = options.lazyContext, !lazyContext.primaryKeyColumns.isEmpty else { return nil }

        var pkComponents: [PrimaryKeyComponent] = []
        for pkColumn in lazyContext.primaryKeyColumns {
            guard let columnIndex = columns.firstIndex(where: { $0.name == pkColumn }) else { return nil }
            guard let cValue = row[columnIndex] else { return nil }
            let value = mysqlSessionText(cString: cValue, encoding: encoding)
            pkComponents.append(PrimaryKeyComponent(column: pkColumn, value: value))
        }
        return CellRef(table: lazyContext.table, column: column, primaryKey: pkComponents)
    }
}

nonisolated private struct MySQLStreamID: Sendable {
    let generation: UInt64
}

nonisolated private enum MySQLBeginStreamResult: Sendable {
    case rowSet(stream: MySQLStreamID, columns: [ColumnInfo])
    case noResult(affectedRows: Int)
}

nonisolated private struct RawMySQLResult: Sendable {
    let columns: [String]
    let columnTypes: [String]
    let rows: [[String?]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}

// MARK: - Errors

nonisolated enum MySQLError: Error, LocalizedError {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "MySQL connection failed: \(msg)"
        case .notConnected: return "Not connected to MySQL database"
        case .queryFailed(let msg): return "MySQL query failed: \(msg)"
        case .unsupported(let msg): return msg
        }
    }
}
