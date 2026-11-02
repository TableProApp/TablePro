//
//  ProjectConfigExtractorTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

struct ScannedURLNormalizerTests {

    @Test("A raw at sign in the password is encoded using the last separator")
    func testRawAtSignEncoded() {
        let normalized = ScannedURLNormalizer.normalize("postgresql://user:p@ss@host:5432/db")
        #expect(normalized == "postgresql://user:p%40ss@host:5432/db")
    }

    @Test("Already encoded credentials are left alone")
    func testIdempotent() {
        let encoded = "postgresql://user:p%40ss@host:5432/db"
        #expect(ScannedURLNormalizer.normalize(encoded) == encoded)
    }

    @Test("A URL without credentials is untouched")
    func testNoUserInfo() {
        let plain = "postgresql://host:5432/db"
        #expect(ScannedURLNormalizer.normalize(plain) == plain)
    }

    @Test("An at sign in the query string is not mistaken for a separator")
    func testAtSignInQueryIgnored() {
        let value = "postgresql://host:5432/db?options=a@b"
        #expect(ScannedURLNormalizer.normalize(value) == value)
    }

    @Test("A slash in the password does not truncate the authority")
    func testSlashInPassword() {
        let normalized = ScannedURLNormalizer.normalize("postgresql://user:p/ss@host:5432/db")
        #expect(normalized == "postgresql://user:p%2Fss@host:5432/db")
    }

    @Test("A file path containing an at sign is left alone")
    func testFilePathWithAtSignUntouched() {
        let scoped = "sqlite:///Users/dat/@scope/proj/database.sqlite"
        #expect(ScannedURLNormalizer.normalize(scoped) == scoped)
        let mailbox = "duckdb:///Users/dat/mail@work/warehouse.duckdb"
        #expect(ScannedURLNormalizer.normalize(mailbox) == mailbox)
    }

    @Test("A unix socket host parameter is left alone")
    func testUnixSocketFormUntouched() {
        let socket = "postgresql:///appdb?host=/var/run/postgresql"
        #expect(ScannedURLNormalizer.normalize(socket) == socket)
    }
}

struct ScannedProductionHeuristicTests {

    @Test("Production markers are detected in the file name, host, and database")
    func testMarkersDetected() {
        #expect(ScannedProductionHeuristic.isProduction(relativePath: ".env.production", host: "", database: ""))
        #expect(ScannedProductionHeuristic.isProduction(relativePath: ".env", host: "db.prod.example.com", database: ""))
        #expect(ScannedProductionHeuristic.isProduction(relativePath: ".env", host: "", database: "live"))
    }

    @Test("A marker embedded in a longer word does not count")
    func testNoSubstringFalsePositives() {
        #expect(!ScannedProductionHeuristic.isProduction(relativePath: ".env", host: "products.example.com", database: ""))
        #expect(!ScannedProductionHeuristic.isProduction(relativePath: ".env", host: "productivity.io", database: ""))
        #expect(!ScannedProductionHeuristic.isProduction(relativePath: ".env.local", host: "localhost", database: "appdb"))
    }

    @Test("A separated marker counts, so the safer default wins")
    func testSeparatedMarkerCounts() {
        #expect(ScannedProductionHeuristic.isProduction(relativePath: ".env", host: "", database: "production_orders"))
        #expect(ScannedProductionHeuristic.isProduction(relativePath: ".env", host: "app-prod-01.internal", database: ""))
    }
}

struct YamlMappingSupportTests {

    @Test("Merge keys are expanded with the owning mapping winning")
    func testMergeKeyExpansion() throws {
        let contents = """
        base: &base
          adapter: postgresql
          host: shared.example.com
        child:
          <<: *base
          host: own.example.com
          database: appdb
        """
        let root = try #require(YamlMappingSupport.loadMapping(contents))
        let child = try #require(YamlMappingSupport.mapping(root["child"]))
        #expect(YamlMappingSupport.string(child["adapter"]) == "postgresql")
        #expect(YamlMappingSupport.string(child["host"]) == "own.example.com")
        #expect(YamlMappingSupport.string(child["database"]) == "appdb")
    }

    @Test("Scalars coerce to strings and integers")
    func testScalarCoercion() {
        #expect(YamlMappingSupport.string(5_432) == "5432")
        #expect(YamlMappingSupport.string(true) == "true")
        #expect(YamlMappingSupport.string("  spaced  ") == "spaced")
        #expect(YamlMappingSupport.string("") == nil)
        #expect(YamlMappingSupport.int("5432") == 5_432)
        #expect(YamlMappingSupport.int("not a port") == nil)
    }

    @Test("A document that is not a mapping yields nil")
    func testNonMappingDocument() {
        #expect(YamlMappingSupport.loadMapping("- just\n- a\n- list") == nil)
    }

    private static func aliasChain(levels: Int, width: Int) -> String {
        var lines = ["l0: &l0 [" + Array(repeating: "x", count: width).joined(separator: ", ") + "]"]
        for level in 1..<levels {
            lines.append("l\(level): &l\(level) [" + Array(repeating: "*l\(level - 1)", count: width).joined(separator: ", ") + "]")
        }
        return lines.joined(separator: "\n")
    }

    @Test("Nested aliases that would build over a million values are refused before they are built")
    func testAliasExpansionIsBounded() {
        let contents = Self.aliasChain(levels: 6, width: 10)
        #expect(contents.utf8.count < 400)
        #expect(YamlMappingSupport.loadMapping(contents) == nil)
        #expect(YamlMappingSupport.loadDocuments(contents).isEmpty)
    }

    @Test("Aliases within the budget still load, and the budget is spent on what they add")
    func testSmallAliasExpansionLoads() throws {
        let budget = ProjectScanExpansionBudget()
        let root = try #require(YamlMappingSupport.loadMapping(Self.aliasChain(levels: 3, width: 3), budget: budget))
        let top = try #require(root["l2"] as? [Any])
        #expect(top.count == 3)
        #expect((top.first as? [Any])?.count == 3)
        #expect(budget.remaining == ProjectScanExpansionBudget.standardLimit - 4 * 3 - 13 * 3)
    }

    @Test("Aliases that nest past the depth limit are refused even when the text itself is shallow")
    func testAliasNestingIsBounded() {
        let depth = YamlMappingSupport.maximumNesting / 2 + 10
        let inner = String(repeating: "[", count: depth) + "x" + String(repeating: "]", count: depth)
        let outer = String(repeating: "[", count: depth) + "*inner" + String(repeating: "]", count: depth)
        let contents = "inner: &inner \(inner)\nouter: \(outer)"
        #expect(YamlMappingSupport.loadMapping(contents) == nil)
    }

    private static func deepDocument(_ shape: String) -> String {
        let levels = 990
        switch shape {
        case "flow":
            return "k: " + String(repeating: "[", count: levels) + "x" + String(repeating: "]", count: levels)
        case "sequence":
            return "k:\n" + String(repeating: "- ", count: levels) + "x"
        default:
            return (0..<levels).map { String(repeating: " ", count: $0) + "k:" }.joined(separator: "\n") + " x"
        }
    }

    // A 512 KiB worker stack overflows near 650 levels in a debug build, and libyaml stops at 1,000.
    @Test("Nesting just under the parser's limit is refused without running out of stack",
          arguments: ["flow", "sequence", "mapping"])
    func testDeepNestingIsRefused(shape: String) {
        let contents = Self.deepDocument(shape)
        #expect(YamlMappingSupport.loadMapping(contents) == nil)
        #expect(YamlMappingSupport.loadDocuments(contents).isEmpty)
    }

    @Test("A key that is a collection is refused instead of crashing the constructor", arguments: [
        "[a, b]: v", "{a: b}: v", "? [a, b]\n: v"
    ])
    func testCollectionKeysAreRefused(keyLine: String) {
        let contents = "services:\n  db:\n    image: postgres\n" + keyLine
        #expect(YamlMappingSupport.loadMapping(contents) == nil)
        #expect(YamlMappingSupport.loadDocuments(contents).isEmpty)
    }

    @Test("A base-60 integer too large for Int is refused instead of crashing, and a short one still loads",
          .timeLimit(.minutes(1)))
    func testSexagesimalOverflowIsRefused() throws {
        #expect(YamlMappingSupport.loadMapping("x: 1:0:0:0:0:0:0:0:0:0:0") == nil)
        #expect(YamlMappingSupport.loadMapping("x: !!int 1:9223372036854775807") == nil)
        let root = try #require(YamlMappingSupport.loadMapping("ports:\n  - 22:22\n  - \"5432:5432\""))
        #expect((root["ports"] as? [Any])?.count == 2)
        let long = "x: 1" + String(repeating: ":0", count: 30) + ":99"
        #expect(YamlMappingSupport.loadMapping(long) != nil)
    }

    @Test("Brackets, braces and colons inside ordinary values and comments still load")
    func testOrdinaryBracketsStillLoad() throws {
        let contents = """
        x-logging: &logging
          driver: json-file
          options: {max-size: "10m"}
        x-ports: &ports ["${DB_PORT:-5432}:5432", "[::1]:5433:5432"]
        services:
          db:
            <<: [*logging]
            image: "postgres:${PG_VERSION:-16}"
            ports: *ports
            # [host]:[container]
            healthcheck:
              test: ["CMD-SHELL", "[ -f /tmp/ready ] && echo ready: yes"]
            command: ["sh", "-c", "until [ -f /ready ]; do echo waiting: 1; done"]
            environment:
              DATABASE_URL: <%= ENV.fetch("DATABASE_URL") { "postgres://localhost:5432/dev" } %>
        """
        let root = try #require(YamlMappingSupport.loadMapping(contents))
        let services = try #require(YamlMappingSupport.mapping(root["services"]))
        let db = try #require(YamlMappingSupport.mapping(services["db"]))
        #expect(YamlMappingSupport.string(db["driver"]) == "json-file")
        #expect(YamlMappingSupport.string(db["image"]) == "postgres:${PG_VERSION:-16}")
        #expect((db["ports"] as? [Any])?.count == 2)
        #expect((db["command"] as? [Any])?.count == 3)
    }
}

struct WordPressConfigExtractorTests {

    @Test("Standard define calls produce a MySQL candidate")
    func testStandardDefines() {
        let contents = """
        <?php
        define('DB_NAME', 'wordpress');
        define('DB_USER', 'wpuser');
        define('DB_PASSWORD', 'wppass');
        define('DB_HOST', 'localhost');
        """
        let candidate = WordPressConfigExtractor.extract(contents: contents, relativePath: "wp-config.php").first
        #expect(candidate?.parsedURL.type == .mysql)
        #expect(candidate?.parsedURL.database == "wordpress")
        #expect(candidate?.parsedURL.username == "wpuser")
        #expect(candidate?.parsedURL.host == "localhost")
        #expect(candidate?.parsedURL.port == 3306)
    }

    @Test("Commented out defines are ignored")
    func testCommentedDefinesIgnored() {
        let contents = """
        <?php
        define('DB_NAME', 'wordpress');
        // define('DB_HOST', 'wrong.example.com');
        define('DB_HOST', 'right.example.com');
        """
        let candidate = WordPressConfigExtractor.extract(contents: contents, relativePath: "wp-config.php").first
        #expect(candidate?.parsedURL.host == "right.example.com")
    }

    @Test("A host with a port is split")
    func testHostWithPort() {
        let result = WordPressConfigExtractor.splitHost("db.example.com:3307")
        #expect(result.host == "db.example.com")
        #expect(result.port == 3307)
    }

    @Test("A socket host is kept whole and flagged")
    func testSocketHost() {
        let result = WordPressConfigExtractor.splitHost("127.0.0.1:/var/run/mysqld/mysqld.sock")
        #expect(result.host == "127.0.0.1:/var/run/mysqld/mysqld.sock")
        #expect(result.isSocket)
    }

    @Test("A placeholder config is flagged")
    func testPlaceholderFlagged() {
        let contents = """
        <?php
        define('DB_NAME', 'database_name_here');
        define('DB_USER', 'username_here');
        define('DB_PASSWORD', 'password_here');
        """
        let candidate = WordPressConfigExtractor.extract(contents: contents, relativePath: "wp-config.php").first
        #expect(candidate?.placeholderSuspected == true)
    }
}

struct PrismaSchemaExtractorTests {
    private let root = URL(fileURLWithPath: "/tmp/prisma-project")

    @Test("The provider and an env reference resolve to a candidate")
    func testProviderWithEnvReference() {
        let contents = """
        datasource db {
          provider = "postgresql"
          url      = env("DATABASE_URL")
        }
        """
        let environment = DotenvParser.parse(
            "DATABASE_URL=postgresql://u:p@localhost:5432/app",
            processEnvironment: [:]
        )
        let candidates = PrismaSchemaExtractor.extract(
            contents: contents,
            relativePath: "prisma/schema.prisma",
            directoryURL: root.appendingPathComponent("prisma"),
            projectRootURL: root,
            environment: environment,
            fileManager: .default
        )
        #expect(candidates.first?.parsedURL.type == .postgresql)
        #expect(candidates.first?.parsedURL.database == "app")
    }

    @Test("A missing url yields no candidate rather than a guess")
    func testMissingURL() {
        let contents = """
        datasource db {
          provider = "postgresql"
        }
        """
        let candidates = PrismaSchemaExtractor.extract(
            contents: contents,
            relativePath: "prisma/schema.prisma",
            directoryURL: root,
            projectRootURL: root,
            environment: nil,
            fileManager: .default
        )
        #expect(candidates.isEmpty)
    }

    @Test("An env reference name is read from the call")
    func testEnvironmentVariableName() {
        #expect(PrismaSchemaExtractor.environmentVariableName(in: #"env("DATABASE_URL")"#) == "DATABASE_URL")
        #expect(PrismaSchemaExtractor.environmentVariableName(in: #""postgres://localhost/db""#) == nil)
    }

    @Test("A relative sqlite path prefers the location that exists on disk")
    func testSQLiteRelativePathProbing() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PrismaSQLite-\(UUID().uuidString)")
        let schemaDirectory = base.appendingPathComponent("prisma")
        try FileManager.default.createDirectory(at: schemaDirectory, withIntermediateDirectories: true)
        let databaseURL = schemaDirectory.appendingPathComponent("dev.db")
        try Data().write(to: databaseURL)

        let resolved = PrismaSchemaExtractor.resolveSQLitePath(
            "./dev.db",
            directoryURL: schemaDirectory,
            projectRootURL: base,
            fileManager: .default
        )
        #expect(resolved == databaseURL.standardizedFileURL.path)
    }
}

struct SpringPropertiesExtractorTests {

    @Test("A JDBC datasource URL is parsed with its credentials")
    func testDatasourceURL() {
        let contents = """
        spring.datasource.url=jdbc:postgresql://localhost:5432/appdb
        spring.datasource.username=springuser
        spring.datasource.password=springpass
        """
        let candidate = SpringPropertiesExtractor.extract(
            contents: contents,
            relativePath: "application.properties",
            processEnvironment: [:]
        ).first
        #expect(candidate?.parsedURL.type == .postgresql)
        #expect(candidate?.parsedURL.database == "appdb")
        #expect(candidate?.parsedURL.username == "springuser")
        #expect(candidate?.parsedURL.password == "springpass")
    }

    @Test("Comments and blank lines are skipped")
    func testCommentsSkipped() {
        let contents = """
        # spring.datasource.url=jdbc:postgresql://wrong:5432/nope
        ! also a comment
        spring.datasource.url=jdbc:postgresql://right:5432/appdb
        """
        let candidate = SpringPropertiesExtractor.extract(
            contents: contents,
            relativePath: "application.properties",
            processEnvironment: [:]
        ).first
        #expect(candidate?.parsedURL.host == "right")
    }

    @Test("A placeholder falls back to its declared default")
    func testPlaceholderDefault() {
        let resolved = SpringPropertiesExtractor.resolvePlaceholders(
            "jdbc:postgresql://${DB_HOST:localhost}:5432/app",
            processEnvironment: [:]
        )
        #expect(resolved == "jdbc:postgresql://localhost:5432/app")
    }

    @Test("A placeholder prefers the process environment over its default")
    func testPlaceholderFromEnvironment() {
        let resolved = SpringPropertiesExtractor.resolvePlaceholders(
            "jdbc:postgresql://${DB_HOST:localhost}:5432/app",
            processEnvironment: ["DB_HOST": "db.example.com"]
        )
        #expect(resolved == "jdbc:postgresql://db.example.com:5432/app")
    }
}

struct AppSettingsJsonExtractorTests {

    private func candidate(_ connectionString: String) -> ScannedConnectionCandidate? {
        AppSettingsJsonExtractor.candidate(
            name: "Default",
            connectionString: connectionString,
            relativePath: "appsettings.json"
        )
    }

    @Test("An Npgsql connection string maps to PostgreSQL")
    func testNpgsql() {
        let result = candidate("Host=localhost;Database=appdb;Username=appuser;Password=apppass")
        #expect(result?.parsedURL.type == .postgresql)
        #expect(result?.parsedURL.database == "appdb")
        #expect(result?.parsedURL.username == "appuser")
    }

    @Test("A SqlClient connection string maps to SQL Server")
    func testSqlClient() {
        let result = candidate("Data Source=localhost;Initial Catalog=appdb;User Id=sa;Password=pass")
        #expect(result?.parsedURL.type == .mssql)
        #expect(result?.parsedURL.database == "appdb")
        #expect(result?.parsedURL.port == 1433)
    }

    @Test("A MySqlConnector connection string maps to MySQL")
    func testMySqlConnector() {
        let result = candidate("Server=localhost;Database=appdb;Uid=appuser;Pwd=apppass")
        #expect(result?.parsedURL.type == .mysql)
        #expect(result?.parsedURL.username == "appuser")
    }

    @Test("A Server key alone is not misread as PostgreSQL")
    func testAmbiguousStringRejected() {
        #expect(candidate("Server=localhost;Database=appdb") == nil)
    }

    @Test("Connection strings are read from the ConnectionStrings object")
    func testFullDocument() throws {
        let json = """
        {
          "ConnectionStrings": {
            "Default": "Host=localhost;Database=appdb;Username=appuser;Password=apppass"
          }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let candidates = AppSettingsJsonExtractor.extract(data: data, relativePath: "appsettings.json")
        #expect(candidates.count == 1)
        #expect(candidates.first?.parsedURL.type == .postgresql)
    }
}
