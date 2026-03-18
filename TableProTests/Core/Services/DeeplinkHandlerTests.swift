//
//  DeeplinkHandlerTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("Deeplink Handler")
@MainActor
struct DeeplinkHandlerTests {

    @Test("Connect action with simple name")
    func testConnectSimpleName() {
        let url = URL(string: "tablepro://connect/Production")!
        let action = DeeplinkHandler.parse(url)
        if case .connect(let name) = action {
            #expect(name == "Production")
        } else {
            Issue.record("Expected .connect, got \(String(describing: action))")
        }
    }

    @Test("Connect action with percent-encoded name")
    func testConnectPercentEncodedName() {
        let url = URL(string: "tablepro://connect/My%20DB")!
        let action = DeeplinkHandler.parse(url)
        if case .connect(let name) = action {
            #expect(name == "My DB")
        } else {
            Issue.record("Expected .connect, got \(String(describing: action))")
        }
    }

    @Test("Open table without database")
    func testOpenTableWithoutDatabase() {
        let url = URL(string: "tablepro://connect/Prod/table/users")!
        let action = DeeplinkHandler.parse(url)
        if case .openTable(let connectionName, let tableName, let databaseName) = action {
            #expect(connectionName == "Prod")
            #expect(tableName == "users")
            #expect(databaseName == nil)
        } else {
            Issue.record("Expected .openTable, got \(String(describing: action))")
        }
    }

    @Test("Open table with database")
    func testOpenTableWithDatabase() {
        let url = URL(string: "tablepro://connect/Prod/database/analytics/table/events")!
        let action = DeeplinkHandler.parse(url)
        if case .openTable(let connectionName, let tableName, let databaseName) = action {
            #expect(connectionName == "Prod")
            #expect(tableName == "events")
            #expect(databaseName == "analytics")
        } else {
            Issue.record("Expected .openTable, got \(String(describing: action))")
        }
    }

    @Test("Open query with decoded SQL")
    func testOpenQueryDecodedSQL() {
        let url = URL(string: "tablepro://connect/Prod/query?sql=SELECT%20*%20FROM%20users")!
        let action = DeeplinkHandler.parse(url)
        if case .openQuery(let connectionName, let sql) = action {
            #expect(connectionName == "Prod")
            #expect(sql == "SELECT * FROM users")
        } else {
            Issue.record("Expected .openQuery, got \(String(describing: action))")
        }
    }

    @Test("Open query with empty SQL returns nil")
    func testOpenQueryEmptySQLReturnsNil() {
        let url = URL(string: "tablepro://connect/Prod/query?sql=")!
        let action = DeeplinkHandler.parse(url)
        #expect(action == nil)
    }

    @Test("Unrecognized path returns nil")
    func testUnrecognizedPathReturnsNil() {
        let url = URL(string: "tablepro://connect/Prod/unknown/path")!
        let action = DeeplinkHandler.parse(url)
        #expect(action == nil)
    }

    @Test("Unknown host returns nil")
    func testUnknownHostReturnsNil() {
        let url = URL(string: "tablepro://unknown-host")!
        let action = DeeplinkHandler.parse(url)
        #expect(action == nil)
    }

    @Test("Wrong scheme returns nil")
    func testWrongSchemeReturnsNil() {
        let url = URL(string: "https://example.com")!
        let action = DeeplinkHandler.parse(url)
        #expect(action == nil)
    }

    @Test("Import connection with all params")
    func testImportConnectionAllParams() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=mysql&port=3306")!
        let action = DeeplinkHandler.parse(url)
        if case .importConnection(let name, let host, let port, let type, _, _) = action {
            #expect(name == "Dev")
            #expect(host == "localhost")
            #expect(port == 3306)
            #expect(type == .mysql)
        } else {
            Issue.record("Expected .importConnection, got \(String(describing: action))")
        }
    }

    @Test("Import connection with case-insensitive type")
    func testImportConnectionCaseInsensitiveType() {
        let url = URL(string: "tablepro://import?name=Dev&host=localhost&type=PostgreSQL")!
        let action = DeeplinkHandler.parse(url)
        if case .importConnection(_, _, _, let type, _, _) = action {
            #expect(type == .postgresql)
        } else {
            Issue.record("Expected .importConnection, got \(String(describing: action))")
        }
    }

    @Test("Import connection missing name returns nil")
    func testImportConnectionMissingNameReturnsNil() {
        let url = URL(string: "tablepro://import?host=localhost&type=mysql")!
        let action = DeeplinkHandler.parse(url)
        #expect(action == nil)
    }
}
