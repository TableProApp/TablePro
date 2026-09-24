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

    @Test("carries the credentials")
    func carriesCredentials() {
        let parameters = build(database: "tmsdevdb1")
        #expect(parameters.contains(MSSQLLoginParameter(field: .user, value: "carrier")))
        #expect(parameters.contains(MSSQLLoginParameter(field: .password, value: "secret")))
    }

    @Test("sets only fields dbsetlname accepts: db-lib refuses an encryption level there with error 20043")
    func setsOnlyFieldsDbLibAccepts() {
        let fields = build(database: "tmsdevdb1").map(\.field)
        #expect(fields == [.user, .password, .application, .nationalLanguage, .charset, .database])
    }

    @Test("sets us_english language to settle the initial login state")
    func setsNationalLanguage() {
        let parameters = build(database: "tmsdevdb1")
        #expect(parameters.contains(MSSQLLoginParameter(field: .nationalLanguage, value: "us_english")))
    }

    @Test("an empty username still emits a user parameter, the FreeTDS Kerberos/GSS trigger")
    func emptyUserEmitsEmptyUserParameter() {
        let parameters = MSSQLLoginParameters.build(
            user: "",
            password: "",
            applicationName: "TablePro",
            database: "app"
        )
        #expect(parameters.contains(MSSQLLoginParameter(field: .user, value: "")))
        #expect(parameters.contains(MSSQLLoginParameter(field: .password, value: "")))
    }
}
