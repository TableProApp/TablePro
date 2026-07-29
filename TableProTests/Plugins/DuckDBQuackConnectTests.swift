//
//  DuckDBQuackConnectTests.swift
//  TableProTests
//
//  Tests for QuackConnectBuilder (compiled via symlink from DuckDBDriverPlugin).
//  Remote Quack connections need a live server, so these cover the SQL the
//  driver sends rather than the network round trip.
//

import Foundation
import Testing

@Suite("DuckDB Quack connect builder")
struct DuckDBQuackConnectTests {
    @Test("Secret statement escapes single quotes in the token")
    func secretEscapesQuotes() {
        let sql = QuackConnectBuilder.secretSQL(token: "my'token")
        #expect(sql == "CREATE OR REPLACE SECRET (TYPE quack, TOKEN 'my''token')")
    }

    @Test("Secret statement cannot be broken out of with injection payloads")
    func secretResistsInjection() {
        let sql = QuackConnectBuilder.secretSQL(token: "x'); DROP TABLE users; --")
        #expect(sql == "CREATE OR REPLACE SECRET (TYPE quack, TOKEN 'x''); DROP TABLE users; --')")
    }

    @Test("Attach statement builds a quack target and quotes the alias")
    func attachBuildsTarget() {
        let sql = QuackConnectBuilder.attachSQL(host: "localhost", port: 9_494, alias: "remotedb")
        #expect(sql == "ATTACH 'quack:localhost:9494' AS \"remotedb\"")
    }

    @Test("Attach quotes aliases that contain spaces and double quotes")
    func attachQuotesAlias() {
        let sql = QuackConnectBuilder.attachSQL(host: "h", port: 1, alias: "my \"db\"")
        #expect(sql == "ATTACH 'quack:h:1' AS \"my \"\"db\"\"\"")
    }

    @Test("Attach escapes a single quote in the host")
    func attachEscapesHost() {
        let sql = QuackConnectBuilder.attachSQL(host: "h'x", port: 9_494, alias: "a")
        #expect(sql == "ATTACH 'quack:h''x:9494' AS \"a\"")
    }

    @Test("USE statement quotes the alias")
    func useStatementQuotesAlias() {
        #expect(QuackConnectBuilder.useSQL(alias: "remotedb") == "USE \"remotedb\"")
    }

    @Test("Empty port falls back to the default")
    func emptyPortUsesDefault() {
        #expect(QuackConnectBuilder.normalizedPort("") == 9_494)
        #expect(QuackConnectBuilder.normalizedPort("  ") == 9_494)
    }

    @Test("Valid ports are accepted, invalid ones rejected")
    func portValidation() {
        #expect(QuackConnectBuilder.normalizedPort("5432") == 5_432)
        #expect(QuackConnectBuilder.normalizedPort("not-a-port") == nil)
        #expect(QuackConnectBuilder.normalizedPort("0") == nil)
        #expect(QuackConnectBuilder.normalizedPort("65536") == nil)
        #expect(QuackConnectBuilder.normalizedPort("-1") == nil)
    }

    @Test("Host validation rejects empty and whitespace-only values")
    func hostValidation() {
        #expect(!QuackConnectBuilder.isValidHost(""))
        #expect(!QuackConnectBuilder.isValidHost("   "))
        #expect(QuackConnectBuilder.isValidHost("localhost"))
    }
}
