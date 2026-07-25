//
//  DotenvConnectionExtractorTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("Dotenv Connection Extractor")
struct DotenvConnectionExtractorTests {
    private let directory = URL(fileURLWithPath: "/tmp/project")

    private func extract(_ source: String, tier: ScannedConnectionTier = .nearCertain) -> [ScannedConnectionCandidate] {
        let document = DotenvParser.parse(source, processEnvironment: [:])
        return DotenvConnectionExtractor.extract(
            document: document,
            relativePath: ".env",
            tier: tier,
            directoryURL: directory
        )
    }

    @Test("A DATABASE_URL becomes a candidate")
    func testDatabaseURL() {
        let candidates = extract("DATABASE_URL=postgresql://admin:secret@db.example.com:5432/mydb")
        #expect(candidates.count == 1)
        #expect(candidates.first?.parsedURL.type == .postgresql)
        #expect(candidates.first?.parsedURL.host == "db.example.com")
        #expect(candidates.first?.parsedURL.database == "mydb")
        #expect(candidates.first?.parsedURL.username == "admin")
        #expect(candidates.first?.hasPassword == true)
    }

    @Test("The direct URL is preferred over the pooled one")
    func testUnpooledPreferred() {
        let source = """
        DATABASE_URL=postgresql://u:p@pooled.example.com:6543/app
        DATABASE_URL_UNPOOLED=postgresql://u:p@direct.example.com:5432/app
        """
        #expect(extract(source).first?.parsedURL.host == "direct.example.com")
    }

    @Test("A raw at sign in the password still parses")
    func testRawAtSignInPassword() {
        let candidates = extract("DATABASE_URL=postgresql://admin:p@ssw0rd@db.example.com:5432/mydb")
        #expect(candidates.first?.parsedURL.host == "db.example.com")
        #expect(candidates.first?.parsedURL.password == "p@ssw0rd")
    }

    @Test("Unresolved indirection produces no candidate")
    func testIndirectionSkipped() {
        #expect(extract("DATABASE_URL=${{Postgres.DATABASE_URL}}").isEmpty)
    }

    @Test("A Prisma placeholder is offered but flagged")
    func testPrismaPlaceholderFlagged() {
        let source = "DATABASE_URL=postgresql://johndoe:randompassword@localhost:5432/mydb?schema=public"
        let candidate = extract(source).first
        #expect(candidate != nil)
        #expect(candidate?.placeholderSuspected == true)
    }

    @Test("A Symfony placeholder is offered but flagged")
    func testSymfonyPlaceholderFlagged() {
        let source = "DATABASE_URL=postgresql://app:!ChangeMe!@127.0.0.1:5432/app"
        #expect(extract(source).first?.placeholderSuspected == true)
    }

    @Test("Laravel discrete keys map the driver name to a database type")
    func testLaravelDiscreteKeys() {
        let source = """
        DB_CONNECTION=pgsql
        DB_HOST=127.0.0.1
        DB_PORT=5432
        DB_DATABASE=laravel
        DB_USERNAME=sail
        DB_PASSWORD=password
        """
        let candidate = extract(source).first
        #expect(candidate?.parsedURL.type == .postgresql)
        #expect(candidate?.parsedURL.database == "laravel")
        #expect(candidate?.parsedURL.username == "sail")
    }

    @Test("Laravel sqlserver maps to SQL Server")
    func testLaravelSqlsrv() {
        #expect(extract("DB_CONNECTION=sqlsrv\nDB_HOST=localhost").first?.parsedURL.type == .mssql)
    }

    @Test("A relative Laravel SQLite path resolves against the env file directory")
    func testLaravelSQLiteRelativePath() {
        let source = """
        DB_CONNECTION=sqlite
        DB_DATABASE=database/database.sqlite
        """
        let candidate = extract(source).first
        #expect(candidate?.parsedURL.type == .sqlite)
        #expect(candidate?.parsedURL.database == "/tmp/project/database/database.sqlite")
    }

    @Test("Docker Postgres variables assume an address and say so")
    func testDockerPostgresAssumedAddress() {
        let source = """
        POSTGRES_USER=appuser
        POSTGRES_PASSWORD=apppass
        POSTGRES_DB=appdb
        """
        let candidate = extract(source).first
        #expect(candidate?.parsedURL.type == .postgresql)
        #expect(candidate?.parsedURL.host == "127.0.0.1")
        #expect(candidate?.parsedURL.port == 5432)
        #expect(candidate?.warnings.isEmpty == false)
    }

    @Test("MariaDB variables win over MySQL ones and yield a single candidate")
    func testMariaDBPreferred() {
        let source = """
        MARIADB_DATABASE=appdb
        MARIADB_USER=appuser
        MARIADB_PASSWORD=apppass
        MYSQL_DATABASE=ignored
        """
        let candidates = extract(source)
        #expect(candidates.count == 1)
        #expect(candidates.first?.parsedURL.type == .mariadb)
        #expect(candidates.first?.parsedURL.database == "appdb")
    }

    @Test("A container service hostname is flagged as unreachable")
    func testServiceHostnameWarning() {
        let source = """
        DB_CONNECTION=mysql
        DB_HOST=mysql
        DB_DATABASE=app
        """
        #expect(extract(source).first?.warnings.isEmpty == false)
    }

    @Test("Two relational engines in one file each produce a candidate")
    func testTwoRelationalEngines() {
        let source = """
        DATABASE_URL=postgresql://u:p@localhost:5432/appdb
        JAWSDB_URL=mysql://u:p@mysql.example.com:3306/legacy
        """
        let candidates = extract(source)
        let types = candidates.map(\.parsedURL.type)
        #expect(types.contains(.postgresql))
        #expect(types.contains(.mysql))
    }

    @Test("Pooled and direct URLs for one engine collapse to the direct one")
    func testPooledAndDirectCollapse() {
        let source = """
        DATABASE_URL=postgresql://u:p@pooled.example.com:6543/app
        DATABASE_URL_UNPOOLED=postgresql://u:p@direct.example.com:5432/app
        POSTGRES_URL=postgresql://u:p@another.example.com:5432/app
        """
        let candidates = extract(source).filter { $0.parsedURL.type == .postgresql }
        #expect(candidates.count == 1)
        #expect(candidates.first?.parsedURL.host == "direct.example.com")
    }

    @Test("Separate URLs for different engines each produce a candidate")
    func testMultipleEngines() {
        let source = """
        DATABASE_URL=postgresql://u:p@localhost:5432/app
        REDIS_URL=redis://localhost:6379/0
        MONGODB_URI=mongodb://u:p@localhost:27017/app
        """
        let types = extract(source).map(\.parsedURL.type)
        #expect(types.contains(.postgresql))
        #expect(types.contains(.redis))
        #expect(types.contains(.mongodb))
    }

    @Test("A production named file raises the safe mode level")
    func testProductionRaisesSafeMode() {
        let document = DotenvParser.parse("DATABASE_URL=postgresql://u:p@db.example.com:5432/app", processEnvironment: [:])
        let candidates = DotenvConnectionExtractor.extract(
            document: document,
            relativePath: ".env.production",
            tier: .likelyReal,
            directoryURL: directory
        )
        #expect(candidates.first?.parsedURL.safeModeLevel == 1)
    }

    @Test("A JDBC prefixed URL is parsed after the prefix is dropped")
    func testJdbcPrefixStripped() {
        let candidate = extract("JDBC_DATABASE_URL=jdbc:postgresql://localhost:5432/app").first
        #expect(candidate?.parsedURL.type == .postgresql)
        #expect(candidate?.parsedURL.database == "app")
    }
}
