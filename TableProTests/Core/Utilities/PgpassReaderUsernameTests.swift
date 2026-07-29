//
//  PgpassReaderUsernameTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Pgpass Effective Username")
struct PgpassReaderUsernameTests {
    @Test("A blank username matches ~/.pgpass as the operating system user")
    func blankUsernameResolvesToOSUser() {
        #expect(PgpassReader.effectiveUsername("") == NSUserName())
    }

    @Test("An explicit username is matched as given")
    func explicitUsernameIsPreserved() {
        #expect(PgpassReader.effectiveUsername("analytics") == "analytics")
    }
}
