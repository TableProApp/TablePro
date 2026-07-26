//
//  ProjectConfigExtractorTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("Scanned URL Normalizer")
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

@Suite("Scanned Production Heuristic")
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

@Suite("YAML Mapping Support")
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
}

@Suite("WordPress Config Extractor")
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

@Suite("Prisma Schema Extractor")
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

@Suite("Spring Properties Extractor")
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

@Suite("App Settings JSON Extractor")
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
