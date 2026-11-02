//
//  NativeDumpRegistryTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProSSHConfig
import Testing
import Yams

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
        database: String = "sales",
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
        let built = try NativeDumpService.buildCommand(
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
                database: database,
                fileURL: fileURL,
                password: password,
                scope: scope,
                localFilePath: localFilePath ?? effective.database,
                serverVersion: serverVersion
            )
        )
        if let folder = built.clientPluginFolder {
            try? FileManager.default.removeItem(at: folder.url)
        }
        return built
    }

    private func configuration(of built: NativeDumpCommand) throws -> String {
        let url = try #require(built.temporaryCredentialsFileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func configurationValue(_ key: String, in contents: String) throws -> String {
        let prefix = "\(key): \""
        let line = try #require(contents.split(separator: "\n").first { $0.hasPrefix(prefix) })
        return String(line.dropFirst(prefix.count).dropLast())
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

    @Test("MongoDB writes no password and no auth database without a username")
    func mongoSkipsCredentialsWithoutUser() throws {
        let anonymous = connection(type: .mongodb, username: "")
        let contents = try configuration(of: command(.mongodb, connection: anonymous))
        #expect(!contents.contains("password:"))
        let uri = try configurationValue("uri", in: contents)
        #expect(uri == "mongodb://db.example.com:5432/")
    }

    @Test("MongoDB authenticates against the Auth Database field before the connection's database")
    func mongoAuthenticatesAgainstTheAuthDatabase() throws {
        var shop = connection(type: .mongodb, database: "shop")
        shop.mongoAuthSource = "admin"
        let explicit = try configurationValue("uri", in: configuration(of: command(.mongodb, connection: shop)))
        #expect(explicit.contains("authSource=admin"))
        #expect(!explicit.contains("authSource=shop"))

        shop.mongoAuthSource = nil
        let fallback = try configurationValue("uri", in: configuration(of: command(.mongodb, connection: shop)))
        #expect(fallback.contains("authSource=shop"))
    }

    @Test("An SRV connection reaches the tool as a mongodb+srv connection string with TLS on", arguments: [
        NativeDumpKind.backup, .restore
    ])
    func mongoSrvUsesAConnectionString(kind: NativeDumpKind) throws {
        var atlas = connection(type: .mongodb, host: "cluster0.example.mongodb.net", port: 27_017)
        atlas.mongoUseSrv = true
        let built = try command(.mongodb, kind: kind, connection: atlas)
        let uri = try configurationValue("uri", in: configuration(of: built))
        #expect(uri.hasPrefix("mongodb+srv://alice@cluster0.example.mongodb.net/?"))
        #expect(uri.contains("authSource=admin"))
        #expect(uri.contains("tls=true"))
        #expect(!built.arguments.contains { $0.hasPrefix("--host") || $0.hasPrefix("--port") })
    }

    @Test("The tools sign in with the Keychain's key passphrase and session token, never a plain copy")
    func mongoToolsGetTheKeychainSecrets() throws {
        var aws = connection(type: .mongodb, sslMode: .required, sslEnabled: true)
        aws.sslConfig.clientCertificatePath = "/Users/alice/client.pem"
        aws.mongoAuthMechanism = "MONGODB-AWS"
        aws.additionalFields["sslClientKeyPassphrase"] = "hunter2"
        aws.additionalFields["mongoAWSSessionToken"] = "FQoG"
        aws.additionalFields["mongoParam_authMechanismProperties"] = "AWS_SESSION_TOKEN:stale"
        aws.additionalFields["mongoParam_proxyPassword"] = "proxy-secret"

        let uri = try configurationValue("uri", in: configuration(of: command(.mongodb, connection: aws)))

        #expect(uri.contains("tlsCertificateKeyFilePassword=hunter2"))
        #expect(uri.contains("authMechanismProperties=AWS_SESSION_TOKEN%3AFQoG"))
        #expect(!uri.contains("stale"))
        #expect(!uri.contains("proxy-secret"))
    }

    @Test("A host list and its replica set reach the tool whole, not as the first host")
    func mongoHostListUsesAConnectionString() throws {
        var replicaSet = connection(type: .mongodb, host: "a.example.com", port: 27_017)
        replicaSet.additionalFields["mongoHosts"] = "a.example.com:27017,b.example.com:27018"
        replicaSet.mongoReplicaSet = "rs0"
        let built = try command(.mongodb, connection: replicaSet)
        let uri = try configurationValue("uri", in: configuration(of: built))
        #expect(uri.hasPrefix("mongodb://alice@a.example.com:27017,b.example.com:27018/?"))
        #expect(uri.contains("replicaSet=rs0"))
        #expect(!built.arguments.contains { $0.hasPrefix("--host") })
    }

    @Test("A Required MongoDB connection reaches the tool without verifying, as it does in the app")
    func mongoRequiredSkipsVerification() throws {
        var secured = connection(type: .mongodb, sslMode: .required, sslEnabled: true)
        secured.sslConfig.clientCertificatePath = "/certs/client.pem"
        let built = try command(.mongodb, connection: secured)
        let uri = try configurationValue("uri", in: configuration(of: built))
        #expect(uri.contains("tls=true&tlsInsecure=true"))
        #expect(uri.contains("tlsCertificateKeyFile=%2Fcerts%2Fclient.pem"))
        #expect(!built.arguments.contains("--ssl"))
    }

    @Test("Every option value reaches the tool encoded, so a `&`, `;` or `+` in it never starts another option")
    func mongoOptionValuesAreEncoded() throws {
        var secured = connection(type: .mongodb, sslMode: .verifyCa, sslEnabled: true)
        secured.sslConfig.caCertificatePath = "/Users/me/R&D/My Certs/c+a;b.pem"
        secured.mongoReplicaSet = "rs;tlsInsecure=true"
        secured.mongoAuthSource = "a&b"
        let uri = try configurationValue("uri", in: configuration(of: command(.mongodb, connection: secured)))
        #expect(uri.contains("replicaSet=rs%3BtlsInsecure%3Dtrue"))
        #expect(uri.contains("authSource=a%26b"))
        #expect(uri.contains("tlsCAFile=%2FUsers%2Fme%2FR%26D%2FMy%20Certs%2Fc%2Ba%3Bb.pem"))
        #expect(!uri.contains("tlsInsecure=true"))
    }

    @Test("A typed parameter named like a field's key in another case never overrides the field")
    func mongoTypedParameterKeysCompareWithoutCase() throws {
        var replicaSet = connection(type: .mongodb)
        replicaSet.mongoReplicaSet = "rs0"
        replicaSet.additionalFields["mongoParam_REPLICASET"] = "other"
        replicaSet.additionalFields["mongoParam_appName"] = "Table Pro"
        let uri = try configurationValue("uri", in: configuration(of: command(.mongodb, connection: replicaSet)))
        #expect(uri.contains("replicaSet=rs0"))
        #expect(!uri.contains("REPLICASET"))
        #expect(uri.contains("appName=Table%20Pro"))
    }

    @Test("X.509 and AWS authenticate against $external, which the tools' driver requires", arguments: [
        "MONGODB-X509", "MONGODB-AWS"
    ])
    func mongoExternalMechanismsUseExternal(mechanism: String) throws {
        var external = connection(type: .mongodb, sslMode: .required, sslEnabled: true)
        external.mongoAuthMechanism = mechanism
        let uri = try configurationValue("uri", in: configuration(of: command(.mongodb, connection: external)))
        #expect(uri.contains("authSource=%24external"))
    }

    @Test("A typed TLS parameter never overrides the SSL mode or sits beside the tlsInsecure it implies")
    func mongoTypedTLSParametersYieldToTheSSLMode() throws {
        var insecure = connection(type: .mongodb, sslMode: .required, sslEnabled: true)
        insecure.additionalFields["mongoParam_tlsDisableOCSPEndpointCheck"] = "true"
        let relaxed = try configurationValue("uri", in: configuration(of: command(.mongodb, connection: insecure)))
        #expect(relaxed.contains("tlsInsecure=true"))
        #expect(!relaxed.contains("tlsDisableOCSPEndpointCheck"))

        var verified = connection(type: .mongodb, sslMode: .verifyIdentity, sslEnabled: true)
        verified.additionalFields["mongoParam_tlsInsecure"] = "true"
        verified.additionalFields["mongoParam_sslInsecure"] = "true"
        verified.additionalFields["mongoParam_sslCertificateAuthorityFile"] = "/tmp/other.pem"
        let strict = try configurationValue("uri", in: configuration(of: command(.mongodb, connection: verified)))
        #expect(!strict.contains("tlsInsecure"))
        #expect(!strict.contains("sslInsecure"))
        #expect(!strict.contains("sslCertificateAuthorityFile"))
    }

    @Test("A bare IPv6 host reaches the tool in brackets")
    func mongoBareIPv6HostIsBracketed() throws {
        let local = connection(type: .mongodb, host: "fd00::5", port: 27_017)
        let uri = try configurationValue("uri", in: configuration(of: command(.mongodb, connection: local)))
        #expect(uri.hasPrefix("mongodb://alice@[fd00::5]:27017/"))
    }

    @Test("A port typed into a host list is encoded, so it cannot open the options")
    func mongoHostListPortIsEncoded() throws {
        var replicaSet = connection(type: .mongodb, host: "a.example.com", port: 27_017)
        replicaSet.additionalFields["mongoHosts"] = "a.example.com:27017,b.example.com:1/?tlsInsecure=true"
        let uri = try configurationValue("uri", in: configuration(of: command(.mongodb, connection: replicaSet)))
        #expect(uri.hasPrefix("mongodb://alice@a.example.com:27017,b.example.com:1%2F%3FtlsInsecure%3Dtrue/"))
    }

    @Test("MongoDB names the database on backup and renames the archive into the target on restore")
    func mongoScopesItsDatabase() throws {
        #expect(try command(.mongodb, kind: .backup).arguments.contains("--db=sales"))
        let restore = try command(.mongodb, kind: .restore).arguments
        #expect(restore.contains("--nsFrom=$db$.$coll$"))
        #expect(restore.contains("--nsTo=sales.$coll$"))
        #expect(!restore.contains { $0.hasPrefix("--nsInclude") })
    }

    @Test("A restore target keeps an asterisk literal, which mongorestore reads as part of the name")
    func mongoRestoreTargetIsLiteral() {
        #expect(
            NativeDumpArgumentQuoting.mongoRestoreRenaming(into: "we*ird")
                == ["--nsFrom=$db$.$coll$", "--nsTo=we*ird.$coll$"]
        )
    }

    /// The database is a file the tool opens, so there is nothing to authenticate to.
    @Test("SQLite passes the file path and no network arguments")
    func sqliteUsesTheFilePath() throws {
        let file = connection(type: .sqlite, host: "", port: 0, database: "/tmp/app.sqlite", username: "")
        let backup = try command(.sqlite, connection: file)
        #expect(backup.arguments == ["-safe", "/tmp/app.sqlite", ".dump"])

        let restore = try command(.sqlite, kind: .restore, connection: file)
        #expect(restore.arguments == ["-safe", "-bail", "/tmp/app.sqlite"])
        #expect(restore.isRestore)
    }

    @Test("A SQLite restore refuses a dump's shell commands and stops at its first error")
    func sqliteRestoreRunsNoShellCommand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-safe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("ran")
        let dump = directory.appendingPathComponent("hostile.sql")
        try "CREATE TABLE t(a);\n.shell touch '\(marker.path)'\nINSERT INTO t VALUES(1);\n"
            .write(to: dump, atomically: true, encoding: .utf8)
        let database = directory.appendingPathComponent("app.sqlite").path
        let file = connection(type: .sqlite, host: "", port: 0, database: database, username: "")
        let restore = try command(.sqlite, kind: .restore, connection: file)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = restore.arguments
        process.standardInput = try FileHandle(forReadingFrom: dump)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
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
        #expect(backup.arguments == ["-safe", "/tmp/turso.db", ".dump"])
    }

    // Measured with sqlite3 3.54.0: `sqlite3 -safe -cmd .dump` reads `-cmd` as an option and dumps an empty
    // in-memory database with exit 0, and sqlite3 before 3.42 rejects `--`.
    @Test("A SQLite path that starts with a dash or a tilde reaches sqlite3 absolute", arguments: [
        NativeDumpKind.backup, .restore
    ])
    func sqlitePathIsAbsolute(kind: NativeDumpKind) throws {
        let dashed = try command(
            .sqlite, kind: kind, connection: connection(type: .sqlite, host: "", port: 0, database: "-cmd", username: "")
        )
        let dashedPath = try #require(dashed.arguments.first { $0 != "-safe" && $0 != "-bail" })
        #expect(dashedPath == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("-cmd").path)
        #expect(dashedPath.hasPrefix("/"))
        #expect(!dashed.arguments.contains("--"))

        let home = try command(
            .sqlite, kind: kind, connection: connection(type: .sqlite, host: "", port: 0, database: "~/x.db", username: "")
        )
        let homePath = try #require(home.arguments.first { $0 != "-safe" && $0 != "-bail" })
        #expect(homePath == URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("x.db").path)

        let dotted = try command(
            .sqlite, kind: kind,
            connection: connection(type: .sqlite, host: "", port: 0, database: "/tmp/a/../-b.db", username: "")
        )
        #expect(dotted.arguments.contains("/tmp/-b.db"))
    }

    @Test("A SQLite path holding a NUL is refused before anything runs")
    func sqlitePathWithNULIsRefused() {
        #expect(throws: NativeDumpError.nulInArgument) {
            try command(.sqlite, connection: connection(type: .sqlite, host: "", port: 0, database: "/tmp/a\u{0}b", username: ""))
        }
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

    @Test("Every value of the SQL Server connection string is quoted", arguments: [
        (NativeDumpKind.backup, "/SourceConnectionString:"), (.restore, "/TargetConnectionString:")
    ])
    func sqlServerConnectionStringQuotesItsValues(kind: NativeDumpKind, flag: String) throws {
        #expect(try NativeDumpArgumentQuoting.sqlServerConnectionStringValue(#"a;b"c"#) == #""a;b""c""#)
        let built = try command(
            .mssql,
            kind: kind,
            connection: connection(type: .mssql, port: 1_433, sslMode: .verifyIdentity),
            database: "x;Server=elsewhere;TrustServerCertificate=true",
            password: "p;w"
        )
        let argument = try #require(built.arguments.first { $0.hasPrefix(flag) })
        #expect(
            argument.dropFirst(flag.count) == """
                Server="db.example.com,1433";Database="x;Server=elsewhere;TrustServerCertificate=true";\
                User ID="alice";Password="p;w";Encrypt=true
                """
        )
    }

    @Test("A NUL in a SQL Server or PostgreSQL value is refused before anything runs")
    func nulInAConnectionValueIsRefused() {
        #expect(throws: NativeDumpError.nulInArgument) {
            try command(.mssql, connection: connection(type: .mssql, port: 1_433), password: "p\u{0}w")
        }
        #expect(throws: NativeDumpError.nulInArgument) {
            try command(.postgresql, database: "sa\u{0}les")
        }
        #expect(throws: NativeDumpError.nulInArgument) {
            try command(.postgresql, scope: .objects([NativeDumpObject(name: "or\u{0}ders", schema: "app")]))
        }
    }

    // Process ends the app on a NUL in an argument, so the runner has to stop it first.
    @Test("A NUL in a sign-in name is a thrown error, not a crash", arguments: [
        DatabaseType.postgresql, .mysql
    ])
    func nulInTheUsernameIsAnError(type: DatabaseType) throws {
        let built = try command(type, connection: connection(type: type, username: "a\u{0}b"))
        let runner = ProcessNativeDumpRunner(command: built)
        #expect(throws: NativeDumpError.nulInArgument) { try runner.start() }
    }

    @Test("A PostgreSQL database name with a quote and a table with a double quote reach the tool escaped")
    func postgresQuotesReachTheTool() throws {
        let built = try command(
            .postgresql,
            database: "o'brien",
            scope: .objects([NativeDumpObject(name: "a\"b", schema: "app")])
        )
        let database = try #require(built.arguments.firstIndex(of: "-d").map { built.arguments[$0 + 1] })
        #expect(database == "dbname='o\\'brien'")
        let table = try #require(built.arguments.firstIndex(of: "-t").map { built.arguments[$0 + 1] })
        #expect(table == "\"app\".\"a\"\"b\"")
    }

    // libpq reads a -d value holding `=` as a conninfo whose host overrides -h. Measured with
    // pg_dump 17.11: the raw name dialed 127.0.0.66, the quoted one dumped the named database.
    @Test("A PostgreSQL database name reaches -d as a quoted dbname, in both directions", arguments: [
        NativeDumpKind.backup, .restore
    ])
    func postgresDatabaseNameIsQuoted(kind: NativeDumpKind) throws {
        let hostile = try command(.postgresql, kind: kind, database: "host=127.0.0.66 port=15433 sslmode=disable")
        let value = try #require(hostile.arguments.firstIndex(of: "-d").map { hostile.arguments[$0 + 1] })
        #expect(value == "dbname='host=127.0.0.66 port=15433 sslmode=disable'")
        #expect(hostile.arguments.starts(with: ["--no-password", "-h", "db.example.com", "-p", "5432"]))

        let quoted = try command(.postgresql, kind: kind, database: "a'b\\c'\u{301}")
        let escaped = try #require(quoted.arguments.firstIndex(of: "-d").map { quoted.arguments[$0 + 1] })
        #expect(escaped == "dbname='a\\'b\\\\c\\'\u{301}'")
    }

    // `\!` and `system` in piped input run a shell command, with MYSQL_PWD in its environment.
    // Measured with MariaDB 13.0.2: --binary-mode refuses both and `\.`, and a mariadb-dump of
    // routines, triggers, events and binary data restores the same under these flags.
    @Test("A MySQL or MariaDB restore turns the client's own commands off", arguments: [
        (NativeDumpToolFlavor.mysql, "mysql  Ver 8.4.6 for macos15 on arm64 (Homebrew)", "--skip-system-command"),
        (.mysql, "mysql  Ver 8.0.39 for macos14 on arm64", nil),
        (.mariadb, "mysql from 13.0.2-MariaDB, client 15.2 for osx10.23 (arm64) using  EditLine wrapper", "--sandbox"),
        (.mariadb, "mysql  Ver 15.1 Distrib 10.6.17-MariaDB, for osx10.19 (arm64)", nil),
        (.unidentified, nil, nil),
    ] as [(NativeDumpToolFlavor, String?, String?)])
    func mysqlRestoreTurnsClientCommandsOff(flavor: NativeDumpToolFlavor, versionText: String?, switchFlag: String?) throws {
        let restore = try command(.mysql, kind: .restore, flavor: flavor, toolVersionText: versionText)
        let terminator = try #require(restore.arguments.firstIndex(of: "--"))
        let options = restore.arguments[..<terminator]
        #expect(options.contains("--binary-mode"))
        #expect(options.contains("--local-infile=0"))
        #expect(options.contains("--skip-system-command") == (switchFlag == "--skip-system-command"))
        #expect(options.contains("--sandbox") == (switchFlag == "--sandbox"))

        let backup = try command(.mysql, kind: .backup, flavor: flavor, toolVersionText: versionText)
        #expect(!backup.arguments.contains("--binary-mode"))
    }

    @Test("An empty host falls back to loopback on every engine that takes one")
    func emptyHostFallsBackToLoopback() throws {
        let mysql = try command(.mysql, connection: connection(type: .mysql, host: ""))
        #expect(mysql.arguments.contains("127.0.0.1"))

        let mongo = try command(.mongodb, connection: connection(type: .mongodb, host: ""))
        #expect(try configurationValue("uri", in: configuration(of: mongo)).hasPrefix("mongodb://alice@127.0.0.1:5432/?"))
    }

    @Test("A MySQL connection goes over TCP to its host and port unless it names a local socket", arguments: [
        NativeDumpKind.backup, .restore
    ])
    func mysqlEndpointFollowsTheSocket(kind: NativeDumpKind) throws {
        let tcp = connection(type: .mysql, host: "localhost", port: 3_307)
        for flavor in [NativeDumpToolFlavor.mysql, .mariadb] {
            let built = try command(.mysql, kind: kind, connection: tcp, flavor: flavor)
            #expect(built.arguments.starts(with: ["--protocol=TCP", "-h", "localhost", "-P", "3307"]), "\(flavor)")
            #expect(!built.arguments.contains { $0.hasPrefix("--socket") }, "\(flavor)")
        }

        var socket = connection(type: .mysql, host: "db.example.com", port: 3_307)
        socket.additionalFields[MySQLLocalSocket.fieldKey] = "/tmp/mysql.sock"
        for flavor in [NativeDumpToolFlavor.mysql, .mariadb] {
            let built = try command(.mysql, kind: kind, connection: socket, flavor: flavor)
            let expected = ["--protocol=SOCKET", "-h", "localhost", "--socket=/tmp/mysql.sock"]
            #expect(built.arguments.starts(with: expected), "\(flavor)")
            #expect(!built.arguments.contains("--protocol=TCP"), "\(flavor)")
            #expect(!built.arguments.contains("db.example.com"), "\(flavor)")
            #expect(!built.arguments.contains("-P"), "\(flavor)")
        }
    }

    @Test("A PostgreSQL socket goes to -h as its directory, with the port its file is named after", arguments: [
        NativeDumpKind.backup, .restore
    ])
    func postgresEndpointFollowsTheSocket(kind: NativeDumpKind) throws {
        var socket = connection(type: .postgresql, host: "db.example.com", port: 5_432, sslMode: .verifyIdentity, sslEnabled: true)
        socket.additionalFields[MySQLLocalSocket.fieldKey] = "/tmp/.s.PGSQL.5433"
        let built = try command(.postgresql, kind: kind, connection: socket)
        #expect(built.arguments.starts(with: ["--no-password", "-h", "/tmp", "-p", "5433"]))
        #expect(!built.arguments.contains("db.example.com"))
        #expect(built.environment["PGSSLMODE"] == nil)

        var directory = connection(type: .postgresql, port: 5_434)
        directory.additionalFields[MySQLLocalSocket.fieldKey] = "/var/run/postgresql"
        let fromDirectory = try command(.postgresql, kind: kind, connection: directory)
        #expect(fromDirectory.arguments.starts(with: ["--no-password", "-h", "/var/run/postgresql", "-p", "5434"]))
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

    // A raw line break inside a double-quoted scalar folds to a space, and YAML 1.1 also breaks lines at U+0085,
    // U+2028 and U+2029, so the tool would sign in with another password.
    @Test("Every MongoDB config value reads back as written", arguments: [
        "plain", "a\"b", "a\\b", "é ✓", "a\nb\r\tc", "\u{1}\u{1B}\u{7F}\u{9F}", "\u{85}\u{2028}\u{2029}",
        "p\nuri: mongodb://evil.example.com",
    ])
    func mongoConfigurationRoundTrips(value: String) throws {
        let text = try NativeDumpService.mongoConfigurationText([
            NativeDumpDescriptor.ConfigurationEntry(key: "uri", value: "mongodb://db.example.com"),
            NativeDumpDescriptor.ConfigurationEntry(key: "password", value: value),
        ])
        let parsed = try #require(try Yams.load(yaml: text) as? [String: String])
        #expect(parsed == ["uri": "mongodb://db.example.com", "password": value])
        #expect(text.split(separator: "\n").count == 2)
    }

    @Test("A MongoDB password holding a newline stays one line of the config file")
    func mongoPasswordWithANewlineStaysOneLine() throws {
        let contents = try configuration(of: command(.mongodb, password: "p\nuri: mongodb://evil.example.com"))
        let lines = contents.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.filter { $0.hasPrefix("uri:") }.count == 1)
        #expect(try configurationValue("password", in: contents) == #"p\nuri: mongodb://evil.example.com"#)
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

    // An untyped $1 picked a planted pg_database_size(text) in the browsed schema over pg_catalog's (name).
    @Test("The PostgreSQL size query names pg_catalog's function and types its parameter")
    func postgresSizeQueryIsQualified() {
        #expect(NativeDumpService.sizeQuery(for: .postgresql) == "SELECT pg_catalog.pg_database_size($1::pg_catalog.name)")
    }

    @Test("A MySQL dump signed in with a token requires TLS, and MySQL's tools send the token in cleartext")
    func mysqlTokenDump() throws {
        var iam = connection(type: .mysql)
        iam.additionalFields["awsAuth"] = "gcpServiceAccount"
        for kind in [NativeDumpKind.backup, .restore] {
            let mysql = try command(.mysql, kind: kind, connection: iam, flavor: .mysql)
            #expect(mysql.arguments.contains("--ssl-mode=REQUIRED"))
            #expect(mysql.arguments.contains("--enable-cleartext-plugin"))

            let maria = try command(.mysql, kind: kind, connection: iam, flavor: .mariadb)
            #expect(maria.arguments.contains("--ssl-verify-server-cert"))
            #expect(!maria.arguments.contains("--enable-cleartext-plugin"))
        }
        let password = try command(.mysql, flavor: .mysql)
        #expect(!password.arguments.contains("--enable-cleartext-plugin"))
    }

    @Test("A PostgreSQL dump signed in with a token requires TLS when the connection has SSL off")
    func postgresTokenDump() throws {
        for auth in ["gcpApplicationDefault", "profile"] {
            var iam = connection(type: .postgresql)
            iam.additionalFields["awsAuth"] = auth
            #expect(try command(.postgresql, connection: iam).environment["PGSSLMODE"] == "require")
        }
    }

    @Test("Every install hint is plain text")
    func installHintsArePlainText() throws {
        for type in [DatabaseType.postgresql, .redshift, .mysql, .mongodb, .sqlite] {
            let tool = try #require(NativeDumpRegistry.descriptor(for: type)?.commandLineTool)
            #expect(!tool.installHint.contains("`"), "\(type.rawValue)")
            #expect(tool.installHint.contains("brew install"), "\(type.rawValue)")
        }
    }

    // What the session hands the tools through a TCP forward: loopback, with the server's name beside it.
    @MainActor
    private func throughTunnel(_ connection: DatabaseConnection) -> DatabaseConnection {
        DatabaseManager.shared.tunneledConnection(from: connection, localPort: 61_000)
    }

    @Test("pg_dump without a password never reads ~/.pgpass on its own", arguments: [NativeDumpKind.backup, .restore])
    func postgresWithoutPasswordSkipsPgpass(kind: NativeDumpKind) throws {
        for password in [nil, ""] as [String?] {
            let built = try command(.postgresql, kind: kind, password: password)
            #expect(built.environment["PGPASSFILE"] == "/dev/null/pgpass")
            #expect(built.environment["PGPASSWORD"] == nil)
        }
        let typed = try command(.postgresql, kind: kind, password: "s3cret")
        #expect(typed.environment["PGPASSWORD"] == "s3cret")
        #expect(typed.environment["PGPASSFILE"] == nil)
    }

    @MainActor
    @Test("Through a tunnel pg_dump checks the certificate against the server and dials the forward", arguments: [
        NativeDumpKind.backup, .restore
    ])
    func postgresThroughTunnelNamesTheServer(kind: NativeDumpKind) throws {
        var secured = connection(type: .postgresql, host: "db.example.com", sslMode: .verifyIdentity, sslEnabled: true)
        secured.sslConfig.caCertificatePath = "/certs/ca.pem"

        let tunneled = try command(.postgresql, kind: kind, connection: throughTunnel(secured))
        #expect(tunneled.arguments.starts(with: ["--no-password", "-h", "db.example.com", "-p", "61000"]))
        #expect(tunneled.environment["PGHOSTADDR"] == "127.0.0.1")
        #expect(tunneled.environment["PGSSLMODE"] == "verify-full")
        #expect(tunneled.environment["PGSSLROOTCERT"] == "/certs/ca.pem")

        let direct = try command(.postgresql, kind: kind, connection: secured)
        #expect(direct.arguments.starts(with: ["--no-password", "-h", "db.example.com", "-p", "5432"]))
        #expect(direct.environment["PGHOSTADDR"] == nil)
    }

    @MainActor
    @Test("Through a tunnel mysqldump refuses Verify Identity and MariaDB's dump refuses every verify mode", arguments: [
        NativeDumpKind.backup, .restore
    ])
    func mysqlThroughTunnelRefusesUncheckedModes(kind: NativeDumpKind) throws {
        var identity = connection(type: .mysql, port: 3_306, sslMode: .verifyIdentity, sslEnabled: true)
        identity.sslConfig.caCertificatePath = "/certs/ca.pem"
        var chain = identity
        chain.sslConfig.mode = .verifyCa
        let tunneledIdentity = throughTunnel(identity)
        let tunneledChain = throughTunnel(chain)

        #expect(throws: NativeDumpError.uncheckedThroughTunnel(
            tool: "/usr/bin/tool", mode: .verifyIdentity, supportedModes: [.disabled, .preferred, .required, .verifyCa]
        )) {
            try command(.mysql, kind: kind, connection: tunneledIdentity, flavor: .mysql)
        }
        let mysqlChain = try command(.mysql, kind: kind, connection: tunneledChain, flavor: .mysql)
        #expect(mysqlChain.arguments.contains("--ssl-mode=VERIFY_CA"))
        #expect(mysqlChain.arguments.contains("--ssl-ca=/certs/ca.pem"))

        for (mode, tunneled) in [(SSLMode.verifyCa, tunneledChain), (.verifyIdentity, tunneledIdentity)] {
            #expect(throws: NativeDumpError.uncheckedThroughTunnel(
                tool: "/usr/bin/tool", mode: mode, supportedModes: [.disabled, .preferred, .required]
            )) {
                try command(.mysql, kind: kind, connection: tunneled, flavor: .mariadb)
            }
        }

        let direct = try command(.mysql, kind: kind, connection: identity, flavor: .mysql)
        #expect(direct.arguments.contains("--ssl-mode=VERIFY_IDENTITY"))
    }

    @MainActor
    @Test("Through a tunnel mongodump keeps Verify CA without the name check and refuses Verify Identity", arguments: [
        NativeDumpKind.backup, .restore
    ])
    func mongoThroughTunnel(kind: NativeDumpKind) throws {
        var chain = connection(type: .mongodb, port: 27_017, sslMode: .verifyCa, sslEnabled: true)
        chain.sslConfig.caCertificatePath = "/certs/ca.pem"
        var identity = chain
        identity.sslConfig.mode = .verifyIdentity
        let tunneledIdentity = throughTunnel(identity)

        let uri = try configurationValue("uri", in: configuration(of: command(.mongodb, kind: kind, connection: throughTunnel(chain))))
        #expect(uri.hasPrefix("mongodb://alice@127.0.0.1:61000/?"))
        #expect(uri.contains("tls=true&tlsAllowInvalidHostnames=true&tlsCAFile=%2Fcerts%2Fca.pem"))
        #expect(!uri.contains("tlsInsecure"))

        #expect(throws: NativeDumpError.uncheckedThroughTunnel(
            tool: "/usr/bin/tool", mode: .verifyIdentity, supportedModes: [.disabled, .preferred, .required, .verifyCa]
        )) {
            try command(.mongodb, kind: kind, connection: tunneledIdentity)
        }

        let direct = try configurationValue("uri", in: configuration(of: command(.mongodb, kind: kind, connection: identity)))
        #expect(direct.contains("tls=true&tlsCAFile=%2Fcerts%2Fca.pem"))
        #expect(!direct.contains("tlsAllowInvalidHostnames"))
    }

    @MainActor
    @Test("Through a tunnel sqlpackage refuses the verify modes and keeps Required", arguments: [
        NativeDumpKind.backup, .restore
    ])
    func sqlServerThroughTunnel(kind: NativeDumpKind) throws {
        for mode in [SSLMode.verifyCa, .verifyIdentity] {
            let tunneled = throughTunnel(connection(type: .mssql, port: 1_433, sslMode: mode, sslEnabled: true))
            #expect(throws: NativeDumpError.uncheckedThroughTunnel(
                tool: "/usr/bin/tool", mode: mode, supportedModes: [.disabled, .preferred, .required]
            )) {
                try command(.mssql, kind: kind, connection: tunneled)
            }
        }

        let required = throughTunnel(connection(type: .mssql, port: 1_433, sslMode: .required, sslEnabled: true))
        let built = try command(.mssql, kind: kind, connection: required)
        let connectionString = try #require(built.arguments.first { $0.contains("ConnectionString:") })
        #expect(connectionString.contains(#"Server="127.0.0.1,61000""#))
        #expect(connectionString.hasSuffix("Encrypt=true;TrustServerCertificate=true"))
    }
}
