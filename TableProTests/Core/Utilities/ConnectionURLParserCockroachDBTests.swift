//
//  ConnectionURLParserCockroachDBTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Connection URL Parser - CockroachDB")
struct ConnectionURLParserCockroachDBTests {
    @Test("Full cockroachdb URL with default port")
    func testFullURLDefaultPort() {
        let result = ConnectionURLParser.parse("cockroachdb://user:pass@host:26257/defaultdb")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .cockroachdb)
        #expect(parsed.host == "host")
        #expect(parsed.port == nil)
        #expect(parsed.database == "defaultdb")
        #expect(parsed.username == "user")
        #expect(parsed.password == "pass")
    }

    @Test("cockroach scheme alias parses as CockroachDB")
    func testCockroachSchemeAlias() {
        let result = ConnectionURLParser.parse("cockroach://user:pass@host/defaultdb")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .cockroachdb)
        #expect(parsed.host == "host")
        #expect(parsed.database == "defaultdb")
        #expect(parsed.username == "user")
        #expect(parsed.password == "pass")
    }

    @Test("Case-insensitive CockroachDB scheme")
    func testCaseInsensitiveScheme() {
        let result = ConnectionURLParser.parse("CockroachDB://user@host/db")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .cockroachdb)
        #expect(parsed.host == "host")
        #expect(parsed.username == "user")
    }

    @Test("CockroachDB URL without credentials")
    func testWithoutCredentials() {
        let result = ConnectionURLParser.parse("cockroachdb://host/db")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .cockroachdb)
        #expect(parsed.host == "host")
        #expect(parsed.database == "db")
        #expect(parsed.username == "")
        #expect(parsed.password == "")
    }

    @Test("CockroachDB non-default port preserved")
    func testNonDefaultPortPreserved() {
        let result = ConnectionURLParser.parse("cockroachdb://user:pass@host:26258/db")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .cockroachdb)
        #expect(parsed.port == 26_258)
        #expect(parsed.host == "host")
        #expect(parsed.database == "db")
    }
}
