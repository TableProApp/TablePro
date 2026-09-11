//
//  ProjectYamlExtractorTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("Rails Database YAML Extractor")
struct RailsDatabaseYamlExtractorTests {
    private let root = URL(fileURLWithPath: "/tmp/rails-project")

    private func extract(_ contents: String, environment: DotenvDocument? = nil) -> [ScannedConnectionCandidate] {
        RailsDatabaseYamlExtractor.extract(
            contents: contents,
            relativePath: "config/database.yml",
            projectRootURL: root,
            environment: environment
        )
    }

    @Test("Anchors and merge keys are expanded before reading the environment")
    func testAnchorsAndMergeKeys() {
        let contents = """
        default: &default
          adapter: postgresql
          encoding: unicode
          host: db.example.com
          username: railsuser
          password: railspass

        development:
          <<: *default
          database: myapp_development

        test:
          <<: *default
          database: myapp_test
        """
        let candidate = extract(contents).first
        #expect(candidate?.parsedURL.type == .postgresql)
        #expect(candidate?.parsedURL.database == "myapp_development")
        #expect(candidate?.parsedURL.host == "db.example.com")
        #expect(candidate?.parsedURL.username == "railsuser")
    }

    @Test("An ERB environment lookup resolves from the project dotenv")
    func testErbResolvedFromDotenv() {
        let contents = """
        development:
          adapter: postgresql
          database: myapp
          host: <%= ENV["DB_HOST"] %>
        """
        let environment = DotenvParser.parse("DB_HOST=resolved.example.com", processEnvironment: [:])
        #expect(extract(contents, environment: environment).first?.parsedURL.host == "resolved.example.com")
    }

    @Test("An ERB fetch default is used when the variable is missing")
    func testErbFetchDefault() {
        let contents = """
        development:
          adapter: postgresql
          database: myapp
          host: <%= ENV.fetch("DB_HOST", "localhost") %>
        """
        #expect(extract(contents).first?.parsedURL.host == "localhost")
    }

    @Test("An unresolvable ERB value is reported as a warning, not guessed")
    func testUnresolvedErbWarns() {
        let contents = """
        development:
          adapter: postgresql
          database: myapp
          password: <%= Rails.application.credentials.db_password %>
        """
        let candidate = extract(contents).first
        #expect(candidate?.parsedURL.password.isEmpty == true)
        #expect(candidate?.warnings.isEmpty == false)
    }

    @Test("A multi database development section picks the nested entry")
    func testMultiDatabaseSection() {
        let contents = """
        development:
          primary:
            adapter: postgresql
            database: myapp_development
            host: localhost
        """
        #expect(extract(contents).first?.parsedURL.database == "myapp_development")
    }

    @Test("A sqlite3 adapter resolves its path against the project root")
    func testSQLitePath() {
        let contents = """
        development:
          adapter: sqlite3
          database: storage/development.sqlite3
        """
        let candidate = extract(contents).first
        #expect(candidate?.parsedURL.type == .sqlite)
        #expect(candidate?.parsedURL.database == "/tmp/rails-project/storage/development.sqlite3")
    }
}

@Suite("Docker Compose Extractor")
struct DockerComposeExtractorTests {

    private func extract(_ contents: String, environment: DotenvDocument? = nil) -> [ScannedConnectionCandidate] {
        DockerComposeExtractor.extract(
            contents: contents,
            relativePath: "docker-compose.yml",
            environment: environment
        )
    }

    @Test("A published port is used instead of the container port")
    func testPublishedPort() {
        let contents = """
        services:
          db:
            image: postgres:16
            environment:
              POSTGRES_USER: appuser
              POSTGRES_PASSWORD: apppass
              POSTGRES_DB: appdb
            ports:
              - "8001:5432"
        """
        let candidate = extract(contents).first
        #expect(candidate?.parsedURL.type == .postgresql)
        #expect(candidate?.parsedURL.host == "127.0.0.1")
        #expect(candidate?.parsedURL.port == 8001)
        #expect(candidate?.parsedURL.database == "appdb")
    }

    @Test("A service with no published port is flagged as possibly unreachable")
    func testUnpublishedPortWarns() {
        let contents = """
        services:
          db:
            image: postgres:16
            environment:
              POSTGRES_PASSWORD: apppass
        """
        let candidate = extract(contents).first
        #expect(candidate?.parsedURL.port == 5432)
        #expect(candidate?.warnings.isEmpty == false)
    }

    @Test("A list form environment block is read")
    func testListFormEnvironment() {
        let contents = """
        services:
          db:
            image: mysql:8
            environment:
              - MYSQL_DATABASE=appdb
              - MYSQL_USER=appuser
              - MYSQL_PASSWORD=apppass
            ports:
              - "3307:3306"
        """
        let candidate = extract(contents).first
        #expect(candidate?.parsedURL.type == .mysql)
        #expect(candidate?.parsedURL.database == "appdb")
        #expect(candidate?.parsedURL.port == 3307)
    }

    @Test("TiDB and Databend images map to their own types and ports")
    func testTiDBAndDatabendImages() {
        let tidb = extract("""
        services:
          tidb:
            image: pingcap/tidb:latest
            ports:
              - "4001:4000"
        """).first
        #expect(tidb?.parsedURL.type == .tidb)
        #expect(tidb?.parsedURL.port == 4_001)

        let databend = extract("""
        services:
          warehouse:
            image: datafuselabs/databend:latest
            ports:
              - "3308:3307"
        """).first
        #expect(databend?.parsedURL.type == .databend)
        #expect(databend?.parsedURL.port == 3_308)
    }

    @Test("TiDB connects as root with no password, whatever MYSQL_ variables the service sets")
    func testTiDBCredentials() {
        let tidb = extract("""
        services:
          tidb:
            image: registry.example.com/pingcap/tidb:v8.5.1
            environment:
              MYSQL_ROOT_PASSWORD: ignored
              MYSQL_USER: ignored
            ports:
              - "4000:4000"
        """).first
        #expect(tidb?.parsedURL.type == .tidb)
        #expect(tidb?.parsedURL.username == "root")
        #expect(tidb?.parsedURL.password.isEmpty == true)
    }

    @Test("TiDB's tools are not TiDB servers")
    func testTiDBToolImagesAreIgnored() {
        for image in ["pingcap/tidb-lightning", "pingcap/tidb-dashboard", "pingcap/tidb-operator", "pingcap/tidb-binlog"] {
            let candidate = extract("""
            services:
              tool:
                image: \(image):latest
                ports:
                  - "4000:4000"
            """).first
            #expect(candidate?.parsedURL.type != .tidb, "\(image)")
        }
    }

    @Test("A split deployment's databend-query node is a Databend server; the meta node is not")
    func testDatabendQueryImage() {
        let query = extract("""
        services:
          query:
            image: datafuselabs/databend-query:v1.2.881
            ports:
              - "3307:3307"
        """).first
        #expect(query?.parsedURL.type == .databend)
        let meta = extract("""
        services:
          meta:
            image: datafuselabs/databend-meta:v1.2.881
            ports:
              - "3307:3307"
        """).first
        #expect(meta?.parsedURL.type != .databend)
    }

    @Test("Databend reads its own user variables and opens the default database")
    func testDatabendCredentials() {
        let databend = extract("""
        services:
          warehouse:
            image: databendlabs/databend
            environment:
              QUERY_DEFAULT_USER: analyst
              QUERY_DEFAULT_PASSWORD: secret
            ports:
              - "3307:3307"
        """).first
        #expect(databend?.parsedURL.type == .databend)
        #expect(databend?.parsedURL.username == "analyst")
        #expect(databend?.parsedURL.password == "secret")
        #expect(databend?.parsedURL.database == "default")
    }

    @Test("Interpolation uses the adjacent dotenv file")
    func testInterpolationFromDotenv() {
        let contents = """
        services:
          db:
            image: postgres:16
            environment:
              POSTGRES_PASSWORD: ${DB_PASSWORD}
            ports:
              - "${DB_PORT}:5432"
        """
        let environment = DotenvParser.parse("DB_PASSWORD=frompass\nDB_PORT=15432", processEnvironment: [:])
        let candidate = extract(contents, environment: environment).first
        #expect(candidate?.parsedURL.port == 15432)
        #expect(candidate?.hasPassword == true)
    }

    @Test("An interpolation default is used when the variable is missing")
    func testInterpolationDefault() {
        let contents = """
        services:
          db:
            image: postgres:16
            environment:
              POSTGRES_PASSWORD: ${DB_PASSWORD:-!ChangeMe!}
            ports:
              - "5433:5432"
        """
        #expect(extract(contents).first?.placeholderSuspected == true)
    }

    @Test("Credentials parked in an extension field anchor are still found")
    func testExtensionFieldAnchor() {
        let contents = """
        x-db-env: &db-env
          POSTGRES_USER: appuser
          POSTGRES_PASSWORD: apppass
          POSTGRES_DB: appdb

        services:
          db:
            image: postgres:16
            environment:
              <<: *db-env
            ports:
              - "5432:5432"
        """
        let candidate = extract(contents).first
        #expect(candidate?.parsedURL.username == "appuser")
        #expect(candidate?.parsedURL.database == "appdb")
    }

    @Test("A variable with no value anywhere is reported, not silently emptied")
    func testUnresolvedInterpolationWarns() {
        let contents = """
        services:
          db:
            image: postgres:16
            environment:
              POSTGRES_PASSWORD: ${DB_PASSWORD}
              POSTGRES_DB: appdb
            ports:
              - "5432:5432"
        """
        let candidate = extract(contents).first
        #expect(candidate?.warnings.isEmpty == false)
    }

    @Test("Services that are not databases are ignored")
    func testNonDatabaseServiceIgnored() {
        let contents = """
        services:
          web:
            image: nginx:latest
            ports:
              - "80:80"
        """
        #expect(extract(contents).isEmpty)
    }

    @Test("The long form port syntax is understood")
    func testLongFormPorts() {
        let contents = """
        services:
          db:
            image: mariadb:11
            environment:
              MARIADB_DATABASE: appdb
              MARIADB_PASSWORD: apppass
            ports:
              - target: 3306
                published: 3399
        """
        let candidate = extract(contents).first
        #expect(candidate?.parsedURL.type == .mariadb)
        #expect(candidate?.parsedURL.port == 3399)
    }
}

@Suite("Spring YAML Extractor")
struct SpringYamlExtractorTests {

    @Test("A nested datasource block is read")
    func testNestedDatasource() {
        let contents = """
        spring:
          datasource:
            url: jdbc:postgresql://localhost:5432/appdb
            username: springuser
            password: springpass
        """
        let candidate = SpringYamlExtractor.extract(
            contents: contents,
            relativePath: "application.yml",
            processEnvironment: [:]
        ).first
        #expect(candidate?.parsedURL.type == .postgresql)
        #expect(candidate?.parsedURL.database == "appdb")
        #expect(candidate?.parsedURL.username == "springuser")
    }

    @Test("A multi document file is searched past the first document")
    func testMultiDocument() {
        let contents = """
        spring:
          config:
            activate:
              on-profile: default
        ---
        spring:
          datasource:
            url: jdbc:postgresql://second:5432/appdb
        """
        let candidate = SpringYamlExtractor.extract(
            contents: contents,
            relativePath: "application.yml",
            processEnvironment: [:]
        ).first
        #expect(candidate?.parsedURL.host == "second")
    }
}
