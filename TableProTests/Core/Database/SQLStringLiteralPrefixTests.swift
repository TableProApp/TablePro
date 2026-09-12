//
//  SQLStringLiteralPrefixTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SQL String Literal Prefix")
struct SQLStringLiteralPrefixTests {
    @Test("SQL Server asks for a national literal")
    func sqlServerAsksForANationalLiteral() {
        #expect(SQLStringLiteralPrefix.forDatabaseType(.mssql) == "N")
    }

    @Test("Every other engine writes a plain literal")
    func otherEnginesWritePlainLiterals() {
        for type in DatabaseType.allKnownTypes where type != .mssql {
            #expect(SQLStringLiteralPrefix.forDatabaseType(type) == "", "\(type.rawValue) asked for a prefix")
        }
    }

    @Test("An unknown type from a future plugin writes a plain literal")
    func unknownTypesWritePlainLiterals() {
        #expect(SQLStringLiteralPrefix.forDatabaseType(DatabaseType(rawValue: "SomeFutureEngine")) == "")
        #expect(SQLStringLiteralPrefix.forDatabaseType(nil) == "")
    }
}
