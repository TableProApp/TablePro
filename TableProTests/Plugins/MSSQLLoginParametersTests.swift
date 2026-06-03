//
//  MSSQLLoginParametersTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("MSSQLLoginParameters.build")
struct MSSQLLoginParametersTests {
    private func build(database: String) -> [MSSQLLoginParameter] {
        MSSQLLoginParameters.build(
            user: "carrier",
            password: "secret",
            applicationName: "TablePro",
            encryptionFlag: "require",
            database: database
        )
    }

    @Test("includes the database in the login packet when set")
    func includesDatabaseWhenSet() {
        let parameters = build(database: "tmsdevdb1")
        #expect(parameters.contains(MSSQLLoginParameter(field: .database, value: "tmsdevdb1")))
    }

    @Test("omits the database when blank")
    func omitsDatabaseWhenBlank() {
        let fields = build(database: "").map(\.field)
        #expect(!fields.contains(.database))
    }

    @Test("carries the credentials and encryption flag")
    func carriesCredentials() {
        let parameters = build(database: "tmsdevdb1")
        #expect(parameters.contains(MSSQLLoginParameter(field: .user, value: "carrier")))
        #expect(parameters.contains(MSSQLLoginParameter(field: .password, value: "secret")))
        #expect(parameters.contains(MSSQLLoginParameter(field: .encryption, value: "require")))
    }

    @Test("sets us_english language to settle the initial login state")
    func setsNationalLanguage() {
        let parameters = build(database: "tmsdevdb1")
        #expect(parameters.contains(MSSQLLoginParameter(field: .nationalLanguage, value: "us_english")))
    }
}
