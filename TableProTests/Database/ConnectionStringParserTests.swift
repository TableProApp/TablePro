//
//  ConnectionStringParserTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("ConnectionStringParser scheme + edge case coverage")
struct ConnectionStringParserTests {
    @Test("postgres:// resolves to PostgreSQL with port 5432 default")
    func parses_postgres_scheme() throws {
        let parsed = try ConnectionStringParser.parse("postgres://alice@db.example.com/sales")
        #expect(parsed.type == .postgresql)
        #expect(parsed.host == "db.example.com")
        #expect(parsed.port == 5_432)
        #expect(parsed.username == "alice")
        #expect(parsed.database == "sales")
        #expect(parsed.useSSL == false)
        #expect(parsed.rawScheme == "postgres")
    }

    @Test("postgresql:// is treated as PostgreSQL")
    func parses_postgresql_scheme() throws {
        let parsed = try ConnectionStringParser.parse("postgresql://db.example.com:6000/main")
        #expect(parsed.type == .postgresql)
        #expect(parsed.port == 6_000)
        #expect(parsed.database == "main")
    }

    @Test("mysql:// resolves to MySQL with default port 3306")
    func parses_mysql_scheme() throws {
        let parsed = try ConnectionStringParser.parse("mysql://root@127.0.0.1/app")
        #expect(parsed.type == .mysql)
        #expect(parsed.port == 3_306)
        #expect(parsed.username == "root")
        #expect(parsed.database == "app")
    }

    @Test("redis:// resolves to Redis with default port 6379")
    func parses_redis_scheme() throws {
        let parsed = try ConnectionStringParser.parse("redis://localhost")
        #expect(parsed.type == .redis)
        #expect(parsed.port == 6_379)
        #expect(parsed.useSSL == false)
        #expect(parsed.database == nil)
    }

    @Test("rediss:// flips useSSL to true")
    func rediss_enables_ssl() throws {
        let parsed = try ConnectionStringParser.parse("rediss://cache.internal")
        #expect(parsed.type == .redis)
        #expect(parsed.useSSL == true)
    }

    @Test("mongodb:// uses default port 27017")
    func parses_mongodb_scheme() throws {
        let parsed = try ConnectionStringParser.parse("mongodb://mongo.example.com/myapp")
        #expect(parsed.type == .mongodb)
        #expect(parsed.port == 27_017)
        #expect(parsed.database == "myapp")
    }

    @Test("mongodb+srv:// is recognized and forces SSL")
    func parses_mongodb_srv() throws {
        let parsed = try ConnectionStringParser.parse(
            "mongodb+srv://user:pw@cluster0.mongodb.net/test"
        )
        #expect(parsed.type == .mongodb)
        #expect(parsed.useSSL == true)
        #expect(parsed.rawScheme == "mongodb+srv")
    }

    @Test("URL-encoded password is decoded back to its original characters")
    func decodes_percent_encoded_password() throws {
        let parsed = try ConnectionStringParser.parse(
            "postgres://user:p%40ss%21@db.example.com/main"
        )
        #expect(parsed.username == "user")
        #expect(parsed.password == "p@ss!")
    }

    @Test("Missing port falls back to scheme default")
    func missing_port_uses_default() throws {
        let parsed = try ConnectionStringParser.parse("mysql://user@host/db")
        #expect(parsed.port == 3_306)
    }

    @Test("Postgres sslmode=require sets useSSL=true")
    func postgres_sslmode_require_enables_ssl() throws {
        let parsed = try ConnectionStringParser.parse(
            "postgres://user:pw@db.example.com:5432/main?sslmode=require"
        )
        #expect(parsed.useSSL == true)
        #expect(parsed.queryParameters["sslmode"] == "require")
    }

    @Test("Postgres sslmode=disable keeps useSSL=false")
    func postgres_sslmode_disable_keeps_ssl_off() throws {
        let parsed = try ConnectionStringParser.parse(
            "postgres://user:pw@db.example.com/main?sslmode=disable"
        )
        #expect(parsed.useSSL == false)
    }

    @Test("Mongo authSource preserved in queryParameters")
    func mongo_auth_source_preserved() throws {
        let parsed = try ConnectionStringParser.parse(
            "mongodb://user:pw@mongo.example.com/myapp?authSource=admin"
        )
        #expect(parsed.queryParameters["authSource"] == "admin")
    }

    @Test("URL with no path returns nil database")
    func empty_path_yields_nil_database() throws {
        let parsed = try ConnectionStringParser.parse("postgres://user@host:5432")
        #expect(parsed.database == nil)
    }

    @Test("URL with trailing slash returns nil database")
    func trailing_slash_yields_nil_database() throws {
        let parsed = try ConnectionStringParser.parse("postgres://user@host/")
        #expect(parsed.database == nil)
    }

    @Test("mysqlx:// is rejected with unsupportedScheme")
    func mysqlx_is_rejected() {
        #expect(throws: ConnectionStringParserError.unsupportedScheme("mysqlx")) {
            try ConnectionStringParser.parse("mysqlx://localhost:33060/test")
        }
    }

    @Test("Plain text without :// is rejected as malformedURL")
    func plain_text_is_rejected() {
        #expect(throws: ConnectionStringParserError.malformedURL) {
            try ConnectionStringParser.parse("just a sentence")
        }
    }

    @Test("Whitespace around the URL is tolerated")
    func whitespace_is_trimmed() throws {
        let parsed = try ConnectionStringParser.parse(
            "  postgres://user@db.example.com/main\n"
        )
        #expect(parsed.host == "db.example.com")
        #expect(parsed.username == "user")
        #expect(parsed.database == "main")
    }

    @Test("Empty input is rejected as malformedURL")
    func empty_input_is_rejected() {
        #expect(throws: ConnectionStringParserError.malformedURL) {
            try ConnectionStringParser.parse("   ")
        }
    }

    @Test("Empty host is rejected as malformedURL")
    func rejects_empty_host() throws {
        #expect(throws: ConnectionStringParserError.malformedURL) {
            try ConnectionStringParser.parse("postgres://")
        }
        #expect(throws: ConnectionStringParserError.malformedURL) {
            try ConnectionStringParser.parse("mysql:///dbonly")
        }
    }

    @Test("Out-of-range port is rejected")
    func rejects_invalid_port() throws {
        #expect(throws: ConnectionStringParserError.malformedURL) {
            try ConnectionStringParser.parse("postgres://host:0/db")
        }
        #expect(throws: ConnectionStringParserError.malformedURL) {
            try ConnectionStringParser.parse("postgres://host:99999/db")
        }
    }

    @Test("mongodb+srv:// reports port 0 so the driver resolves via DNS")
    func srv_scheme_skips_default_port() throws {
        let parsed = try ConnectionStringParser.parse("mongodb+srv://cluster.example.net/inventory")
        #expect(parsed.type == .mongodb)
        #expect(parsed.port == 0)
        #expect(parsed.useSSL == true)
        #expect(parsed.rawScheme == "mongodb+srv")
    }

    @Test("Postgres sslmode=allow and sslmode=prefer keep SSL off (libpq semantics)")
    func sslmode_prefer_and_allow_disable_ssl() throws {
        let allow = try ConnectionStringParser.parse("postgres://host/db?sslmode=allow")
        #expect(allow.useSSL == false)

        let prefer = try ConnectionStringParser.parse("postgres://host/db?sslmode=prefer")
        #expect(prefer.useSSL == false)

        let require = try ConnectionStringParser.parse("postgres://host/db?sslmode=require")
        #expect(require.useSSL == true)

        let verifyCa = try ConnectionStringParser.parse("postgres://host/db?sslmode=verify-ca")
        #expect(verifyCa.useSSL == true)
    }
}
