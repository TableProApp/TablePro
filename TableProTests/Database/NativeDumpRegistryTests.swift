//
//  NativeDumpRegistryTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Native dump registry")
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
        fileURL: URL = URL(fileURLWithPath: "/tmp/out.bin")
    ) throws -> NativeDumpCommand {
        let descriptor = try #require(NativeDumpRegistry.descriptor(for: type))
        return try NativeDumpService.buildCommand(
            kind: kind,
            descriptor: descriptor,
            executable: URL(fileURLWithPath: "/usr/bin/tool"),
            effective: overrideConnection ?? connection(type: type),
            database: "sales",
            fileURL: fileURL,
            password: password
        )
    }

    @Test("The engines with client-side tools are the ones the menu offers")
    func supportedEngines() {
        for type in [DatabaseType.postgresql, .redshift, .mysql, .mariadb, .mongodb, .sqlite] {
            #expect(NativeDumpRegistry.supports(type), "\(type.rawValue) should have a descriptor")
        }
        for type in [DatabaseType.clickhouse, .oracle, .duckdb] {
            #expect(!NativeDumpRegistry.supports(type), "\(type.rawValue) should not claim one")
        }
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

    @Test("An empty host falls back to loopback on every engine that takes one")
    func emptyHostFallsBackToLoopback() throws {
        let mysql = try command(.mysql, connection: connection(type: .mysql, host: ""))
        #expect(mysql.arguments.contains("127.0.0.1"))

        let mongo = try command(.mongodb, connection: connection(type: .mongodb, host: ""))
        #expect(mongo.arguments.contains("--host=127.0.0.1"))
    }

    @Test("MySQL SSL mode maps to the client's own spelling")
    func mysqlSSLModes() {
        #expect(NativeDumpRegistry.mysqlSSLMode(.disabled) == "--ssl-mode=DISABLED")
        #expect(NativeDumpRegistry.mysqlSSLMode(.preferred) == "--ssl-mode=PREFERRED")
        #expect(NativeDumpRegistry.mysqlSSLMode(.required) == "--ssl-mode=REQUIRED")
        #expect(NativeDumpRegistry.mysqlSSLMode(.verifyCa) == "--ssl-mode=VERIFY_CA")
        #expect(NativeDumpRegistry.mysqlSSLMode(.verifyIdentity) == "--ssl-mode=VERIFY_IDENTITY")
    }

    /// MariaDB 11.0 renamed every client and some builds ship no `mysql`-prefixed symlink, so both
    /// spellings have to be tried before reporting the tool missing.
    @Test("MySQL tries both the mysql and mariadb tool names")
    func mysqlTriesBothToolNames() throws {
        let descriptor = try #require(NativeDumpRegistry.descriptor(for: .mysql))
        #expect(descriptor.backupBinaries == ["mysqldump", "mariadb-dump"])
        #expect(descriptor.restoreBinaries == ["mysql", "mariadb"])
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
