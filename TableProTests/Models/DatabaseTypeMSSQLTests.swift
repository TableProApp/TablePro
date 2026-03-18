//
//  DatabaseTypeMSSQLTests.swift
//  TableProTests
//
//  Tests for .mssql properties and methods.
//

import Foundation
@testable import TablePro
import Testing

@Suite("DatabaseType MSSQL")
struct DatabaseTypeMSSQLTests {
    // MARK: - Basic Properties

    @Test("defaultPort is 1433")
    func defaultPort() {
        #expect(.mssql.defaultPort == 1_433)
    }

    @Test("rawValue is SQL Server")
    func rawValue() {
        #expect(.mssql.rawValue == "SQL Server")
    }

    @Test("requiresAuthentication is true")
    func requiresAuthentication() {
        #expect(.mssql.requiresAuthentication == true)
    }

    @Test("supportsForeignKeys is true")
    func supportsForeignKeys() {
        #expect(.mssql.supportsForeignKeys == true)
    }

    @Test("supportsSchemaEditing is true")
    func supportsSchemaEditing() {
        #expect(.mssql.supportsSchemaEditing == true)
    }

    @Test("iconName is mssql-icon")
    func iconName() {
        #expect(.mssql.iconName == "mssql-icon")
    }

    // MARK: - allKnownTypes Tests

    @Test("allKnownTypes contains mssql")
    func allKnownTypesContainsMSSql() {
        #expect(DatabaseType.allKnownTypes.contains(.mssql))
    }

    @Test("allCases shim contains mssql")
    func allCasesContainsMSSql() {
        #expect(DatabaseType.allCases.contains(.mssql))
    }
}
