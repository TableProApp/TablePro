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
        case .postgresql, .redshift:
            return postgres
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

    private static var postgres: NativeDumpDescriptor {
        NativeDumpDescriptor(
            mechanism: .commandLineTool(
                NativeDumpDescriptor.CommandLineTool(
                    backupBinaries: ["pg_dump"],
                    restoreBinaries: ["pg_restore"],
                    installHint: String(localized: "Install it with `brew install libpq` and link it."),
                    backupDelivery: .toolWritesFile,
                    restoreDelivery: .toolWritesFile,
                    backupArguments: { request in
                        connectionFlags(request)
                            + ["-Fc", "-d", request.database]
                            + postgresTableFlags(request)
                            + ["-f", request.fileURL.path]
                    },
                    restoreArguments: { request in
                        connectionFlags(request) + ["--no-owner", "--no-acl", "-d", request.database, request.fileURL.path]
                    },
                    environment: { request in
                        var environment: [String: String] = [:]
                        if let password = request.password, !password.isEmpty {
                            environment["PGPASSWORD"] = password
                        }
                        if request.connection.sslConfig.isEnabled,
                           let mode = postgresSSLMode(request.connection.sslConfig.mode) {
                            environment["PGSSLMODE"] = mode
                        }
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
            )
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

    private static func connectionFlags(_ request: NativeDumpDescriptor.Request) -> [String] {
        var flags = ["--no-password", "-h", request.host, "-p", String(request.connection.port)]
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

    // MARK: - MySQL and MariaDB

    /// MariaDB 11.0 renamed every client, keeping the `mysql`-prefixed names as symlinks that some
    /// builds leave out, so both spellings are tried.
    private static var mysql: NativeDumpDescriptor {
        NativeDumpDescriptor(
            mechanism: .commandLineTool(
                NativeDumpDescriptor.CommandLineTool(
                    backupBinaries: ["mysqldump", "mariadb-dump"],
                    restoreBinaries: ["mysql", "mariadb"],
                    installHint: String(localized: "Install it with `brew install mysql-client` and link it."),
                    backupDelivery: .standardOutput,
                    restoreDelivery: .standardOutput,
                    backupArguments: { request in
                        mysqlConnectionFlags(request) + [
                            "--single-transaction",
                            "--routines",
                            "--triggers",
                            "--events",
                            "--default-character-set=utf8mb4",
                            request.database
                        ] + mysqlTableArguments(request)
                    },
                    restoreArguments: { request in
                        mysqlConnectionFlags(request) + ["--default-character-set=utf8mb4", request.database]
                    },
                    environment: { request in
                        guard let password = request.password, !password.isEmpty else { return [:] }
                        return ["MYSQL_PWD": password]
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
            )
        )
    }

    /// `--` before the table list, because `my_getopt` does not stop parsing options at the first
    /// positional argument. Measured with mysqldump 12.3.2: a table named `--no-data` passed as a
    /// bare argument was read as the option and the dump came back with zero rows, exit 0, which
    /// the result sheet reports as a successful backup. The same trick reaches `--ssl-mode=DISABLED`
    /// and sends the whole dump in cleartext. With `--` in front, the name is a table again.
    private static func mysqlTableArguments(_ request: NativeDumpDescriptor.Request) -> [String] {
        let names = request.scope.objects.map(\.name)
        guard !names.isEmpty else { return [] }
        return ["--"] + names
    }

    private static func mysqlConnectionFlags(_ request: NativeDumpDescriptor.Request) -> [String] {
        var flags = ["--protocol=TCP", "-h", request.host, "-P", String(request.connection.port)]
        if !request.connection.username.isEmpty {
            flags.append(contentsOf: ["-u", request.connection.username])
        }
        if request.connection.sslConfig.isEnabled {
            flags.append(mysqlSSLMode(request.connection.sslConfig.mode))
        } else {
            flags.append("--ssl-mode=DISABLED")
        }
        return flags
    }

    static func mysqlSSLMode(_ mode: SSLMode) -> String {
        switch mode {
        case .disabled: return "--ssl-mode=DISABLED"
        case .preferred: return "--ssl-mode=PREFERRED"
        case .required: return "--ssl-mode=REQUIRED"
        case .verifyCa: return "--ssl-mode=VERIFY_CA"
        case .verifyIdentity: return "--ssl-mode=VERIFY_IDENTITY"
        }
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
                    installHint: String(localized: "Install it with `brew install mongodb-database-tools`."),
                    backupDelivery: .toolWritesFile,
                    restoreDelivery: .toolWritesFile,
                    needsCredentialsFile: true,
                    backupArguments: { request in
                        mongoConnectionFlags(request) + mongoNamespaceFlags(request) + [
                            "--gzip",
                            "--archive=\(request.fileURL.path)"
                        ]
                    },
                    restoreArguments: { request in
                        mongoConnectionFlags(request) + [
                            "--nsInclude=\(request.database).*",
                            "--gzip",
                            "--archive=\(request.fileURL.path)"
                        ]
                    }
                )
            ),
            archiveFormat: NativeDumpDescriptor.ArchiveFormat(
                fileExtension: "archive",
                contentDescription: String(localized: "MongoDB gzipped archive")
            ),
            objectScope: .collections
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

    private static func mongoConnectionFlags(_ request: NativeDumpDescriptor.Request) -> [String] {
        var flags = ["--host=\(request.host)", "--port=\(request.connection.port)"]
        if !request.connection.username.isEmpty {
            flags.append("--username=\(request.connection.username)")
            flags.append("--authenticationDatabase=\(request.connection.database.isEmpty ? "admin" : request.connection.database)")
        }
        if request.connection.sslConfig.isEnabled {
            flags.append("--ssl")
        }
        return flags
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
                    backupArguments: { request in
                        ["/Action:Export",
                         "/TargetFile:\(request.fileURL.path)",
                         "/SourceConnectionString:\(sqlServerConnectionString(request))"]
                            + request.scope.objects.map { "/p:TableData=\(sqlServerTableData($0))" }
                    },
                    restoreArguments: { request in
                        ["/Action:Import",
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
            )
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
    private static func sqlServerConnectionString(_ request: NativeDumpDescriptor.Request) -> String {
        var parts = [
            "Server=\(request.host),\(request.connection.port)",
            "Database=\(request.database)"
        ]
        if request.connection.username.isEmpty {
            parts.append("Integrated Security=true")
        } else {
            parts.append("User ID=\(request.connection.username)")
            parts.append("Password=\(request.password ?? "")")
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
                    installHint: String(localized: "Install it with `brew install sqlite` and link it."),
                    backupDelivery: .standardOutput,
                    restoreDelivery: .standardOutput,
                    backupArguments: { request in
                        [
                            sqlitePath(request),
                            NativeDumpArgumentQuoting.sqliteDumpCommand(
                                names: request.scope.objects.map(\.name)
                            )
                        ]
                    },
                    restoreArguments: { request in [sqlitePath(request)] }
                )
            ),
            archiveFormat: NativeDumpDescriptor.ArchiveFormat(
                fileExtension: "sql",
                contentDescription: String(localized: "SQL statements")
            ),
            objectScope: .tables(caveat: nil),
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

    /// One `.duckdb` file, written by the engine already in front of the app.
    ///
    /// Measured against the vendored libduckdb v1.5.2: `ATTACH` plus `COPY FROM DATABASE` carries
    /// tables, views, indexes, foreign keys and sequences, and restores with the same statement
    /// reversed. The source catalog comes from `current_database()`, because DuckDB derives a
    /// catalog name from the file's basename: a file `my-weird.name.db` attaches as `my-weird`, and
    /// `COPY FROM DATABASE main` fails with `Catalog "main" does not exist`.
    private static var duckDBFile: NativeDumpDescriptor {
        NativeDumpDescriptor(
            mechanism: .engineStatements(
                NativeDumpDescriptor.EngineStatements(
                    backupStatements: { request, alias in
                        guard let source = request.currentCatalog, !source.isEmpty else { return [] }
                        return [
                            "ATTACH \(quotedLiteral(request.fileURL.path)) AS \(quotedIdentifier(alias))",
                            "COPY FROM DATABASE \(quotedIdentifier(source)) TO \(quotedIdentifier(alias))",
                            "DETACH \(quotedIdentifier(alias))"
                        ]
                    },
                    restoreStatements: { request, alias in
                        guard let target = request.currentCatalog, !target.isEmpty else { return [] }
                        return [
                            "ATTACH \(quotedLiteral(request.fileURL.path)) AS \(quotedIdentifier(alias)) (READ_ONLY)",
                            "COPY FROM DATABASE \(quotedIdentifier(alias)) TO \(quotedIdentifier(target))",
                            "DETACH \(quotedIdentifier(alias))"
                        ]
                    },
                    cleanupStatements: { alias in ["DETACH \(quotedIdentifier(alias))"] }
                )
            ),
            archiveFormat: duckDBFileFormat,
            objectScope: .unsupported(
                reason: String(localized: "DuckDB copies the whole database. There is no table filter.")
            )
        )
    }

    /// A folder of Parquet next to `schema.sql` and `load.sql`, which tools other than DuckDB can
    /// read. `EXPORT DATABASE` merges into a folder that already holds one, leaving the previous
    /// run's data files behind, so the caller empties the destination first.
    private static var duckDBParquet: NativeDumpDescriptor {
        NativeDumpDescriptor(
            mechanism: .engineStatements(
                NativeDumpDescriptor.EngineStatements(
                    backupStatements: { request, _ in
                        ["EXPORT DATABASE \(quotedLiteral(request.fileURL.path)) (FORMAT PARQUET)"]
                    },
                    restoreStatements: { request, _ in
                        ["IMPORT DATABASE \(quotedLiteral(request.fileURL.path))"]
                    },
                    cleanupStatements: { _ in [] }
                )
            ),
            archiveFormat: duckDBParquetFormat,
            objectScope: .unsupported(
                reason: String(localized: "EXPORT DATABASE writes the whole database. There is no table filter.")
            )
        )
    }

    private static func quotedLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func quotedIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
