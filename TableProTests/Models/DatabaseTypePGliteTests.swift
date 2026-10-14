//
//  DatabaseTypePGliteTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct DatabaseTypePGliteTests {
    @Test("connection pooling is off (single connection)")
    func doesNotPool() {
        #expect(DatabaseType.pglite.supportsConnectionPooling == false)
    }
}
