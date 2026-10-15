//
//  DriverPurposeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

// The libpq plugin matches these spellings, the way it already does `connectionId` and `queryTimeoutSeconds`.
// PostgreSQLDriverTests' LibPQConnectionStringTests pins its side to the same two values.
struct DriverPurposeTests {
    @Test("Each purpose the app sends is spelled the way the libpq plugin names it")
    func pluginNamesEachPurpose() {
        #expect(DriverPurpose.session.rawValue == "session")
        #expect(DriverPurpose.metadata.rawValue == "metadata")
    }
}
