//
//  NativeDumpRegistry.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Which engines have client-side dump and restore tools, and how to drive them.
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
    static func descriptor(for type: DatabaseType) -> NativeDumpDescriptor? {
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
        default:
            return nil
        }
    }

    static func supports(_ type: DatabaseType) -> Bool {
        descriptor(for: type) != nil
    }

    // MARK: - PostgreSQL

    private static var postgres: NativeDumpDescriptor {
        NativeDumpDescriptor(
            backupBinaries: ["pg_dump"],
            restoreBinaries: ["pg_restore"],
            installHint: String(localized: "Install it with `brew install libpq` and link it."),
            archiveFormat: NativeDumpDescriptor.ArchiveFormat(
                fileExtension: "dump",
                contentDescription: String(localized: "PostgreSQL custom archive")
            ),
            backupDelivery: .toolWritesFile,
            restoreDelivery: .toolWritesFile,
            backupArguments: { request in
                connectionFlags(request) + ["-Fc", "-d", request.database, "-f", request.fileURL.path]
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
            backupBinaries: ["mysqldump", "mariadb-dump"],
            restoreBinaries: ["mysql", "mariadb"],
            installHint: String(localized: "Install it with `brew install mysql-client` and link it."),
            archiveFormat: NativeDumpDescriptor.ArchiveFormat(
                fileExtension: "sql",
                contentDescription: String(localized: "SQL statements")
            ),
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
                ]
            },
            restoreArguments: { request in
                mysqlConnectionFlags(request) + ["--default-character-set=utf8mb4", request.database]
            },
            environment: { request in
                guard let password = request.password, !password.isEmpty else { return [:] }
                return ["MYSQL_PWD": password]
            }
        )
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
            backupBinaries: ["mongodump"],
            restoreBinaries: ["mongorestore"],
            installHint: String(localized: "Install it with `brew install mongodb-database-tools`."),
            archiveFormat: NativeDumpDescriptor.ArchiveFormat(
                fileExtension: "archive",
                contentDescription: String(localized: "MongoDB gzipped archive")
            ),
            backupDelivery: .toolWritesFile,
            restoreDelivery: .toolWritesFile,
            backupArguments: { request in
                mongoConnectionFlags(request) + [
                    "--db=\(request.database)",
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
            backupBinaries: ["sqlpackage"],
            restoreBinaries: ["sqlpackage"],
            installHint: String(localized: "Download SqlPackage from Microsoft and put it on your PATH."),
            archiveFormat: NativeDumpDescriptor.ArchiveFormat(
                fileExtension: "bacpac",
                contentDescription: String(localized: "SQL Server bacpac")
            ),
            backupDelivery: .toolWritesFile,
            restoreDelivery: .toolWritesFile,
            exposesPasswordInArguments: true,
            backupArguments: { request in
                ["/Action:Export",
                 "/TargetFile:\(request.fileURL.path)",
                 "/SourceConnectionString:\(sqlServerConnectionString(request))"]
            },
            restoreArguments: { request in
                ["/Action:Import",
                 "/SourceFile:\(request.fileURL.path)",
                 "/TargetConnectionString:\(sqlServerConnectionString(request))"]
            }
        )
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
    private static var sqlite: NativeDumpDescriptor {
        NativeDumpDescriptor(
            backupBinaries: ["sqlite3"],
            restoreBinaries: ["sqlite3"],
            installHint: String(localized: "Install it with `brew install sqlite` and link it."),
            archiveFormat: NativeDumpDescriptor.ArchiveFormat(
                fileExtension: "sql",
                contentDescription: String(localized: "SQL statements")
            ),
            backupDelivery: .standardOutput,
            restoreDelivery: .standardOutput,
            backupArguments: { request in [request.connection.database, ".dump"] },
            restoreArguments: { request in [request.connection.database] }
        )
    }
}
