//
//  ConnectionURLParserMSSQLTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("Connection URL Parser — MSSQL")
struct ConnectionURLParserMSSQLTests {

    @Test("Full MSSQL URL with default port")
    func testFullMSSQLURLDefaultPort() {
        let result = ConnectionURLParser.parse("mssql://user:pass@host:1433/mydb")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .mssql)
        #expect(parsed.host == "host")
        #expect(parsed.port == nil)
        #expect(parsed.database == "mydb")
        #expect(parsed.username == "user")
        #expect(parsed.password == "pass")
    }

    @Test("sqlserver scheme alias parses as MSSQL")
    func testSqlServerSchemeAlias() {
        let result = ConnectionURLParser.parse("sqlserver://user:pass@host/db")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .mssql)
        #expect(parsed.host == "host")
        #expect(parsed.database == "db")
        #expect(parsed.username == "user")
        #expect(parsed.password == "pass")
    }

    @Test("Case-insensitive MSSQL scheme")
    func testCaseInsensitiveMSSQLScheme() {
        let result = ConnectionURLParser.parse("MSSQL://user@host/db")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .mssql)
        #expect(parsed.host == "host")
        #expect(parsed.username == "user")
    }

    @Test("MSSQL URL without credentials")
    func testMSSQLWithoutCredentials() {
        let result = ConnectionURLParser.parse("mssql://host/db")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .mssql)
        #expect(parsed.host == "host")
        #expect(parsed.database == "db")
        #expect(parsed.username == "")
        #expect(parsed.password == "")
    }

    @Test("MSSQL non-default port preserved")
    func testMSSQLNonDefaultPortPreserved() {
        let result = ConnectionURLParser.parse("mssql://user:pass@host:1434/db")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .mssql)
        #expect(parsed.port == 1434)
        #expect(parsed.host == "host")
        #expect(parsed.database == "db")
    }

    @Test("MongoDB+SRV scheme parses as MongoDB")
    func testMongoDBSrvParsesAsMongoDBType() {
        let result = ConnectionURLParser.parse("mongodb+srv://user:pass@cluster.net/db")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .mongodb)
        #expect(parsed.host == "cluster.net")
        #expect(parsed.database == "db")
    }
}
