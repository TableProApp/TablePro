//
//  NativeDumpRegistryTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct NativeDumpRegistryTests {
    private func connection(
        type: DatabaseType,
        host: String = "db.example.com",
        port: Int = 5_432,
        database: String = "sales",
        username: String = "alice",
        sslMode: SSLMode = .disabled,
        sslEnabled: Bool = false
    ) -> DatabaseConnection {
        var sslConfig = SSLConfiguration()
        sslConfig.mode = sslMode
        if sslEnabled { sslConfig.mode = sslMode == .disabled ? .required : sslMode }
        return DatabaseConnection(
            name: "Test",
            host: host,
            port: port,
            database: database,
            username: username,
            type: type,
            sshConfig: SSHConfiguration(),
            sslConfig: sslConfig
        )
    }

    private func command(
        _ type: DatabaseType,
        kind: NativeDumpKind = .backup,
        connection overrideConnection: DatabaseConnection? = nil,
        password: String? = "s3cret",
        fileURL: URL = URL(fileURLWithPath: "/tmp/out.bin"),
        scope: NativeDumpScope = .wholeDatabase,
        localFilePath: String? = nil,
        flavor: NativeDumpToolFlavor = .mysql,
        toolVersionText: String? = nil,
        serverVersion: String? = nil
    ) throws -> NativeDumpCommand {
        let tool = try #require(NativeDumpRegistry.descriptor(for: type)?.commandLineTool)
        let effective = overrideConnection ?? connection(type: type)
        return try NativeDumpService.buildCommand(
            kind: kind,
            tool: tool,
            resolved: NativeDumpResolvedTool(
                name: "tool",
                path: "/usr/bin/tool",
                flavor: flavor,
                versionText: toolVersionText
            ),
            request: NativeDumpDescriptor.Request(
                connection: effective,
                database: "sales",
                fileURL: fileURL,
                password: password,
                scope: scope,
                localFilePath: localFilePath ?? effective.database,
                serverVersion: serverVersion
            )
        )
    }

    @Test("The engines with client-side tools are the ones the menu offers")
    func supportedEngines() {
        for type in [DatabaseType.postgresql, .redshift, .mysql, .mariadb, .mongodb, .sqlite] {
            #expect(NativeDumpRegistry.supports(type), "\(type.rawValue) should have a descriptor")
        }
        #expect(NativeDumpRegistry.supports(.duckdb), "DuckDB dumps through its own engine")
        for type in [DatabaseType.clickhouse, .oracle] {
            #expect(!NativeDumpRegistry.supports(type), "\(type.rawValue) should not claim one")
        }
    }

    @Test("PostgreSQL matches its tools to the server, Redshift and MySQL keep the plain lookup")
    func postgresToolsFollowTheServer() throws {
        let postgres = try #require(NativeDumpRegistry.descriptor(for: .postgresql)?.commandLineTool)
        let redshift = try #require(NativeDumpRegistry.descriptor(for: .redshift)?.commandLineTool)
        let mysql = try #require(NativeDumpRegistry.descriptor(for: .mysql)?.commandLineTool)
        #expect(postgres.toolForServer != nil)
        #expect(redshift.toolForServer == nil)
        #expect(mysql.toolForServer == nil)
    }

    @Test("One selector covers both directions, so a restore is matched to the server too")
    func postgresRestoreUsesTheSameSelector() throws {
        let postgres = try #require(NativeDumpRegistry.descriptor(for: .postgresql)?.commandLineTool)
        #expect(postgres.binaries(for: .backup) == ["pg_dump"])
        #expect(postgres.binaries(for: .restore) == ["pg_restore"])
        #expect(postgres.toolForServer != nil)
    }

    @Test("Each engine offers its own archive extension")
    func archiveExtensions() throws {
        #expect(try #require(NativeDumpRegistry.descriptor(for: .postgresql)).archiveFormat.fileExtension == "dump")
        #expect(try #require(NativeDumpRegistry.descriptor(for: .mysql)).archiveFormat.fileExtension == "sql")
        #expect(try #require(NativeDumpRegistry.descriptor(for: .mongodb)).archiveFormat.fileExtension == "archive")
        #expect(try #require(NativeDumpRegistry.descriptor(for: .sqlite)).archiveFormat.fileExtension == "sql")
    }

    /// Anything in `argv` is readable by every process on the machine through `ps`, so no
    /// descriptor may put a password there.
    @Test("No engine puts the password in the argument list")
    func passwordNeverReachesArgv() throws {
        for type in [DatabaseType.postgresql, .mysql, .mongodb, .sqlite] {
            for kind in [NativeDumpKind.backup, .restore] {
                let built = try command(type, kind: kind, password: "s3cret")
                let leaked = built.arguments.filter { $0.contains("s3cret") }
                #expect(leaked.isEmpty, "\(type.rawValue) \(kind) leaked the password: \(leaked)")
            }
        }
    }

    @Test("MySQL passes its password through MYSQL_PWD")
    func mysqlUsesEnvironmentPassword() throws {
        let built = try command(.mysql)
        #expect(built.environment["MYSQL_PWD"] == "s3cret")
        #expect(built.arguments.contains("--single-transaction"))
        #expect(built.arguments.contains("--routines"))
        #expect(built.arguments.contains("--triggers"))
        #expect(built.arguments.contains("--events"))
        #expect(built.arguments.last == "sales")
    }

    /// `mysqldump` writes SQL to standard output, so the caller has to redirect it to the file.
    @Test("MySQL is redirected through standard output in both directions")
    func mysqlRedirects() throws {
        let backup = try command(.mysql, kind: .backup)
        #expect(backup.delivery == .standardOutput)
        #expect(backup.redirectedFileURL?.path == "/tmp/out.bin")
        #expect(!backup.isRestore)

        let restore = try command(.mysql, kind: .restore)
        #expect(restore.delivery == .standardOutput)
        #expect(restore.isRestore)
        #expect(!restore.arguments.contains("--single-transaction"))
    }

    /// `pg_dump -Fc` is told the path and writes it itself, so nothing is redirected.
    @Test("PostgreSQL writes its own file")
    func postgresWritesItsOwnFile() throws {
        let built = try command(.postgresql)
        #expect(built.delivery == .toolWritesFile)
        #expect(built.redirectedFileURL == nil)
    }

    /// `mongodump` reads a password from neither the environment nor standard input, so the only
    /// channel left is a config file, which must be owner-only and must not survive the process.
    @Test("MongoDB writes an owner-only credentials file and points at it")
    func mongoUsesACredentialsFile() throws {
        let built = try command(.mongodb)
        let configArgument = try #require(built.arguments.first { $0.hasPrefix("--config=") })
        let path = String(configArgument.dropFirst("--config=".count))
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(built.temporaryCredentialsFileURL?.path == path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o600)

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents.contains("s3cret"))
        #expect(built.environment["MONGO_PASSWORD"] == nil)
    }

    @Test("MongoDB writes no credentials file without a username")
    func mongoSkipsCredentialsWithoutUser() throws {
        let anonymous = connection(type: .mongodb, username: "")
        let built = try command(.mongodb, connection: anonymous)
        #expect(built.temporaryCredentialsFileURL == nil)
        #expect(!built.arguments.contains { $0.hasPrefix("--config=") })
    }

    @Test("MongoDB names the database on backup and scopes the namespace on restore")
    func mongoScopesItsDatabase() throws {
        #expect(try command(.mongodb, kind: .backup).arguments.contains("--db=sales"))
        #expect(try command(.mongodb, kind: .restore).arguments.contains("--nsInclude=sales.*"))
    }

    /// The database is a file the tool opens, so there is nothing to authenticate to.
    @Test("SQLite passes the file path and no network arguments")
    func sqliteUsesTheFilePath() throws {
        let file = connection(type: .sqlite, host: "", port: 0, database: "/tmp/app.sqlite", username: "")
        let backup = try command(.sqlite, connection: file)
        #expect(backup.arguments == ["/tmp/app.sqlite", ".dump"])

        let restore = try command(.sqlite, kind: .restore, connection: file)
        #expect(restore.arguments == ["/tmp/app.sqlite"])
        #expect(restore.isRestore)
    }

    /// libSQL claims the SQLite descriptor and keeps its path in a plugin-declared additional
    /// field, leaving `database` empty. Reading `database` handed `sqlite3` an empty path, which
    /// exits 0 after writing a 52-byte file the result sheet then reported as a backup.
    @Test("libSQL dumps the file its driver opens, not the empty database field")
    func libsqlUsesItsResolvedPath() throws {
        var remote = connection(type: .libsql, host: "", port: 0, database: "", username: "")
        remote.additionalFields["libsqlFilePath"] = "/tmp/turso.db"
        let backup = try command(
            .libsql, connection: remote, localFilePath: "/tmp/turso.db"
        )
        #expect(backup.arguments == ["/tmp/turso.db", ".dump"])
    }

    /// A libSQL connection to a Turso URL has no local file, so `sqlite3` cannot reach it at all.
    /// Answering by type alone is what offered Backup Dump on one and wrote nothing.
    @Test("A connection with no local file is not offered a dump")
    func remoteFileBackedConnectionIsUnsupported() {
        var remote = connection(type: .libsql, host: "", port: 0, database: "", username: "")
        remote.additionalFields["databaseUrl"] = "libsql://db.turso.io"
        #expect(!NativeDumpRegistry.supports(remote, localFilePath: nil))

        var local = remote
        local.additionalFields["libsqlFilePath"] = "/tmp/turso.db"
        #expect(NativeDumpRegistry.supports(local, localFilePath: "/tmp/turso.db"))
    }

    @Test("An empty host falls back to loopback on every engine that takes one")
    func emptyHostFallsBackToLoopback() throws {
        let mysql = try command(.mysql, connection: connection(type: .mysql, host: ""))
        #expect(mysql.arguments.contains("127.0.0.1"))

        let mongo = try command(.mongodb, connection: connection(type: .mongodb, host: ""))
        #expect(mongo.arguments.contains("--host=127.0.0.1"))
    }

    /// Measured, MariaDB 12.3.3 answers any `--ssl-mode` with `unknown variable` and exit 7, and
    /// MySQL 8.4.11 answers `--ssl` with `unknown option` and exit 2, so neither spelling may reach
    /// the other family's tool in either direction (#3046).
    @Test("Neither client family is ever handed the other one's SSL flags", arguments: [
        NativeDumpKind.backup, .restore
    ])
    func sslFlagsFollowTheResolvedTool(kind: NativeDumpKind) throws {
        let secured = connection(type: .mysql, sslMode: .required, sslEnabled: true)
        let maria = try command(.mysql, kind: kind, connection: secured, flavor: .mariadb)
        #expect(!maria.arguments.contains { $0.hasPrefix("--ssl-mode") })
        #expect(maria.arguments.contains("--ssl"))
        #expect(maria.arguments.contains("--ssl-verify-server-cert"))

        let mysql = try command(.mysql, kind: kind, connection: secured, flavor: .mysql)
        #expect(mysql.arguments.contains("--ssl-mode=REQUIRED"))
        #expect(!mysql.arguments.contains("--ssl"))
        #expect(!mysql.arguments.contains("--skip-ssl"))
    }

    /// SSL off is the other half of the same defect: the old code sent `--ssl-mode=DISABLED`, which
    /// MariaDB rejects exactly as it rejects the rest.
    @Test("An SSL-off connection is disabled in the tool's own spelling")
    func sslDisabledFollowsTheResolvedTool() throws {
        let maria = try command(.mysql, flavor: .mariadb)
        #expect(maria.arguments.contains("--skip-ssl"))
        #expect(!maria.arguments.contains { $0.hasPrefix("--ssl-mode") })

        let mysql = try command(.mysql, flavor: .mysql)
        #expect(mysql.arguments.contains("--ssl-mode=DISABLED"))
    }

    /// `--ssl-cert` implies `--ssl` on MariaDB, so a connection whose SSL is off must not carry the
    /// certificate the form still holds.
    @Test("Certificate paths reach the tool, and only while SSL is on")
    func certificatePathsFollowTheMode() throws {
        var secured = connection(type: .mysql, sslMode: .verifyCa, sslEnabled: true)
        secured.sslConfig.caCertificatePath = "/certs/ca.pem"
        secured.sslConfig.clientCertificatePath = "/certs/client.pem"
        secured.sslConfig.clientKeyPath = "/certs/client.key"
        let enabled = try command(.mysql, connection: secured, flavor: .mysql)
        #expect(enabled.arguments.contains("--ssl-ca=/certs/ca.pem"))
        #expect(enabled.arguments.contains("--ssl-cert=/certs/client.pem"))
        #expect(enabled.arguments.contains("--ssl-key=/certs/client.key"))

        var off = secured
        off.sslConfig.mode = .disabled
        let disabled = try command(.mysql, connection: off, flavor: .mariadb)
        #expect(!disabled.arguments.contains { $0.hasPrefix("--ssl-ca") })
        #expect(!disabled.arguments.contains { $0.hasPrefix("--ssl-cert") })
        #expect(!disabled.arguments.contains { $0.hasPrefix("--ssl-key") })
    }

    /// A tool that answered nothing is not guessed at once the connection asks for encryption:
    /// MariaDB accepts `--loose-ssl-mode=REQUIRED` and ignores it, which is a cleartext dump.
    @Test("An unidentified client refuses an encrypted connection rather than guessing")
    func unidentifiedToolRefusesEncryptedModes() throws {
        for mode in [SSLMode.required, .verifyCa, .verifyIdentity] {
            let secured = connection(type: .mysql, sslMode: mode, sslEnabled: true)
            #expect(throws: NativeDumpError.self) {
                try command(.mysql, connection: secured, flavor: .unidentified)
            }
        }
        let preferred = connection(type: .mysql, sslMode: .preferred, sslEnabled: true)
        let built = try command(.mysql, connection: preferred, flavor: .unidentified)
        #expect(!built.arguments.contains { $0.hasPrefix("--ssl") })
    }

    /// `mysqldump` 8.0 reads a table no MariaDB server and no MySQL before 8.0 has, and exits 2
    /// after writing part of the file. The flag that skips it is MySQL's own and backup only.
    @Test("A MySQL 8 dump tool skips column statistics on a server that has none")
    func columnStatisticsFlagFollowsTheServer() throws {
        let mysql8 = "mysqldump  Ver 8.4.11 for macos26.6 on arm64 (Homebrew)"
        let againstMariaDB = try command(
            .mysql, flavor: .mysql, toolVersionText: mysql8, serverVersion: "12.3.3-MariaDB"
        )
        #expect(againstMariaDB.arguments.contains("--skip-column-statistics"))

        let againstMySQL8 = try command(
            .mysql, flavor: .mysql, toolVersionText: mysql8, serverVersion: "8.4.11"
        )
        #expect(!againstMySQL8.arguments.contains("--skip-column-statistics"))

        let restore = try command(
            .mysql, kind: .restore, flavor: .mysql, toolVersionText: mysql8, serverVersion: "12.3.3-MariaDB"
        )
        #expect(!restore.arguments.contains("--skip-column-statistics"))

        let mariaTool = try command(
            .mysql,
            flavor: .mariadb,
            toolVersionText: "mysqldump from 12.3.3-MariaDB, client 10.20 for osx10.21 (arm64)",
            serverVersion: "12.3.3-MariaDB"
        )
        #expect(!mariaTool.arguments.contains("--skip-column-statistics"))
    }

    /// `my_getopt` parses past a positional argument, so a database named `--no-data` was read as
    /// the option: measured on MySQL 8.4.11 and MariaDB 12.3.3, that dumped a different database
    /// with no rows and exited 0, which the result sheet reports as a successful backup.
    @Test("The option terminator comes before the database, in both directions", arguments: [
        NativeDumpKind.backup, .restore
    ])
    func optionTerminatorPrecedesTheDatabase(kind: NativeDumpKind) throws {
        let built = try command(.mysql, kind: kind, flavor: .mysql)
        let terminator = try #require(built.arguments.firstIndex(of: "--"))
        let database = try #require(built.arguments.firstIndex(of: "sales"))
        #expect(terminator < database)
        #expect(built.arguments.filter { $0 == "--" }.count == 1)
    }

    @Test("A narrowed dump keeps its tables behind the same terminator")
    func narrowedDumpKeepsOneTerminator() throws {
        let scope = NativeDumpScope.objects([
            NativeDumpObject(name: "orders"), NativeDumpObject(name: "customers")
        ])
        let built = try command(.mysql, scope: scope, flavor: .mysql)
        let terminator = try #require(built.arguments.firstIndex(of: "--"))
        #expect(Array(built.arguments[terminator...]) == ["--", "sales", "orders", "customers"])
    }

    /// libpq falls back to `~/.postgresql/root.crt` when no root certificate is named, so a
    /// Verify CA connection that opens in the app could never be dumped: measured with pg_dump
    /// 17.11, it fails with `root certificate file "..." does not exist`.
    @Test("PostgreSQL sends the whole SSL configuration, not just the mode")
    func postgresSendsCertificatePaths() throws {
        var secured = connection(type: .postgresql, sslMode: .verifyCa, sslEnabled: true)
        secured.sslConfig.caCertificatePath = "/certs/ca.pem"
        secured.sslConfig.clientCertificatePath = "/certs/client.pem"
        secured.sslConfig.clientKeyPath = "/certs/client.key"
        let built = try command(.postgresql, connection: secured)
        #expect(built.environment["PGSSLMODE"] == "verify-ca")
        #expect(built.environment["PGSSLROOTCERT"] == "/certs/ca.pem")
        #expect(built.environment["PGSSLCERT"] == "/certs/client.pem")
        #expect(built.environment["PGSSLKEY"] == "/certs/client.key")

        var off = secured
        off.sslConfig.mode = .disabled
        let disabled = try command(.postgresql, connection: off)
        #expect(disabled.environment["PGSSLMODE"] == nil)
        #expect(disabled.environment["PGSSLROOTCERT"] == nil)
        #expect(disabled.environment["PGSSLCERT"] == nil)
        #expect(disabled.environment["PGSSLKEY"] == nil)
    }

    /// The CA belongs to the modes that verify one, which is the rule the live connection already
    /// follows in `LibPQConnectionString`.
    @Test("A required connection sends its client certificate but not a CA it does not check")
    func postgresRequiredKeepsTheClientCertificate() throws {
        var secured = connection(type: .postgresql, sslMode: .required, sslEnabled: true)
        secured.sslConfig.caCertificatePath = "/certs/ca.pem"
        secured.sslConfig.clientCertificatePath = "/certs/client.pem"
        let built = try command(.postgresql, connection: secured)
        #expect(built.environment["PGSSLMODE"] == "require")
        #expect(built.environment["PGSSLROOTCERT"] == nil)
        #expect(built.environment["PGSSLCERT"] == "/certs/client.pem")
    }

    /// MariaDB 11.0 renamed every client and some builds ship no `mysql`-prefixed symlink, so both
    /// spellings have to be tried before reporting the tool missing.
    @Test("MySQL tries both the mysql and mariadb tool names")
    func mysqlTriesBothToolNames() throws {
        let tool = try #require(NativeDumpRegistry.descriptor(for: .mysql)?.commandLineTool)
        #expect(tool.backupBinaries == ["mysqldump", "mariadb-dump"])
        #expect(tool.restoreBinaries == ["mysql", "mariadb"])
    }

    @Test("A YAML-quoted password survives quotes and backslashes")
    func yamlQuotingIsLossless() {
        #expect(NativeDumpService.mongoYAMLQuoted("plain") == "\"plain\"")
        #expect(NativeDumpService.mongoYAMLQuoted("a\"b") == "\"a\\\"b\"")
        #expect(NativeDumpService.mongoYAMLQuoted("a\\b") == "\"a\\\\b\"")
    }

    /// A progress bar showing a percentage of a number nobody measured is worse than an
    /// indeterminate one, so an engine with no cheap size answer returns nil.
    @Test("Only the engines with a cheap size query offer a determinate progress bar")
    func sizeQueryCoverage() {
        #expect(NativeDumpService.sizeQuery(for: .postgresql) != nil)
        #expect(NativeDumpService.sizeQuery(for: .mysql) != nil)
        #expect(NativeDumpService.sizeQuery(for: .mongodb) == nil)
        #expect(NativeDumpService.sizeQuery(for: .sqlite) == nil)
    }
}
