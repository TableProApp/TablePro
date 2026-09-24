//
//  DriverPurposeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// The app and the libpq plugin agree on these values only by spelling, the way they already do for
/// `connectionId` and `queryTimeoutSeconds`, so a rename on either side is caught here.
@Suite("DriverPurpose")
struct DriverPurposeTests {
    @Test("Each purpose the app sends is the one the libpq plugin names")
    func pluginNamesEachPurpose() {
        #expect(LibPQConnectionString.applicationName(forPurpose: DriverPurpose.session.rawValue) == "TablePro")
        #expect(
            LibPQConnectionString.applicationName(forPurpose: DriverPurpose.metadata.rawValue) == "TablePro Metadata"
        )
    }
}
