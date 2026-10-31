//
//  NativeDumpRegistry.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Which engines can dump and restore, and how to drive them.
///
/// Curated here rather than declared by each driver plugin, because the facts are about tools on
/// the user's Mac rather than about the driver's own behaviour, and adding a `DriverPlugin` static
/// for them would mean an ABI change and a re-release of every registry plugin for data no plugin
/// produces.
///
/// A password never reaches the argument list. Anything in `argv` is readable by every process on
/// the machine through `ps`, so each engine's own out-of-band channel is used instead: `PGPASSWORD`
/// and `MYSQL_PWD` for the two that read the environment, and a `0600` config file for MongoDB,
/// whose tools read neither.
enum NativeDumpRegistry {
    /// The formats one engine can write, in the order the sheet offers them. The first is the
    /// default. Only DuckDB has more than one.
    static func formats(for type: DatabaseType) -> [NativeDumpDescriptor.ArchiveFormat] {
        switch type {
        case .duckdb:
            return [duckDBFileFormat, duckDBParquetFormat]
        default:
            return descriptor(for: type).map { [$0.archiveFormat] } ?? []
        }
    }

    static func descriptor(
        for type: DatabaseType,
        formatId: String? = nil
    ) -> NativeDumpDescriptor? {
        switch type {
        case .postgresql:
            return postgres(toolForServer: postgresToolForServer)
        case .redshift:
            return postgres(toolForServer: nil)
        case .mysql, .mariadb:
            return mysql
        case .mongodb:
            return mongodb
        case .sqlite, .libsql:
            return sqlite
        case .mssql:
            return sqlServer
        case .duckdb:
            return formatId == duckDBParquetFormat.id ? duckDBParquet : duckDBFile
        default:
            return nil
        }
    }

    static func supports(_ type: DatabaseType) -> Bool {
        descriptor(for: type) != nil
    }

    /// Whether this particular connection can be dumped, which is not always the same question as
    /// whether its engine can.
    ///
    /// libSQL reaches either a local file or a Turso URL, and only the file can be handed to
    /// `sqlite3`. Answering by type alone is how a remote libSQL connection produced a 52-byte
    /// backup the result sheet reported as a success.
    static func supports(_ connection: DatabaseConnection, localFilePath: String?) -> Bool {
        guard let descriptor = descriptor(for: connection.type) else { return false }
        guard descriptor.requiresLocalFile else { return true }
        let path = localFilePath ?? connection.database
        return !path.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - PostgreSQL

    /// Redshift reports 8.0.2, which no `pg_dump` release claims to support, so only PostgreSQL
    /// itself is matched to the server.
    static let postgresToolForServer: @Sendable (String, String?) -> NativeDumpToolSelection = { binary, serverVersion in
        PostgreSQLDumpToolLocator.select(binary: binary, serverVersion: serverVersion)
    }

    private static func postgres(
        toolForServer: (@Sendable (String, String?) -> NativeDumpToolSelection)?
    ) -> NativeDumpDescriptor {
        NativeDumpDescriptor(
            mechanism: .commandLineTool(
                NativeDumpDescriptor.CommandLineTool(
                    backupBinaries: ["pg_dump"],
                    restoreBinaries: ["pg_restore"],
                    installHint: String(localized: "Install it with “brew install libpq” and link it."),
                    backupDelivery: .toolWritesFile,
                    restoreDelivery: .toolWritesFile,
                    restoreExitPolicy: .toleratesUnrecognizedSessionSettings,
                    requiresUntranslatedMessages: true,
                    toolForServer: toolForServer,
                    backupArguments: { request, _ in
                        try connectionFlags(request)
                            + ["-Fc", "-d", NativeDumpArgumentQuoting.postgresDatabase(request.database)]
                            + postgresTableFlags(request)
                            + ["-f", request.fileURL.path]
                    },
                    restoreArguments: { request, _ in
                        try connectionFlags(request) + [
                            "--no-owner",
                            "--no-acl",
                            "-d",
                            NativeDumpArgumentQuoting.postgresDatabase(request.database),
                            request.fileURL.path
                        ]
                    },
                    environment: { request in
                        var environment: [String: String] = [:]
                        if let password = request.password, !password.isEmpty {
                            environment["PGPASSWORD"] = password
                        }
                        environment.merge(
                            postgresSSLEnvironment(request.connection.transportSSLConfiguration)
                        ) { _, new in new }
                        return environment
                    }
                )
            ),
            archiveFormat: NativeDumpDescriptor.ArchiveFormat(
                fileExtension: "dump",
                contentDescription: String(localized: "PostgreSQL custom archive")
            ),
            objectScope: .tables(
                caveat: String(
                    localized: """
                        A dump of chosen tables may not restore on its own. Sequences, types, schemas \
                        and tables it references are left out.
                        """)
            ),
            restoreSemantics: .addsToExistingObjects
        )
    }

    /// `-t` takes a `psql` pattern rather than a name, so every picked table is quoted part by
    /// part. Measured with pg_dump 17.11: `-t 'app.Orders'` matches nothing and
    /// `-t '"app"."Orders"'` matches exactly one table.
    private static func postgresTableFlags(_ request: NativeDumpDescriptor.Request) -> [String] {
        request.scope.objects.flatMap { object in
            ["-t", NativeDumpArgumentQuoting.postgresTablePattern(object)]
        }
    }

    // A socket goes to `-h` as its directory, the way libpq reads a host starting with `/`.
    private static func connectionFlags(_ request: NativeDumpDescriptor.Request) -> [String] {
        let socket = request.connection.type.localSocketIsDirectory ? request.connection.localSocketEndpoint : nil
        let host = socket?.path ?? request.host
        let port = socket?.port ?? request.connection.port
        var flags = ["--no-password", "-h", host, "-p", String(port)]
        if !request.connection.username.isEmpty {
            flags.append(contentsOf: ["-U", request.connection.username])
        }
        return flags
    }

    static func postgresSSLMode(_ mode: SSLMode) -> String? {
        switch mode {
        case .disabled: return nil
        case .preferred: return "prefer"
        case .required: return "require"
        case .verifyCa: return "verify-ca"
        case .verifyIdentity: return "verify-full"
        }
    }

    /// The whole of the connection's SSL configuration, not just its mode.
    ///
    /// libpq falls back to `~/.postgresql/root.crt` when no root certificate is named, and measured
    /// with pg_dump 17.11 a `verify-ca` connection with no such file fails before connecting with
    /// `root certificate file "..." does not exist`. So a Verify CA connection that opens in the
    /// app could never be dumped. The rule matches what `LibPQConnectionString` already sends on
    /// the live connection, down to the CA being tied to the modes that verify.
    static func postgresSSLEnvironment(_ ssl: SSLConfiguration) -> [String: String] {
        guard ssl.isEnabled, let mode = postgresSSLMode(ssl.mode) else { return [:] }
        var environment = ["PGSSLMODE": mode]
        if ssl.verifiesCertificate, !ssl.caCertificatePath.isEmpty {
            environment["PGSSLROOTCERT"] = ssl.caCertificatePath
        }
        if !ssl.clientCertificatePath.isEmpty {
            environment["PGSSLCERT"] = ssl.clientCertificatePath
        }
        if !ssl.clientKeyPath.isEmpty {
            environment["PGSSLKEY"] = ssl.clientKeyPath
        }
        return environment
    }

    // MARK: - MySQL and MariaDB

    /// MariaDB 11.0 renamed every client, keeping the `mysql`-prefixed names as symlinks that some
    /// builds leave out, so both spellings are tried.
    private static var mysql: NativeDumpDescriptor {
        NativeDumpDescriptor(
            mechanism: .commandLineTool(
                NativeDumpDescriptor.CommandLineTool(
                    backupBinaries: ["mysqldump", "mariadb-dump"],
                    restoreBinaries: ["mysql", "mariadb"],
                    installHint: String(localized: "Install it with “brew install mysql-client” and link it."),
                    backupDelivery: .standardOutput,
                    restoreDelivery: .standardOutput,
                    identifyExecutable: { name, path in
                        MySQLDumpToolIdentifier.identify(name: name, path: path)
                    },
                    backupArguments: { request, resolved in
                        try mysqlConnectionFlags(request, resolved) + [
                            "--single-transaction",
                            "--routines",
                            "--triggers",
                            "--events",
                            "--default-character-set=utf8mb4"
                        ]
                            + MySQLClientArguments.dumpCompatibility(
                                tool: resolved, serverVersion: request.serverVersion
                            )
                            + mysqlObjectArguments(request)
                    },
                    restoreArguments: { request, resolved in
                        try mysqlConnectionFlags(request, resolved)
                            + MySQLClientArguments.restoreSafety(tool: resolved)
                            + ["--default-character-set=utf8mb4", "--", request.database]
                    },
                    environment: { request in
                        guard let password = request.password, !password.isEmpty else { return [:] }
                        return ["MYSQL_PWD": password]
                    },
                    prepare: { request, resolved in
                        try await mysqlPrepare(request, resolved)
                    },
                    clientPluginFolder: { request, resolved in
                        try mysqlPluginFolder(request, resolved)
                    }
                )
            ),
            archiveFormat: NativeDumpDescriptor.ArchiveFormat(
                fileExtension: "sql",
                contentDescription: String(localized: "SQL statements")
            ),
            objectScope: .tables(
                caveat: String(
                    localized: """
                        Views and tables the chosen tables reference are left out. The dump turns \
                        foreign key checks off, so it restores with those references dangling.
                        """)
            ),
            restoreSemantics: .replacesObjects
        )
    }

    /// `--` before the database, because `my_getopt` does not stop parsing options at the first
    /// positional argument and every name after it is the user's. Measured with mysqldump 8.4.11
    /// and 12.3.2, a database named `--no-data` with the terminator behind it dumped a *different*
    /// database with no rows and exited 0, which the result sheet reports as a successful backup;
    /// a table named `--ssl-mode=DISABLED` in the same slot sends the whole dump in cleartext. With
    /// `--` in front of the database, both are names again.
    private static func mysqlObjectArguments(_ request: NativeDumpDescriptor.Request) -> [String] {
        ["--", request.database] + request.scope.objects.map(\.name)
    }

    private static func mysqlPrepare(
        _ request: NativeDumpDescriptor.Request,
        _ resolved: NativeDumpResolvedTool
    ) async throws -> NativeDumpDescriptor.Request {
        var request = request
        request.serverOffersTLS = try await mysqlServerOffersTLS(request, resolved)
        let hidesPlugins = MySQLClientArguments.hidesPlaintextPasswordPlugins(
            request.connection,
            flavor: resolved.flavor,
            serverOffersTLS: request.serverOffersTLS
        )
        guard hidesPlugins else { return request }
        switch await MariaDBBuiltInPlaintextCheck.verdict(toolPath: resolved.path) {
        case .refusesPlaintext:
            break
        case .sendsPlaintext:
            throw NativeDumpError.incompatibleTool(
                message: String(
                    format: String(
                        localized: """
                            %@ sends the password in plain text when a server asks, even without TLS, and TablePro \
                            cannot turn that off. Set SSL Mode to Required, or install another build of the client tools.
                            """
                    ),
                    resolved.path
                )
            )
        case .unknown:
            throw NativeDumpError.incompatibleTool(
                message: String(
                    format: String(
                        localized: """
                            TablePro could not check whether %@ sends the password in plain text without TLS. Try \
                            again, or set SSL Mode to Required.
                            """
                    ),
                    resolved.path
                )
            )
        }
        return request
    }

    // Unreadable fails the run: guessing no TLS would dump in plaintext from a server that has it, and guessing TLS
    // brings back the fallback that sends the typed password.
    private static func mysqlServerOffersTLS(
        _ request: NativeDumpDescriptor.Request,
        _ resolved: NativeDumpResolvedTool
    ) async throws -> Bool? {
        guard MySQLClientArguments.needsServerGreeting(request.connection, flavor: resolved.flavor) else { return nil }
        switch await MySQLServerGreeting.read(host: request.host, port: request.connection.port) {
        case .offersTLS(let offered):
            return offered
        case .serverError(let message):
            throw NativeDumpError.unreachableServer(message: message)
        case .unreadable:
            throw NativeDumpError.unreachableServer(
                message: String(
                    format: String(
                        localized: "TablePro could not reach %@ to see whether it offers TLS. Check that the server is running and reachable, then try again."
                    ),
                    "\(request.host):\(request.connection.port)"
                )
            )
        }
    }

    private static func mysqlPluginFolder(
        _ request: NativeDumpDescriptor.Request,
        _ resolved: NativeDumpResolvedTool
    ) throws -> MariaDBClientPluginFolder? {
        guard MySQLClientArguments.hidesPlaintextPasswordPlugins(
            request.connection,
            flavor: resolved.flavor,
            serverOffersTLS: request.serverOffersTLS
        ) else { return nil }
        return try MariaDBClientPluginFolder.make(from: MariaDBClientPluginFolder.pluginDirectory(forTool: resolved.path))
    }

    private static func mysqlConnectionFlags(
        _ request: NativeDumpDescriptor.Request,
        _ resolved: NativeDumpResolvedTool
    ) throws -> [String] {
        var flags = MySQLClientArguments.endpoint(
            host: request.host,
            port: request.connection.port,
            socketPath: MySQLLocalSocket.path(in: request.connection.additionalFields)
        )
        if !request.connection.username.isEmpty {
            flags.append(contentsOf: ["-u", request.connection.username])
        }
        flags.append(
            contentsOf: try MySQLClientArguments.tls(
                request.connection.transportSSLConfiguration,
                flavor: resolved.flavor,
                toolPath: resolved.path,
                serverOffersTLS: request.serverOffersTLS
            )
        )
        if request.connection.usesIAMToken {
            flags.append(contentsOf: MySQLClientArguments.cleartextAuthentication(flavor: resolved.flavor))
        }
        if let folder = request.clientPluginFolder {
            flags.append(contentsOf: MySQLClientArguments.pluginDirectory(folder.url))
        }
        return flags
    }

    // MARK: - MongoDB

    /// `mongodump` reads no password from the environment, and a password in `argv` is readable by
    /// every process on the machine. Its `--config` file is the only channel left, so the caller
    /// writes one at mode `0600` and passes its path; `NativeDumpService` removes it afterwards.
    private static var mongodb: NativeDumpDescriptor {
        NativeDumpDescriptor(
            mechanism: .commandLineTool(
                NativeDumpDescriptor.CommandLineTool(
                    backupBinaries: ["mongodump"],
                    restoreBinaries: ["mongorestore"],
                    installHint: String(localized: "Install it with “brew install mongodb-database-tools”."),
                    backupDelivery: .toolWritesFile,
                    restoreDelivery: .toolWritesFile,
                    backupArguments: { request, _ in
                        mongoNamespaceFlags(request) + ["--gzip", "--archive=\(request.fileURL.path)"]
                    },
                    restoreArguments: { request, _ in
                        NativeDumpArgumentQuoting.mongoRestoreRenaming(into: request.database)
                            + ["--gzip", "--archive=\(request.fileURL.path)"]
                    },
                    configurationFileEntries: { request in mongoConfigurationEntries(request) }
                )
            ),
            archiveFormat: NativeDumpDescriptor.ArchiveFormat(
                fileExtension: "archive",
                contentDescription: String(localized: "MongoDB gzipped archive")
            ),
            objectScope: .collections,
            restoreSemantics: .addsToExistingObjects
        )
    }

    /// A whole-database dump names the database; a narrowed one names each collection, because
    /// `--db` plus `--collection` takes only one collection at a time while `--nsInclude` repeats.
    private static func mongoNamespaceFlags(_ request: NativeDumpDescriptor.Request) -> [String] {
        guard !request.scope.isWholeDatabase else { return ["--db=\(request.database)"] }
        return request.scope.objects.map { object in
            "--nsInclude=\(NativeDumpArgumentQuoting.mongoNamespace(database: request.database, collection: object.name))"
        }
    }

    private static func mongoConfigurationEntries(
        _ request: NativeDumpDescriptor.Request
    ) -> [NativeDumpDescriptor.ConfigurationEntry] {
        var entries = [
            NativeDumpDescriptor.ConfigurationEntry(
                key: "uri",
                value: MongoToolsConnectionString.make(for: request.connection, host: request.host)
            )
        ]
        if let password = request.password, !password.isEmpty, !request.connection.username.isEmpty {
            entries.append(NativeDumpDescriptor.ConfigurationEntry(key: "password", value: password))
        }
        return entries
    }

    // MARK: - SQL Server

    /// `sqlpackage` is Microsoft's own client-side export, and the only one that writes a whole
    /// database to a local file. `bcp` moves one table at a time and produces no schema, so it
    /// cannot stand in for a dump.
    ///
    /// Not verified against a live server here: the arguments come from Microsoft's documented CLI
    /// surface rather than from a run, so a mistake in them surfaces as the tool's own usage error
    /// rather than a wrong file.
    private static var sqlServer: NativeDumpDescriptor {
        NativeDumpDescriptor(
            mechanism: .commandLineTool(
                NativeDumpDescriptor.CommandLineTool(
                    backupBinaries: ["sqlpackage"],
                    restoreBinaries: ["sqlpackage"],
                    installHint: String(localized: "Download SqlPackage from Microsoft and put it on your PATH."),
                    backupDelivery: .toolWritesFile,
                    restoreDelivery: .toolWritesFile,
                    exposesPasswordInArguments: true,
                    backupArguments: { request, _ in
                        try ["/Action:Export",
                             "/TargetFile:\(request.fileURL.path)",
                             "/SourceConnectionString:\(sqlServerConnectionString(request))"]
                            + request.scope.objects.map { "/p:TableData=\(sqlServerTableData($0))" }
                    },
                    restoreArguments: { request, _ in
                        try ["/Action:Import",
                             "/SourceFile:\(request.fileURL.path)",
                             "/TargetConnectionString:\(sqlServerConnectionString(request))"]
                    }
                )
            ),
            archiveFormat: NativeDumpDescriptor.ArchiveFormat(
                fileExtension: "bacpac",
                contentDescription: String(localized: "SQL Server bacpac")
            ),
            objectScope: .dataOnly(
                caveat: String(
                    localized: """
                        The .bacpac always carries the whole schema. Only the chosen tables' data is \
                        narrowed, and tables they reference by foreign key have to be chosen too.
                        """)
            ),
            restoreSemantics: .requiresEmptyDatabase
        )
    }

    private static func sqlServerTableData(_ object: NativeDumpObject) -> String {
        guard let schema = object.schema else { return object.name }
        return "\(schema).\(object.name)"
    }

    /// `sqlpackage` takes no password flag and no password environment variable: the connection
    /// string is the only channel it has. That puts the password in `argv`, where `ps` can read it,
    /// so the string is built here and `NativeDumpService` keeps SQL Server out of the flows that
    /// promise otherwise. Anything better needs Entra or integrated auth, which have no password.
    private static func sqlServerConnectionString(_ request: NativeDumpDescriptor.Request) throws -> String {
        let quoted = NativeDumpArgumentQuoting.sqlServerConnectionStringValue
        var parts = try [
            "Server=\(quoted("\(request.host),\(request.connection.port)"))",
            "Database=\(quoted(request.database))"
        ]
        if request.connection.username.isEmpty {
            parts.append("Integrated Security=true")
        } else {
            try parts.append("User ID=\(quoted(request.connection.username))")
            try parts.append("Password=\(quoted(request.password ?? ""))")
        }
        parts.append(request.connection.sslConfig.isEnabled ? "Encrypt=true" : "Encrypt=false")
        if request.connection.sslConfig.mode == .required || request.connection.sslConfig.mode == .preferred {
            parts.append("TrustServerCertificate=true")
        }
        return parts.joined(separator: ";")
    }

    // MARK: - SQLite

    /// The database is a file the tool opens directly, so there is no host, port or password, and
    /// `.dump` writes SQL to standard output.
    ///
    /// The path comes from `localFilePath` rather than from `connection.database`. libSQL claims
    /// this descriptor too and keeps its path in a plugin-declared additional field, so reading
    /// `database` handed `sqlite3` an empty string, which exits 0 after writing a 52-byte file.
    private static var sqlite: NativeDumpDescriptor {
        NativeDumpDescriptor(
            mechanism: .commandLineTool(
                NativeDumpDescriptor.CommandLineTool(
                    backupBinaries: ["sqlite3"],
                    restoreBinaries: ["sqlite3"],
                    installHint: String(localized: "Install it with “brew install sqlite” and link it."),
                    backupDelivery: .standardOutput,
                    restoreDelivery: .standardOutput,
                    // `.shell`, `.system` and writefile() run from a dump read on stdin unless `-safe`
                    // is given. Not `-readonly`: it cannot open a WAL database whose -wal and -shm are gone.
                    backupArguments: { request, _ in
                        [
                            "-safe",
                            sqlitePath(request),
                            NativeDumpArgumentQuoting.sqliteDumpCommand(
                                names: request.scope.objects.map(\.name)
                            )
                        ]
                    },
                    restoreArguments: { request, _ in ["-safe", "-bail", sqlitePath(request)] }
                )
            ),
            archiveFormat: NativeDumpDescriptor.ArchiveFormat(
                fileExtension: "sql",
                contentDescription: String(localized: "SQL statements")
            ),
            objectScope: .tables(caveat: nil),
            restoreSemantics: .addsToExistingObjects,
            requiresLocalFile: true
        )
    }

    private static func sqlitePath(_ request: NativeDumpDescriptor.Request) -> String {
        let resolved = request.localFilePath ?? request.connection.database
        return resolved.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - DuckDB

    static let duckDBFileFormat = NativeDumpDescriptor.ArchiveFormat(
        id: "duckdb",
        fileExtension: "duckdb",
        contentDescription: String(localized: "DuckDB database file")
    )

    static let duckDBParquetFormat = NativeDumpDescriptor.ArchiveFormat(
        id: "parquet",
        fileExtension: "",
        contentDescription: String(localized: "Folder of Parquet files"),
        producesDirectory: true
    )

    private static var duckDBFile: NativeDumpDescriptor {
        NativeDumpDescriptor(
            mechanism: .engineStatements(duckDBFileStatements),
            archiveFormat: duckDBFileFormat,
            objectScope: .unsupported(
                reason: String(localized: "DuckDB copies the whole database. There is no table filter.")
            ),
            restoreSemantics: .stopsAtExistingObjects
        )
    }

    // The catalog is the session's, never `main`: DuckDB names one after the file, so `my-weird.name.db` attaches as `my-weird`.
    private static let duckDBFileStatements = NativeDumpDescriptor.EngineStatements(
        backupStatements: { request, alias in
            guard let source = request.currentCatalog, !source.isEmpty else { return [] }
            return ["ATTACH \(quotedLiteral(request.fileURL.path)) AS \(quotedIdentifier(alias))"]
                + copyDatabase(from: source, to: alias)
                + ["DETACH \(quotedIdentifier(alias))"]
        },
        restoreStatements: { request, alias in
            guard let target = request.currentCatalog, !target.isEmpty else { return [] }
            return ["ATTACH \(quotedLiteral(request.fileURL.path)) AS \(quotedIdentifier(alias)) (READ_ONLY)"]
                + copyDatabase(from: alias, to: target)
                + ["DETACH \(quotedIdentifier(alias))"]
        },
        cleanupStatements: { alias in ["DETACH \(quotedIdentifier(alias))"] }
    )

    // Without an option, COPY FROM DATABASE expands to these two statements, and a prepared statement holds only one.
    private static func copyDatabase(from source: String, to target: String) -> [String] {
        ["SCHEMA", "DATA"].map { part in
            "COPY FROM DATABASE \(quotedIdentifier(source)) TO \(quotedIdentifier(target)) (\(part))"
        }
    }

    // EXPORT DATABASE merges into an earlier export, so the caller empties the folder first. On restore the folder's
    // schema.sql and load.sql run only in the driver's isolated instance, and the session restores the file it builds.
    private static var duckDBParquet: NativeDumpDescriptor {
        NativeDumpDescriptor(
            mechanism: .engineStatements(
                NativeDumpDescriptor.EngineStatements(
                    backupStatements: { request, _ in
                        ["EXPORT DATABASE \(quotedLiteral(request.fileURL.path)) (FORMAT PARQUET)"]
                    },
                    restoreStatements: duckDBFileStatements.restoreStatements,
                    cleanupStatements: duckDBFileStatements.cleanupStatements,
                    isolatedImportFormat: duckDBFileFormat
                )
            ),
            archiveFormat: duckDBParquetFormat,
            objectScope: .unsupported(
                reason: String(localized: "EXPORT DATABASE writes the whole database. There is no table filter.")
            ),
            restoreSemantics: .stopsAtExistingObjects
        )
    }

    private static func quotedLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''", options: .literal))'"
    }

    private static func quotedIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\"", options: .literal))\""
    }
}
