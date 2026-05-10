//
//  DatabaseTypeMSSQLTests.swift
//  TableProTests
//
//  Tests for .mssql properties and methods.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("DatabaseType MSSQL")
struct DatabaseTypeMSSQLTests {
    // MARK: - Basic Properties

    @Test("defaultPort is 1433")
    func defaultPort() {
        #expect(DatabaseType.mssql.defaultPort == 1_433)
    }

    @Test("rawValue is SQL Server")
    func rawValue() {
        #expect(DatabaseType.mssql.rawValue == "SQL Server")
    }

    @Test("requiresAuthentication is true")
    func requiresAuthentication() {
        #expect(DatabaseType.mssql.requiresAuthentication == true)
    }

    @Test("supportsForeignKeys is true")
    func supportsForeignKeys() {
        #expect(DatabaseType.mssql.supportsForeignKeys == true)
    }

    @Test("supportsSchemaEditing is true")
    func supportsSchemaEditing() {
        #expect(DatabaseType.mssql.supportsSchemaEditing == true)
    }

    @Test("iconName is mssql-icon")
    func iconName() {
        #expect(DatabaseType.mssql.iconName == "mssql-icon")
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
