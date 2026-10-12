//
//  ImportedSSLModeResolutionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ImportedSSLModeResolutionTests {
    private func parse(_ urlString: String) throws -> ParsedConnectionURL {
        guard case .success(let parsed) = ConnectionURLParser.parse(urlString) else {
            throw ConnectionURLParseError.invalidURL
        }
        return parsed
    }

    @Test("A deep link with no SSL parameter takes the driver's default, as the form does", arguments: [
        "postgresql://analyst@db.example.com/analytics",
        "mysql://root@db.example.com/shop",
        "mariadb://root@db.example.com/shop",
        "redshift://analyst@cluster.example.com/dev",
        "cockroachdb://root@crdb.example.com/app"
    ])
    func deepLinkTakesTheDriverDefault(url: String) throws {
        let connection = TransientConnectionFactory.build(from: try parse(url))
        #expect(connection.sslConfig.mode == .preferred)
    }

    @Test("An explicit opt-out stays Disabled on a deep link", arguments: [
        "mysql://root@db.example.com/shop?ssl=false",
        "postgresql://analyst@db.example.com/app?sslmode=disable",
        "postgresql://analyst@db.example.com/app?tlsmode=0"
    ])
    func deepLinkOptOutStaysDisabled(url: String) throws {
        #expect(TransientConnectionFactory.build(from: try parse(url)).sslConfig.mode == .disabled)
    }

    @Test("Drivers whose default is Disabled stay Disabled, and TLS schemes keep TLS")
    func schemeAndDefaultModes() throws {
        #expect(TransientConnectionFactory.build(from: try parse("mongodb://db.example.com/app")).sslConfig.mode == .disabled)
        #expect(TransientConnectionFactory.build(from: try parse("redis://cache.example.com")).sslConfig.mode == .disabled)
        #expect(TransientConnectionFactory.build(from: try parse("rediss://cache.example.com")).sslConfig.mode == .required)
        let srv = try parse("mongodb+srv://cluster.example.net/app?sslmode=disable")
        #expect(TransientConnectionFactory.build(from: srv).sslConfig.mode == .required)
    }

    @Test("The form and a deep link resolve the same SSL mode for the same URL", arguments: [
        "postgresql://analyst@db.example.com/app",
        "postgresql://analyst@db.example.com/app?sslmode=disable",
        "mysql://root@db.example.com/shop",
        "mysql://root@db.example.com/shop?ssl=false",
        "sqlserver://sa@sql.example.com/Sales",
        "mongodb://db.example.com/app",
        "mongodb+srv://cluster.example.net/app?sslmode=disable",
        "rediss://cache.example.com",
        "trino://analyst@trino.example.com:443/hive",
        "trino://analyst@trino.example.com:443/hive?SSL=false",
        "clickhouse://default@ch.example.com:8443/default",
        "cockroachdb://root@crdb.example.com/app"
    ])
    func formAndDeepLinkAgree(url: String) throws {
        let parsed = try parse(url)
        let coordinator = ConnectionFormCoordinator(connectionId: nil, initialParsedURL: parsed)
        coordinator.start()
        #expect(coordinator.ssl.mode == TransientConnectionFactory.build(from: parsed).sslConfig.mode)
    }

    @Test("The form and a deep link open the same port for the same URL", arguments: [
        "clickhouse://default@ch.example.com/default?ssl=true",
        "clickhouse://default@ch.example.com:8123/default?ssl=true",
        "clickhouse://default@ch.example.com/default",
        "trino://analyst@trino.example.com/hive?SSL=true",
        "postgresql://analyst@db.example.com/app?sslmode=require"
    ])
    func formAndDeepLinkAgreeOnPort(url: String) throws {
        let parsed = try parse(url)
        let coordinator = ConnectionFormCoordinator(connectionId: nil, initialParsedURL: parsed)
        coordinator.start()
        let transient = TransientConnectionFactory.build(from: parsed)
        #expect(coordinator.network.port == String(transient.port))
        #expect(transient.port == parsed.resolvedPort)
    }
}
