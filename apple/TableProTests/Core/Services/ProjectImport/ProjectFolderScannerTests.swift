//
//  ProjectFolderScannerTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

struct ProjectFolderScannerTests {
    private let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProjectScannerTests-\(UUID().uuidString)")
            .appendingPathComponent("my-project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func write(_ contents: String, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func scan() throws -> ProjectFolderScanResult {
        switch ProjectFolderScanner.scan(rootURL: root) {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    @Test("A mixed project yields one candidate per distinct database")
    func testMixedProject() throws {
        try write("DATABASE_URL=postgresql://appuser:apppass@localhost:5432/appdb", to: ".env")
        try write("REDIS_URL=redis://localhost:6379/0", to: ".env")
        try write("DATABASE_URL=postgresql://johndoe:randompassword@localhost:5432/leaked", to: ".env.example")
        try write("DATABASE_URL=postgresql://u:p@localhost:5432/vendored", to: "node_modules/pkg/.env")
        try write(
            """
            <?php
            define('DB_NAME', 'wordpress');
            define('DB_USER', 'wpuser');
            define('DB_PASSWORD', 'wppass');
            define('DB_HOST', 'localhost');
            """,
            to: "wp-config.php"
        )

        let result = try scan()
        let paths = Set(result.candidates.map(\.sourceRelativePath))
        #expect(paths.contains(".env"))
        #expect(paths.contains("wp-config.php"))
        #expect(!paths.contains(".env.example"))
        #expect(!result.candidates.contains { $0.parsedURL.database == "vendored" })
        #expect(!result.candidates.contains { $0.parsedURL.database == "leaked" })
    }

    @Test("The same connection described twice is deduplicated to the stronger source")
    func testDeduplication() throws {
        try write("DATABASE_URL=postgresql://appuser:apppass@localhost:5432/appdb", to: ".env")
        try write(
            """
            {
              "ConnectionStrings": {
                "Default": "Host=localhost;Port=5432;Database=appdb;Username=appuser;Password=apppass"
              }
            }
            """,
            to: "appsettings.json"
        )

        let result = try scan()
        let matching = result.candidates.filter { $0.parsedURL.database == "appdb" }
        #expect(matching.count == 1)
        #expect(matching.first?.sourceRelativePath == ".env")
    }

    @Test("A Prisma schema resolves its url through the project dotenv")
    func testPrismaWithDotenv() throws {
        try write("DATABASE_URL=postgresql://prismauser:prismapass@localhost:5432/prismadb", to: ".env")
        try write(
            """
            datasource db {
              provider = "postgresql"
              url      = env("DATABASE_URL")
            }
            """,
            to: "prisma/schema.prisma"
        )

        let result = try scan()
        #expect(result.candidates.contains { $0.parsedURL.database == "prismadb" })
    }

    @Test("A compose file contributes a candidate on its published port")
    func testComposeService() throws {
        try write(
            """
            services:
              db:
                image: postgres:16
                environment:
                  POSTGRES_USER: composeuser
                  POSTGRES_PASSWORD: composepass
                  POSTGRES_DB: composedb
                ports:
                  - "15432:5432"
            """,
            to: "docker-compose.yml"
        )

        let result = try scan()
        let candidate = result.candidates.first { $0.parsedURL.database == "composedb" }
        #expect(candidate?.parsedURL.port == 15432)
    }

    @Test("An empty project produces no candidates and no error")
    func testEmptyProject() throws {
        try write("# nothing to see here", to: "README.md")
        #expect(try scan().candidates.isEmpty)
    }

    @Test("A missing folder fails rather than returning an empty result")
    func testMissingFolder() {
        let missing = root.appendingPathComponent("does-not-exist")
        switch ProjectFolderScanner.scan(rootURL: missing) {
        case .success:
            Issue.record("Expected a failure for a missing folder")
        case .failure(let error):
            #expect(error == .rootUnreadable)
        }
    }

    @Test("A dotenv reference the project does not define is not filled from TablePro's environment")
    func dotenvReferenceIgnoresProcessEnvironment() throws {
        let (name, secret) = setProbeVariable()
        defer { unsetenv(name) }
        try write("DB_CONNECTION=pgsql\nDB_HOST=db.example.com\nDB_USERNAME=app\nDB_PASSWORD=${\(name)}", to: ".env")

        let candidate = try #require(try scan().candidates.first)

        #expect(candidate.parsedURL.host == "db.example.com")
        #expect(candidate.parsedURL.password != secret)
        #expect(!candidate.hasPassword)
    }

    @Test("A Spring placeholder the project does not define is not filled from TablePro's environment")
    func springPlaceholderIgnoresProcessEnvironment() throws {
        let (name, secret) = setProbeVariable()
        defer { unsetenv(name) }
        try write(
            """
            spring.datasource.url=jdbc:postgresql://db.example.com:5432/appdb
            spring.datasource.username=app
            spring.datasource.password=${\(name)}
            """,
            to: "application.properties"
        )
        try write(
            """
            spring:
              datasource:
                url: jdbc:postgresql://db.example.com:5432/appdb
                username: app
                password: ${\(name)}
            """,
            to: "application.yml"
        )

        let result = try scan()

        #expect(!result.candidates.isEmpty)
        #expect(!result.candidates.contains { $0.parsedURL.password == secret })
    }

    private func setProbeVariable() -> (name: String, secret: String) {
        let name = "TABLEPRO_SCAN_PROBE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let secret = UUID().uuidString
        setenv(name, secret, 1)
        return (name, secret)
    }

    @Test("Results are ordered with the most trustworthy sources first")
    func testOrdering() throws {
        try write("DATABASE_URL=postgresql://u:p@localhost:5432/fromlocal", to: ".env.local")
        try write("DATABASE_URL=postgresql://u:p@localhost:5432/fromstaging", to: ".env.staging")

        let result = try scan()
        #expect(result.candidates.first?.parsedURL.database == "fromlocal")
    }
}
